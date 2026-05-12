#!/usr/bin/env bash
# lib/paths.sh — DRYDOCK_HOME resolution, path constants, and MOUNTS_FILE seam
#
# Sourced by bin/drydock (the thin dispatcher). Never sourced directly by
# lib/*.sh siblings — let the dispatcher control the source order.

# ── MOUNTS_FILE seam ──────────────────────────────────────────────────────────
# Moved here from bin/drydock (was an inline seam in slice 1).
# Override in tests: export MOUNTS_FILE=/path/to/fixture before sourcing.
: "${MOUNTS_FILE:=/proc/mounts}"

# ── OS-detection seams ────────────────────────────────────────────────────────
# Override in tests to simulate macOS or plain-Linux CI without the real kernel.
#   export OSRELEASE_FILE=/path/to/fixture   (default: /proc/sys/kernel/osrelease)
#   export UNAME=/path/to/stub-script        (default: uname)
: "${OSRELEASE_FILE:=/proc/sys/kernel/osrelease}"
: "${UNAME:=uname}"

# ── Path constants ────────────────────────────────────────────────────────────
# DRYDOCK_HOME is set by the inline bootstrap in bin/drydock before this file
# is sourced, so these references are safe at source time.
# shellcheck disable=SC2034  # used in lib/commands.sh (cmd_setup, cmd_sync)
HOST_CLAUDE="$HOME/.claude"
# shellcheck disable=SC2034  # used in lib/commands.sh
CONTAINER_CLAUDE="$HOME/.claude-container"
# shellcheck disable=SC2034  # used in lib/commands.sh
HOST_CLAUDE_JSON="$HOME/.claude.json"
# shellcheck disable=SC2034  # used in lib/commands.sh
CONTAINER_CLAUDE_JSON="$HOME/.claude-container.json"
# shellcheck disable=SC2034  # used in lib/commands.sh
HOST_ENGRAM="$HOME/.engram"
# shellcheck disable=SC2034  # used in lib/commands.sh
CONTAINER_ENGRAM="$HOME/.engram-container"

# ── Functions ─────────────────────────────────────────────────────────────────

# resolve_drydock_home — follow symlinks to find the real script location.
# Intentionally duplicated here (same logic as the inline bootstrap in
# bin/drydock) so slice-3 unit tests can call it in isolation without
# executing the full dispatcher.
resolve_drydock_home() {
	local src="$1"
	local dir
	while [ -L "$src" ]; do
		dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
		src="$(readlink "$src")"
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd -P "$(dirname "$src")/.." >/dev/null 2>&1 && pwd
}

resolve_project_dir() {
	local input="${1:-}"
	if [ -z "$input" ]; then
		pwd
	elif [ -d "$input" ]; then
		(cd "$input" && pwd)
	else
		err "directorio no existe: $input"
	fi
}

# Returns 0 if the host OS is Linux (uname -s = Linux).
# False on macOS (Darwin). WSL2 counts as Linux here — the macOS gate is about
# whether the host engram binary can run in the Linux container, not WSL2 risk.
host_is_linux() {
	[ "$("$UNAME" -s)" = "Linux" ]
}

# Returns 0 if the host's container bind-mount layer has unreliable POSIX file
# locks — WSL2 (9P bridge) or macOS (virtiofs/gRPC-FUSE). Used to decide
# whether shared engram DB mode is safe to activate.
# Guard: reads $OSRELEASE_FILE only when it exists (file absent on macOS).
host_fs_locks_unreliable() {
	if [ -r "$OSRELEASE_FILE" ] && grep -qi microsoft "$OSRELEASE_FILE"; then
		return 0
	fi
	[ "$("$UNAME" -s)" = "Darwin" ]
}

# Returns 0 if $1 is a separate filesystem mount point (e.g. 9P drvfs sub-mount
# from Windows on WSL2). Used to decide whether to apply the docs/ overlay.
# /proc/mounts layout: <source> <mount_point> <fs_type> <options> <dump> <pass>
is_separate_mount() {
	local path="$1"
	[ -e "$path" ] || return 1
	awk -v target="$path" '$2 == target {found=1} END {exit !found}' "$MOUNTS_FILE"
}
