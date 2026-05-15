#!/usr/bin/env bash
# lib/paths.sh — DRYDOCK_HOME resolution, path constants, and MOUNTS_FILE seam
#
# Sourced by bin/drydock (the thin dispatcher). Never sourced directly by
# lib/*.sh siblings — let the dispatcher control the source order.

# ── MOUNTS_FILE seam ──────────────────────────────────────────────────────────
# Moved here from bin/drydock (was an inline seam in slice 1).
# Override in tests: export MOUNTS_FILE=/path/to/fixture before sourcing.
: "${MOUNTS_FILE:=/proc/mounts}"

# ── MOUNTINFO_FILE seam ───────────────────────────────────────────────────────
# Override in tests: export MOUNTINFO_FILE=/path/to/fixture before sourcing.
: "${MOUNTINFO_FILE:=/proc/self/mountinfo}"

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

# detect_submounts — enumerate sub-mounts of $1 visible in $MOUNTINFO_FILE,
# emit one pipe-delimited record per sub-mount:
#   <docker-source>|<mount-point>|<class>
# Classes:
#   drvfs         — 9p WSL2 drvfs; source translated to /mnt/<letter>/...
#   linux-native  — ext4/btrfs/xfs/zfs/f2fs/reiserfs/ext3/ext2 bind; source
#                   translated via major:minor reverse-lookup. If the source
#                   FS row is not found, docker-source is left EMPTY —
#                   generate_submount_overlay() skips empty-source rows and
#                   warns. (tmpfs/overlay are NOT in this list — classified
#                   exotic; see classify() below.)
#   exotic:<fst>  — nfs/cifs/fuse/tmpfs/overlay/etc.; source passed through;
#                   generate_submount_overlay() emits a warn per row.
# Output is sorted by mount-point (col 2) parent-before-child, then
# deduplicated by mount-point. WSL2 occasionally stacks duplicate 9p
# mounts on the same target (post-reboot mount-replay or repeated
# `mount --bind` without unmount). Emitting both would generate
# duplicate volume entries in the compose overlay, which Docker
# Compose rejects. First occurrence (post-sort) wins.
detect_submounts() {
	local project_dir="$1"
	[ -r "$MOUNTINFO_FILE" ] || return 0

	# Pass 1: build major:minor → mountpoint map for rows where fsroot=="/".
	local fs_map
	fs_map=$(awk '
		{
			i = index($0, " - ")
			if (i == 0) next
			pre = substr($0, 1, i - 1)
			split(pre, p, " ")
			if (p[4] == "/") { printf "%s=%s\n", p[3], p[5] }
		}
	' "$MOUNTINFO_FILE")

	# Pass 2: emit sub-mounts of project_dir, classify, translate.
	awk -v root="$project_dir" -v fsmap="$fs_map" '
		BEGIN {
			n = split(fsmap, lines, "\n")
			for (k = 1; k <= n; k++) {
				if (lines[k] == "") continue
				eq = index(lines[k], "=")
				if (eq > 0) FS_MOUNT[substr(lines[k], 1, eq - 1)] = substr(lines[k], eq + 1)
			}
		}
		{
			i = index($0, " - ")
			if (i == 0) next
			pre  = substr($0, 1, i - 1)
			post = substr($0, i + 3)
			split(pre, p, " ")
			split(post, q, " ")

			major_minor = p[3]
			fsroot      = unescape(p[4])
			mount_point = unescape(p[5])
			fstype      = q[1]
			source_fs   = q[2]
			super_opts  = q[3]

			if (mount_point == root) next
			if (index(mount_point, root "/") != 1) next

			class = classify(fstype, super_opts)
			docker_src = translate(class, fsroot, super_opts, source_fs, FS_MOUNT[major_minor])
			label = (class == "exotic") ? "exotic:" fstype : class
			printf "%s|%s|%s\n", docker_src, mount_point, label
		}

		function unescape(s,   r) { r = s; gsub(/\\040/, " ", r); return r }
		function classify(t, o) {
			if (t == "9p" && index(o, "aname=drvfs") > 0) return "drvfs"
			# Linux-native allowlist: real block-backed filesystems only.
			# tmpfs and overlay are intentionally NOT here — they classify as
			# exotic. major:minor reverse-lookup for tmpfs would resolve to
			# unrelated tmpfs mountpoints (/run, /dev/shm); overlay is the
			# docker layer FS, not a user bind source. (Fix T2.)
			if (t == "ext4" || t == "btrfs" || t == "xfs" || t == "zfs" || \
			    t == "f2fs" || t == "reiserfs" || t == "ext3" || t == "ext2") return "linux-native"
			return "exotic"
		}
		function translate(c, fsr, o, src, src_mp,    letter) {
			if (c == "drvfs") {
				# Regex anchors on [A-Za-z]: — matches with or without trailing \.
				if (match(o, /path=[A-Za-z]:/)) {
					letter = tolower(substr(o, RSTART + 5, 1))
					return "/mnt/" letter fsr
				}
				return src
			}
			if (c == "linux-native") {
				# Empty source-FS row → return EMPTY so shell layer skip+warns.
				# Returning src (block device) is useless to Docker; returning
				# fsr alone may point at a non-existent host path. (Fix C3.)
				if (src_mp == "") return ""
				if (src_mp == "/") return fsr
				return src_mp fsr
			}
			return src   # exotic — pass-through
		}
	' "$MOUNTINFO_FILE" | sort -t'|' -k2,2 | awk -F'|' '!seen[$2]++'
}
