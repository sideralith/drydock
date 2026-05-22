#!/usr/bin/env bash
# drydock-block-destructive.sh — Claude Code PreToolUse hook for drydock containers.
#
# Blocks the residue rule classes that the declarative deny layer cannot
# express without false-positives. All other rules ship as Bash(...) deny patterns
# in managed-settings drop-ins (10-git-safety.json, 30-os-safety.json,
# 50-prod-ops.json).
#
# Rule residue (ADR-7):
#   A1       — ssh to a production host (ssh token AND prod/production hostname)
#   A2       — kubectl/helm destructive verb (delete/destroy/uninstall/drain)
#              against a production context. Needs TWO conditions: the verb AND
#              a prod-scoped --context / --kube-context / -n / --namespace value.
#              A bare "prod" token (e.g. a resource name "prod-api") does NOT
#              block — the prod marker must be a context/namespace flag value.
#   A3       — a DB CLI (psql/mysql/mongo/mongosh/redis-cli) whose -h/--host
#              value contains a prod/production token. localhost and dev hosts
#              are not blocked. Connection-URI forms are a documented non-goal.
#   A4       — terraform apply/destroy. The deny layer covers the common forms
#              (terraform apply* / terraform destroy*); this rule backstops
#              forms with intervening flags (terraform -chdir=… destroy).
#   C1-res   — rm with ANY recursive flag form (-r/-R/-rf/-Rf/-fr/-fR and bundled)
#              targeting a system path root (/, /etc, /usr, /var, /boot, /opt,
#              /lib, /lib32, /lib64, /sbin, /bin, /sys, /proc, /dev, /root, /home).
#              Token-bounded: /home/me/project is NOT blocked. This is the hook
#              backstop for flag-order-reversed forms (-fR, -fr) and uppercase-R
#              forms that cannot be expressed as Bash(...) globs because *-r* only
#              matches a literal lowercase 'r'. The deny layer covers *-r* and *-R*
#              for the common flag orderings; this rule catches the residue.
#   C7-res   — sudo chmod with a world-writable mode: a numeric mode whose final
#              octal digit (others) carries the write bit (2/3/6/7), or a symbolic
#              clause granting write to 'o'/'a'. A Bash(...) glob cannot inspect
#              the others write bit. chmod WITHOUT sudo is out of scope.
#   C12      — fork bomb (:() { :|: & };: shape)
#   C17      — rm of . or .git (anchored: no extension, no trailing path component)
#   C18      — rm with ../ traversal or bare .. target
#   C20      — curl/wget piped into bash/sh (optionally via sudo)
#
# Docker-aware coverage (ADR-6):
#   The hook applies its regex set to the FULL command string unconditionally.
#   docker exec/run wrappers do not suppress a match: "docker exec ctr rm -rf ."
#   still contains "rm -rf ." and is caught by C17. No flag-tokenizer is used
#   (that would require eval-adjacent logic — rejected in ADR-6). Host-escape
#   forms (docker run --privileged, -v /:) are handled at the deny layer.
#
# Adversarial bypass (INV-6 / INV-7):
#   Command-string inspection raises the accident floor; it is NOT an adversarial
#   ceiling. Raw socket calls, the Docker SDK, base64-obfuscated payloads, and
#   docker exec reading commands from a file all bypass string inspection.
#   Adversarial container-escape via the Docker socket remains a documented
#   non-goal per INV-6 and INV-7.
#
# HOST-SAFETY GUARD:
#   This script is absent on the host; the guard in 40-guardrails-hook.json uses
#   'sh -c "[ -x /opt/drydock/hooks/drydock-block-destructive.sh ] && exec ..."'
#   so host sessions never reach here. Nonetheless, a belt-and-suspenders guard
#   is kept below so the script is idempotent even if invoked directly on a host.
#
# SEAMS (mirrors drydock-session-start.sh):
#   DRYDOCK_RELEASE_FILE — defaults to /etc/drydock-release; override in tests

set -euo pipefail

: "${DRYDOCK_RELEASE_FILE:=/etc/drydock-release}"

# Exit silently on the host (no marker file → not inside a drydock container).
[ -f "$DRYDOCK_RELEASE_FILE" ] || exit 0

# ── Read PreToolUse JSON from stdin ───────────────────────────────────────────
payload="$(cat)"

# Belt-and-suspenders: only act when tool_name is Bash (matcher already scopes
# this, but defense-in-depth costs nothing here).
# Guard: jq failures (non-JSON / malformed stdin) are swallowed; the hook
# exits 0 (allow) on unreadable input rather than crashing under set -e.
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$tool_name" = "Bash" ] || exit 0

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Nothing to inspect if the command is empty.
[ -n "$cmd" ] || exit 0

# ── Segment splitting (FIX-1) ─────────────────────────────────────────────────
# Rules A1, C17, and C18 must match within a SINGLE command segment so that a
# harmless flag or token in an unrelated segment does not cause a false block.
# Split on &&, ||, ;, and newline — NOT on | (C20 must still see across pipes).
# Each segment is tested independently; if any segment is dangerous, block.
norm="${cmd//&&/$'\x01'}"
norm="${norm//||/$'\x01'}"
norm="${norm//;/$'\x01'}"
norm="${norm//$'\n'/$'\x01'}"
IFS=$'\x01' read -ra _segments <<<"$norm"

# ── FIX-31: quoted-target normalization (issue #31) ──────────────────────────
# The space-anchored regex checks in C1-residue / C17 / C18 below use
# [[:space:]] as the token boundary before the target argument. A quoted
# target (rm -rf "/etc", rm -rf "." …) defeats the anchor because the
# path token is preceded by a quote character, not a space.
#
# This pass strips a SINGLE layer of matched double or single quote pairs
# from each segment. Quote chars are replaced with spaces so token
# boundaries are preserved without breaking word integrity inside the
# quoted content:
#
#   rm -rf "/etc"       →  rm -rf  /etc           (space before /etc, anchored)
#   echo "hello world"  →  echo  hello world      (content intact)
#   rm -rf '../foo'     →  rm -rf  ../foo
#
# Quote handling coverage:
# - Nested mixed quoting (e.g. double-quoted block containing single-quoted
#   inner): the two-pass strip CORRECTLY handles this — the double-quote pass
#   produces a stripped form; the single-quote pass then catches the inner.
# - Escaped quote characters (e.g. a backslash-escaped double quote inside a
#   double-quoted block): treated as two separate matched pairs by the sed
#   pattern. Acceptable under threat model A (INV-7) — accident-class typos
#   do not produce backslash-escaped quotes around path tokens.
# - ANSI-C quoting ($'…' form): handled (incidentally) by the single-quote
#   pass — the '…' substring matches even with the $ prefix. Coverage is
#   locked in via FIX-31-followup tests in test/block_destructive.bats.
# - Mismatched quotes (e.g. quoted opening with no closing): bash rejects the
#   command at parse time before execution. The hook receives the raw string
#   but bash never runs it destructively. Acceptable under threat model A.
_strip_quotes() {
	local s="$1"
	s="$(printf '%s' "$s" | sed -E 's/"([^"]*)"/ \1 /g')"
	s="$(printf '%s' "$s" | sed -E "s/'([^']*)'/ \1 /g")"
	printf '%s' "$s"
}

for _i in "${!_segments[@]}"; do
	_segments[_i]="$(_strip_quotes "${_segments[_i]}")"
done

# ── Rule C1-residue: rm with any recursive flag targeting a system path root ──
# Block: rm with -r/-R/-rf/-Rf/-fr/-fR (or any bundled form containing r or R)
# where the target is a system path root token (/, /etc, /usr, etc.) — not a
# subpath like /home/me/project. Token boundary: path followed by EOS or space.
# Allow: rm -Rf /home/me/project/dist (the '/' after /home is not EOS or space).
#
# Per-segment: flag and system-path target must belong to the same rm invocation.
# Paths matched: / /etc /usr /var /boot /opt /lib /lib32 /lib64 /sbin /bin
#                /sys /proc /dev /root /home
#
# Note: the deny layer (*-r* and *-R* entries) handles the common flag orderings
# at the framework level before this hook runs. This rule is the residue backstop
# for flag-order-reversed forms like -fr and -fR that the glob *-r* cannot match.
for _seg in "${_segments[@]}"; do
	if [[ "$_seg" =~ (^|[[:space:]])rm[[:space:]] ]] &&
		[[ "$_seg" =~ [[:space:]](-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$) ]] &&
		[[ "$_seg" =~ [[:space:]](/|/etc|/usr|/var|/boot|/opt|/lib|/lib32|/lib64|/sbin|/bin|/sys|/proc|/dev|/root|/home)($|[[:space:]]) ]]; then
		echo "drydock guardrail: rm with recursive flag targeting a system path root is blocked (C1-residue)." >&2
		echo "Specify a project-relative path or a path under your project directory." >&2
		exit 2
	fi
done

# ── Rule A1: ssh to production host ──────────────────────────────────────────
# Block: ssh token AND a prod/production hostname token (case-insensitive).
# Allow: ssh to dev, staging, or any non-production host.
# Case-insensitive match is scoped to a subshell so nocasematch does not leak
# into subsequent regex tests.
_a1_match() (
	local seg="$1"
	shopt -s nocasematch
	[[ "$seg" =~ (^|[[:space:]])ssh[[:space:]] ]] &&
		[[ "$seg" =~ (^|[[:space:]@./-])prod(uction)?([[:space:]@./-]|$) ]]
)

for _seg in "${_segments[@]}"; do
	if _a1_match "$_seg"; then
		echo "drydock guardrail: ssh to a production host is blocked (A1)." >&2
		echo "Use a deploy key or a jump host approved for production access." >&2
		exit 2
	fi
done

# ── Rule C12: fork bomb ────────────────────────────────────────────────────────
# Block: the classic :() { :|: & };: shape (colon-function recursion).
# Checked against full $cmd — the two pattern halves may straddle a ; but
# splitting would break the compound detection.
if [[ "$cmd" =~ :\(\)[[:space:]]*\{ ]] && [[ "$cmd" =~ :\|: ]]; then
	echo "drydock guardrail: fork bomb pattern detected and blocked (C12)." >&2
	exit 2
fi

# ── Rule C17: rm of . or .git (anchored at word boundary) ────────────────────
# Block: rm with a recursive flag where the target is exactly:
#   - .        (current directory)
#   - ./       (current directory with trailing slash, bare — not ./subdir)
#   - .git     (git directory, no extension or sub-path)
#   - .git/    (git directory with trailing slash)
# Allow: rm -rf ./subdir, rm -rf .gitignore, rm -rf .github/workflows
#
# Per-segment: the recursive flag and dangerous target must belong to the same
# rm invocation. Flags in an unrelated segment (e.g. ls -R) do not trigger.
#
# Two-part check (ordering-independent):
#   (a) rm is present AND any -r/-R flag is present anywhere in the segment;
#   (b) a space-preceded dot or .git target at word boundary is present.
# The two checks are ordering-independent: the flag regex
# [[:space:]](-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$) matches a recursive
# flag regardless of whether it appears before or after the target argument. The
# inner class is letters-only so it cannot consume a long flag's hyphens — e.g.
# --verbose is never mistaken for a recursive flag.
for _seg in "${_segments[@]}"; do
	if [[ "$_seg" =~ (^|[[:space:]])rm[[:space:]] ]] &&
		[[ "$_seg" =~ [[:space:]](-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$) ]]; then
		# Check for dot-only target: the argument is exactly "." (end or space after)
		if [[ "$_seg" =~ [[:space:]]\.($|[[:space:]]) ]]; then
			echo "drydock guardrail: rm of the current directory (.) is blocked (C17)." >&2
			echo "Specify the target explicitly (e.g. rm -rf ./build/)." >&2
			exit 2
		fi
		# Check for ./ bare target: "./" at end-of-string or followed by space.
		# Matches "rm -rf ./" but not "rm -rf ./tmp" (the 't' blocks the tail).
		if [[ "$_seg" =~ [[:space:]]\.\/($|[[:space:]]) ]]; then
			echo "drydock guardrail: rm of the current directory (./) is blocked (C17)." >&2
			echo "Specify the target explicitly (e.g. rm -rf ./build/)." >&2
			exit 2
		fi
		# Check for .git target: ".git" followed by optional "/" then end-of-string or space
		if [[ "$_seg" =~ [[:space:]]\.git(/)?($|[[:space:]]) ]]; then
			echo "drydock guardrail: rm of .git is blocked (C17)." >&2
			echo "Deleting .git destroys the repository history." >&2
			exit 2
		fi
	fi
done

# ── Rule C18: rm with ../ traversal or bare .. target ────────────────────────
# Block: rm with a recursive flag and a target containing ../ OR exactly ..
# Allow: rm -rf ./dist, rm -rf /absolute/path
#
# Per-segment: the recursive flag and dangerous target must belong to the same
# rm invocation. Flags in an unrelated segment (e.g. grep -r) do not trigger.
for _seg in "${_segments[@]}"; do
	if [[ "$_seg" =~ (^|[[:space:]])rm[[:space:]] ]] &&
		[[ "$_seg" =~ [[:space:]](-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$) ]]; then
		# Match ../ prefix (traversal into parent) OR bare .. (parent dir, no slash)
		if [[ "$_seg" =~ [[:space:]]\.\.(/|[[:space:]]|$) ]]; then
			echo "drydock guardrail: rm with parent-directory traversal is blocked (C18)." >&2
			echo "Specify the target with an absolute path or relative to the project root." >&2
			exit 2
		fi
	fi
done

# ── Rule A2: kubectl/helm destructive verb against a production context ──────
# Block: a kubectl/helm invocation that has BOTH a destructive verb
# (delete/destroy/uninstall/drain) AND a prod-scoped context. The prod marker
# is the VALUE of a --context / --kube-context / --namespace / -n flag — not a
# bare "prod" token. This keeps "kubectl delete pod prod-api -n dev" (prod in a
# resource name, dev namespace) out of the block set.
# Allow: kubectl get -n prod (read-only verb); kubectl delete pod foo -n dev.
#
# The flag/value separator is [[:space:]=]* (zero-or-more) so the attached
# short-flag form '-nprod' is matched alongside '-n prod' and '-n=prod'.
# Case-insensitive (nocasematch) so 'PROD'/'Production' match, mirroring A1.
#
# The match is checked per pipe-part, not per whole segment: a destructive
# verb in a command piped FROM a kubectl invocation (kubectl get … --context=prod
# | grep delete) must not be read as a kubectl subcommand. Splitting on '|'
# keeps the verb, the kubectl token, and the prod context within one real
# invocation. The verb itself is NOT position-anchored: kubectl accepts global
# flags before the subcommand (kubectl -n prod delete …), and anchoring to the
# token after kubectl+flags would miss that form (the '-n' value 'prod' sits
# between the flag and the verb). Residual: a destructive verb word used as a
# positional argument (a resource literally named 'delete') in a prod-context
# invocation still blocks — accepted accident-floor noise, same class as A1.
_a2_match() (
	local seg="$1"
	shopt -s nocasematch
	[[ "$seg" =~ (^|[[:space:]])(kubectl|helm)[[:space:]] ]] &&
		[[ "$seg" =~ [[:space:]](delete|destroy|uninstall|drain)([[:space:]]|$) ]] &&
		[[ "$seg" =~ [[:space:]](--context|--kube-context|--namespace|-n)[[:space:]=]*[^[:space:]]*prod ]]
)

for _seg in "${_segments[@]}"; do
	IFS='|' read -ra _a2_parts <<<"$_seg"
	for _a2_part in "${_a2_parts[@]}"; do
		if _a2_match "$_a2_part"; then
			echo "drydock guardrail: a kubectl/helm destructive verb against a production context is blocked (A2)." >&2
			echo "Target a non-production context, or perform production changes through your deployment pipeline." >&2
			exit 2
		fi
	done
done

# ── Rule A3: database CLI pointed at a production host ───────────────────────
# Block: a DB CLI (psql/mysql/mongo/mongosh/redis-cli) whose -h/--host value
# contains a prod/production token.
# Allow: a DB CLI against localhost, a dev host, or staging; a DB name that
# merely contains "prod" with no -h/--host flag.
#
# Separator [[:space:]=]* (zero-or-more) so the attached form '-hprod-db' is
# matched alongside '-h prod-db' and '--host=prod-db'. Case-insensitive
# (nocasematch) so an uppercase 'PROD-db' host token matches, mirroring A1.
#
# Per-segment: the DB CLI and the -h/--host flag must belong to the same call.
_a3_match() (
	local seg="$1"
	shopt -s nocasematch
	[[ "$seg" =~ (^|[[:space:]])(psql|mysql|mongo|mongosh|redis-cli)[[:space:]] ]] &&
		[[ "$seg" =~ [[:space:]](-h|--host)[[:space:]=]*[^[:space:]]*prod ]]
)

for _seg in "${_segments[@]}"; do
	if _a3_match "$_seg"; then
		echo "drydock guardrail: a database CLI pointed at a production host is blocked (A3)." >&2
		echo "Connect to a local or development database instead." >&2
		exit 2
	fi
done

# ── Rule A4: terraform apply/destroy ─────────────────────────────────────────
# Block: terraform with an apply or destroy subcommand. The deny layer covers
# the leading forms (terraform apply* / terraform destroy*); this rule is the
# backstop for forms with intervening flags (terraform -chdir=… destroy).
# Allow: terraform plan / output / validate / show (read-only subcommands);
# "apply"/"destroy" appearing as a positional argument rather than the
# subcommand (terraform show apply, terraform plan -out apply).
#
# The subcommand is anchored: 'terraform', then zero or more flag tokens
# (-chdir=…), then exactly the next token must be apply/destroy. This keeps
# apply/destroy as a non-subcommand argument or filename out of the block set.
#
# Per-segment: the terraform token and the subcommand must share a segment.
for _seg in "${_segments[@]}"; do
	if [[ "$_seg" =~ (^|[[:space:]])terraform[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(apply|destroy)([[:space:]]|$) ]]; then
		echo "drydock guardrail: terraform apply/destroy is blocked (A4)." >&2
		echo "Use 'terraform plan' to preview changes; apply through your infrastructure pipeline." >&2
		exit 2
	fi
done

# ── Rule C7-residue: sudo chmod with a world-writable mode ───────────────────
# Block: sudo chmod whose mode is world-writable —
#   - numeric: the final octal digit (others) carries the write bit, i.e. the
#     last digit of a 3- or 4-digit octal mode is one of 2/3/6/7;
#   - symbolic: a clause granting write to 'others' or 'all' (o+w, a+w, ugo+w,
#     o=rw, …). A 'u'/'g'-only clause (u+w, g+w) is NOT world-writable.
# Allow: sudo chmod 755 / 644 / 775 (no others-write bit); sudo chmod o-w
# (removes write); chmod WITHOUT sudo (out of scope per #76).
#
# A Bash(...) deny glob cannot inspect the others write bit — this is the hook
# residue for the otherwise glob-expressible C7 sudo set in 30-os-safety.json.
#
# A 'chmod --reference=FILE' invocation carries no literal mode (the mode is
# copied from FILE), so there is nothing for this rule to evaluate — it is
# skipped, which also avoids reading a clause-shaped target filename as a mode.
#
# Per-segment: the sudo token, the chmod token, and the mode share a segment.
for _seg in "${_segments[@]}"; do
	if [[ "$_seg" =~ (^|[[:space:]])sudo[[:space:]] ]] &&
		[[ "$_seg" =~ [[:space:]]chmod[[:space:]] ]] &&
		! [[ "$_seg" =~ [[:space:]]--reference ]]; then
		# Numeric: 3- or 4-digit octal mode whose final digit has the write bit.
		# Anchored to the mode argument — 'chmod', then zero or more flag tokens
		# (-R, -v, --reference=…), then the mode. Anchoring is what keeps a
		# numerically-named file argument (sudo chmod 755 222) out of the match:
		# the mode in that command is 755 (no others-write bit), and 222 is not
		# at the mode position.
		if [[ "$_seg" =~ (^|[[:space:]])chmod[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[0-7][0-7][0-7]?[2367]([[:space:]]|$) ]]; then
			echo "drydock guardrail: sudo chmod with a world-writable mode is blocked (C7-residue)." >&2
			echo "Grant the narrowest permissions needed — a world-writable mode lets any user modify the target." >&2
			exit 2
		fi
		# Symbolic: a clause whose who-list includes 'o' or 'a' and grants 'w'.
		# Anchored to the mode argument the same way the numeric branch is —
		# 'chmod', zero or more flag tokens, then the mode token. The leading
		# [^[:space:]]* lets the clause sit anywhere INSIDE the mode token, so a
		# comma-joined form (u=rw,o+w) still matches, while a filename argument
		# that resembles a clause (sudo chmod 644 a+w) does not.
		if [[ "$_seg" =~ (^|[[:space:]])chmod[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[^[:space:]]*[ugoa]*[oa][ugoa]*[+=][rwxXst]*w ]]; then
			echo "drydock guardrail: sudo chmod with a world-writable mode is blocked (C7-residue)." >&2
			echo "Grant the narrowest permissions needed — a world-writable mode lets any user modify the target." >&2
			exit 2
		fi
	fi
done

# ── Rule C20: curl/wget piped to shell ───────────────────────────────────────
# Block: curl or wget combined with a pipe to bash or sh in the same command.
# Allow: curl -o file.sh ..., curl https://api.example.com/data (no pipe to shell)
#
# Checked against full $cmd — C20 must see across pipes; do NOT split here.
#
# The curl/wget token check uses a non-alphabetic boundary (not just space) so
# that docker-wrapped payloads like 'docker run ... sh -c "curl ... | bash"' are
# also caught — the inner "curl" follows a '"' character, not a space.
# Similarly the trailing condition for bash/sh uses a non-alphabetic boundary so
# 'bash"' (quoted in a sh -c string) is still recognised as a shell invocation.
#
# An optional "sudo " bridge between the pipe and the shell is allowed so that
# "curl ... | sudo bash" is also blocked (FIX-4).
if [[ "$cmd" =~ (^|[^a-zA-Z])(curl|wget)([^a-zA-Z]|$) ]] &&
	[[ "$cmd" =~ \|[[:space:]]*(sudo[[:space:]]+)?(bash|sh)([^a-zA-Z]|$) ]]; then
	echo "drydock guardrail: piping curl/wget output directly into a shell is blocked (C20)." >&2
	echo "Download the script first (curl -o script.sh ...), inspect it, then run it." >&2
	exit 2
fi

exit 0
