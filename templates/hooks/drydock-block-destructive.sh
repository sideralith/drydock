#!/usr/bin/env bash
# drydock-block-destructive.sh — Claude Code PreToolUse hook for drydock containers.
#
# Blocks the six residue rule classes that the declarative deny layer cannot
# express without false-positives. All other rules ship as Bash(...) deny patterns
# in managed-settings drop-ins (10-git-safety.json, 30-os-safety.json).
#
# Rule residue (ADR-7):
#   A1       — ssh to a production host (ssh token AND prod/production hostname)
#   C1-res   — rm with ANY recursive flag form (-r/-R/-rf/-Rf/-fr/-fR and bundled)
#              targeting a system path root (/, /etc, /usr, /var, /boot, /opt,
#              /lib, /lib32, /lib64, /sbin, /bin, /sys, /proc, /dev, /root, /home).
#              Token-bounded: /home/me/project is NOT blocked. This is the hook
#              backstop for flag-order-reversed forms (-fR, -fr) and uppercase-R
#              forms that cannot be expressed as Bash(...) globs because *-r* only
#              matches a literal lowercase 'r'. The deny layer covers *-r* and *-R*
#              for the common flag orderings; this rule catches the residue.
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
