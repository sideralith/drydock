#!/usr/bin/env bash
# drydock-block-destructive.sh — Claude Code PreToolUse hook for drydock containers.
#
# Blocks the five residue rule classes that the declarative deny layer cannot
# express without false-positives. All other rules ship as Bash(...) deny patterns
# in managed-settings drop-ins (10-git-safety.json, 30-os-safety.json).
#
# Rule residue (ADR-7):
#   A1  — ssh to a production host (ssh token AND prod/production hostname)
#   C12 — fork bomb (:() { :|: & };: shape)
#   C17 — rm of . or .git (anchored: no extension, no trailing path component)
#   C18 — rm with ../ traversal
#   C20 — curl/wget piped into bash/sh
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
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
[ "$tool_name" = "Bash" ] || exit 0

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

# Nothing to inspect if the command is empty.
[ -n "$cmd" ] || exit 0

# ── Rule A1: ssh to production host ──────────────────────────────────────────
# Block: ssh token AND a prod/production hostname token.
# Allow: ssh to dev, staging, or any non-production host.
if [[ "$cmd" =~ (^|[[:space:]])ssh[[:space:]] ]] && \
   [[ "$cmd" =~ (^|[[:space:]@./-])prod(uction)?([[:space:]@./-]|$) ]]; then
    echo "drydock guardrail: ssh to a production host is blocked (A1)." >&2
    echo "Use a deploy key or a jump host approved for production access." >&2
    exit 2
fi

# ── Rule C12: fork bomb ────────────────────────────────────────────────────────
# Block: the classic :() { :|: & };: shape (colon-function recursion).
if [[ "$cmd" =~ :\(\)[[:space:]]*\{ ]] && [[ "$cmd" =~ :\|: ]]; then
    echo "drydock guardrail: fork bomb pattern detected and blocked (C12)." >&2
    exit 2
fi

# ── Rule C17: rm of . or .git (anchored at word boundary) ────────────────────
# Block: rm with a recursive flag where the target is exactly:
#   - .        (current directory)
#   - .git     (git directory, no extension or sub-path)
#   - .git/    (git directory with trailing slash)
# Allow: rm -rf ./subdir, rm -rf .gitignore, rm -rf .github/workflows
#
# Two-part check: (a) rm is present AND any -r/-R flag is present;
# (b) a space-preceded dot or .git target at word boundary is present.
# The two-part split is necessary because "rm .+ -r pattern" would need
# a complex join that is fragile; the two separate checks are robust.
if [[ "$cmd" =~ (^|[[:space:]])rm[[:space:]] ]] && \
   [[ "$cmd" =~ [[:space:]]-[^[:space:]]*[rR] ]]; then
    # Check for dot-only target: the argument is exactly "." (end or space after)
    if [[ "$cmd" =~ [[:space:]]\.($|[[:space:]]) ]]; then
        echo "drydock guardrail: rm of the current directory (.) is blocked (C17)." >&2
        echo "Specify the target explicitly (e.g. rm -rf ./build/)." >&2
        exit 2
    fi
    # Check for .git target: ".git" followed by optional "/" then end-of-string or space
    if [[ "$cmd" =~ [[:space:]]\.git(/)?($|[[:space:]]) ]]; then
        echo "drydock guardrail: rm of .git is blocked (C17)." >&2
        echo "Deleting .git destroys the repository history." >&2
        exit 2
    fi
fi

# ── Rule C18: rm with ../ traversal ──────────────────────────────────────────
# Block: rm with a recursive flag and a target containing ../
# Allow: rm -rf ./dist, rm -rf /absolute/path
if [[ "$cmd" =~ (^|[[:space:]])rm[[:space:]] ]] && \
   [[ "$cmd" =~ [[:space:]]-[^[:space:]]*[rR] ]] && \
   [[ "$cmd" =~ [[:space:]]\.\./ ]]; then
    echo "drydock guardrail: rm with parent-directory traversal (../) is blocked (C18)." >&2
    echo "Specify the target with an absolute path or relative to the project root." >&2
    exit 2
fi

# ── Rule C20: curl/wget piped to shell ───────────────────────────────────────
# Block: curl or wget combined with a pipe to bash or sh in the same command.
# Allow: curl -o file.sh ..., curl https://api.example.com/data (no pipe to shell)
#
# The curl/wget token check uses a non-alphabetic boundary (not just space) so
# that docker-wrapped payloads like 'docker run ... sh -c "curl ... | bash"' are
# also caught — the inner "curl" follows a '"' character, not a space.
# Similarly the trailing condition for bash/sh uses a non-alphabetic boundary so
# 'bash"' (quoted in a sh -c string) is still recognised as a shell invocation.
if [[ "$cmd" =~ (^|[^a-zA-Z])(curl|wget)([^a-zA-Z]|$) ]] && \
   [[ "$cmd" =~ \|[[:space:]]*(bash|sh)([^a-zA-Z]|$) ]]; then
    echo "drydock guardrail: piping curl/wget output directly into a shell is blocked (C20)." >&2
    echo "Download the script first (curl -o script.sh ...), inspect it, then run it." >&2
    exit 2
fi

exit 0
