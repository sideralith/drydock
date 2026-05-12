#!/usr/bin/env bash
# lib/paths.sh — DRYDOCK_HOME resolution, path constants, and MOUNTS_FILE seam
#
# Sourced by bin/drydock (the thin dispatcher). Never sourced directly by
# lib/*.sh siblings — let the dispatcher control the source order.

# ── MOUNTS_FILE seam ──────────────────────────────────────────────────────────
# Moved here from bin/drydock (was an inline seam in slice 1).
# Override in tests: export MOUNTS_FILE=/path/to/fixture before sourcing.
: "${MOUNTS_FILE:=/proc/mounts}"

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

# Returns 0 if $1 is a separate filesystem mount point (e.g. 9P drvfs sub-mount
# from Windows on WSL2). Used to decide whether to apply the docs/ overlay.
# /proc/mounts layout: <source> <mount_point> <fs_type> <options> <dump> <pass>
is_separate_mount() {
	local path="$1"
	[ -e "$path" ] || return 1
	awk -v target="$path" '$2 == target {found=1} END {exit !found}' "$MOUNTS_FILE"
}
