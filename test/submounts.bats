#!/usr/bin/env bats
# test/submounts.bats — unit tests for detect_submounts() and the warn
# behaviour of generate_submount_overlay().
#
# R3-W1 fix: scenarios 5 and 11 use 'run --separate-stderr' (bats >= 1.5,
# pinned at 1.13.0 in this project) to capture stderr from generate_submount_overlay
# separately. The function writes YAML to $SUBMOUNT_OVERLAY (not stdout) and
# emits warnings via the shell 'warn' helper to stderr.

load "helpers/load"

# R3-W1: scenarios 5 and 11 use 'run --separate-stderr' which requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"

	FIX="$DRYDOCK_HOME/test/fixtures"

	TEST_PROJECT="$BATS_TEST_TMPDIR/proj"
	mkdir -p "$TEST_PROJECT"
}

@test "drvfs C: drive letter translated to /mnt/c/... (production path=C:\\ form)" {
	export MOUNTINFO_FILE="$FIX/mountinfo-drvfs-c.txt"
	mkdir -p "$BATS_TEST_TMPDIR/serendipilink"
	run detect_submounts "/home/rai/git/serendipilink"
	[ "$status" -eq 0 ]
	[[ "$output" == *"/mnt/c/Users/Rai/Documents/Obsidian/Vaults/Serendipilink|/home/rai/git/serendipilink/docs|drvfs"* ]]
}

@test "drvfs D: drive letter translated to /mnt/d/... (production path=D:\\ form)" {
	export MOUNTINFO_FILE="$FIX/mountinfo-drvfs-d.txt"
	run detect_submounts "/home/rai/git/serendipilink"
	[ "$status" -eq 0 ]
	[[ "$output" == *"/mnt/d/Projects/data|/home/rai/git/serendipilink/data|drvfs"* ]]
}

@test "linux-native bind with source FS at / — fsroot returned unchanged" {
	export MOUNTINFO_FILE="$FIX/mountinfo-linux-bind-root.txt"
	run detect_submounts "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	[[ "$output" == *"/tmp/linux-bind-src|/home/rai/git/proj/bind|linux-native"* ]]
}

@test "linux-native bind with source FS at /data — fsroot prefixed" {
	export MOUNTINFO_FILE="$FIX/mountinfo-linux-bind-mounted.txt"
	run detect_submounts "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	[[ "$output" == *"/data/foo|/home/rai/git/proj/bind|linux-native"* ]]
}

@test "exotic nfs — pass-through source + exotic class + warn from overlay" {
	export MOUNTINFO_FILE="$FIX/mountinfo-nfs.txt"
	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/submount.yml"

	run detect_submounts "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	[[ "$output" == *"server:/export|/home/rai/git/proj/nfsmount|exotic:nfs"* ]]

	# R3-W1 fix: use --separate-stderr to capture warn() output from generate_submount_overlay.
	# generate_submount_overlay writes YAML to $SUBMOUNT_OVERLAY (not stdout);
	# warnings go to stderr via the 'warn' helper. bats 'run' without --separate-stderr
	# captures stdout only, leaving $output empty despite correct implementation.
	run --separate-stderr generate_submount_overlay "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"nfsmount"* ]]
	[[ "$stderr" == *"nfs"* ]]
}

@test "project_dir itself excluded (exact match, not prefix)" {
	export MOUNTINFO_FILE="$FIX/mountinfo-project-itself.txt"
	run detect_submounts "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "\\040 escape un-escaped to literal space" {
	export MOUNTINFO_FILE="$FIX/mountinfo-spaces.txt"
	run detect_submounts "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	[[ "$output" == *"/tmp/with spaces|/home/rai/git/proj/with spaces|linux-native"* ]]
}

@test "no sub-mounts under project_dir — empty output" {
	export MOUNTINFO_FILE="$FIX/mountinfo-no-submounts.txt"
	run detect_submounts "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "nested sub-mounts — parent listed before child" {
	export MOUNTINFO_FILE="$FIX/mountinfo-nested.txt"
	run detect_submounts "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	parent_line=$(echo "$output" | grep -n '|/home/rai/git/proj/docs|' | head -1 | cut -d: -f1)
	child_line=$(echo "$output" | grep -n '|/home/rai/git/proj/docs/sub|' | head -1 | cut -d: -f1)
	[ -n "$parent_line" ]
	[ -n "$child_line" ]
	[ "$parent_line" -lt "$child_line" ]
}

@test "optional fields between options and separator are tolerated (shared:N master:N)" {
	export MOUNTINFO_FILE="$FIX/mountinfo-optional-fields.txt"
	run detect_submounts "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	[[ "$output" == *"/tmp/shared-bind|/home/rai/git/proj/shared|linux-native"* ]]
}

@test "linux-native fallback: orphan major:minor — row emitted with empty docker-source" {
	export MOUNTINFO_FILE="$FIX/mountinfo-orphan-major-minor.txt"
	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/submount.yml"
	run detect_submounts "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	# Row is emitted with EMPTY docker-source (leading pipe) — design §2.1
	[[ "$output" == *"|/home/rai/git/proj/orphan|linux-native"* ]]
	# R3-W1 fix: use --separate-stderr to capture warn() output from generate_submount_overlay.
	# generate_submount_overlay writes YAML to $SUBMOUNT_OVERLAY (not stdout);
	# warnings go to stderr via the 'warn' helper.
	run --separate-stderr generate_submount_overlay "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"source FS root not found"* ]]
	[ ! -f "$SUBMOUNT_OVERLAY" ] || ! grep -q "orphan" "$SUBMOUNT_OVERLAY"
}

@test "tmpfs source: classified as exotic:tmpfs — NOT linux-native" {
	export MOUNTINFO_FILE="$FIX/mountinfo-tmpfs-bind.txt"
	run detect_submounts "/home/rai/git/proj"
	[ "$status" -eq 0 ]
	[[ "$output" == *"|/home/rai/git/proj/tmpfs-bind|exotic:tmpfs"* ]]
}

@test "duplicate 9p mounts on same target — deduplicated to one row" {
	# WSL2 occasionally stacks a second 9p mount on the same target (post-reboot
	# mount replay or repeated `mount --bind` without unmount). detect_submounts
	# must emit only ONE row for that target — otherwise generate_submount_overlay
	# would write duplicate volume entries and Docker Compose rejects the overlay.
	export MOUNTINFO_FILE="$FIX/mountinfo-duplicate-drvfs.txt"
	run detect_submounts "/home/rai/git/serendipilink"
	[ "$status" -eq 0 ]
	# Exactly ONE line containing the mount point, not two.
	count=$(printf '%s\n' "$output" | grep -c '|/home/rai/git/serendipilink/docs|' || true)
	[ "$count" -eq 1 ]
}
