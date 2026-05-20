#!/usr/bin/env bash
# drydock-session-start.sh — Claude Code SessionStart hook for drydock containers.
#
# Delivers session context to Claude: identity markers, security framing (INV-6),
# and live probes (noexec /tmp, tool availability).
#
# HOST-SAFETY GUARD (design D-3): this script is absent on the host; the guard in
# settings.json's hook command uses `[ -x /opt/drydock/hooks/drydock-session-start.sh ]`
# so host sessions never reach here. Nonetheless, a belt-and-suspenders guard is
# kept below so the script is idempotent even if invoked directly on a host.
#
# SEAMS (design D-5, mirrors lib/paths.sh:14):
#   DRYDOCK_RELEASE_FILE — defaults to /etc/drydock-release; override in tests
#   MOUNTINFO_FILE       — defaults to /proc/self/mountinfo; override in tests

set -euo pipefail

: "${DRYDOCK_RELEASE_FILE:=/etc/drydock-release}"
: "${MOUNTINFO_FILE:=/proc/self/mountinfo}"

# Exit silently on the host (no marker file → not inside a drydock container).
[ -f "$DRYDOCK_RELEASE_FILE" ] || exit 0

# ── STATIC BLOCK ──────────────────────────────────────────────────────────────
# Always emitted when running inside a drydock container.

cat <<'STATIC'
## drydock container context

You are running inside a drydock container (containerized Claude Code workspace).

### Security framing (INV-1 — credential isolation)
~/.ssh and ~/.gnupg are deliberately NOT mounted in this container. This is a
feature, not a bug: it prevents agents from accessing the host's primary SSH and
GPG identities. Deploy keys live under ~/.config/drydock/keys/<project>_deploy and
are mounted via the optional SSH overlay when needed.

### Security framing (INV-6 — Docker socket)
The Docker socket is bind-mounted from the host. Any process with socket access can run
`docker run -v /:/host --privileged` — this is root-equivalent host access, not a security sandbox.
drydock defends against agent accidents (typos, runaway loops), not adversaries.
Do not treat this container as an adversarial sandbox.

### GPG commit signing
GPG commit signing is disabled by default inside the container (GIT_CONFIG_VALUE_0=false).
The optional GPG overlay (docker-compose.gpg.yml) enables signing with a sandbox key.

### GitHub CLI cache workaround
The gh CLI needs a writable cache directory. Use XDG_CACHE_HOME=/tmp/ghcache before
gh commands if you see cache-related errors:
  XDG_CACHE_HOME=/tmp/ghcache gh <command>
STATIC

# ── LIVE BLOCK ────────────────────────────────────────────────────────────────
# Dynamic probes emitted after the static block.

echo ""
echo "### Environment probes"

# -- /tmp noexec probe (uses /proc/self/mountinfo, no external tool) -----------
# Field 5 in mountinfo is the mount point; per-mount options are field 6.
# We grep for a line whose 5th whitespace-delimited field is exactly "/tmp"
# AND whose 6th field (options) contains "noexec".
if [ -r "$MOUNTINFO_FILE" ]; then
	if awk '{ if ($5 == "/tmp" && $6 ~ /noexec/) found=1 } END { exit !found }' "$MOUNTINFO_FILE" 2>/dev/null; then
		echo ""
		echo "WARNING: /tmp is mounted noexec. Running \`bats test/\` directly will fail."
		echo "Use \`scripts/test.sh\` instead (it runs bats from a writable tmp location)."
	fi
fi

# -- Tool availability probes --------------------------------------------------
_missing=""
for _tool in bats shellcheck shfmt; do
	if ! command -v "$_tool" >/dev/null 2>&1; then
		_missing="${_missing:+$_missing, }$_tool"
	fi
done

if [ -n "$_missing" ]; then
	echo ""
	echo "Tools not found in PATH: $_missing"
	echo "Run via scripts/test.sh (installs bats/shellcheck/shfmt on demand via npx)."
fi
unset _tool _missing

exit 0
