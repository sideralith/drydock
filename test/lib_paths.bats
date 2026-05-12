#!/usr/bin/env bats
# test/lib_paths.bats — unit tests for lib/paths.sh
#
# Sources lib/common.sh + lib/paths.sh directly (not bin/drydock). Proves each
# function works correctly in isolation, with DRYDOCK_HOME already set by the
# inline bootstrap in bin/drydock (not needed here — we set it via load.bash).

load "helpers/load"

setup() {
	# lib/paths.sh reads $DRYDOCK_HOME for nothing at source time — it only
	# defines constants relative to $HOME. Source order: common first so err()
	# is available when resolve_project_dir branches on nonexistent input.
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
}

# ── resolve_drydock_home ──────────────────────────────────────────────────────

@test "resolve_drydock_home: resolves bin/drydock to the repo root" {
	result="$(resolve_drydock_home "$DRYDOCK_HOME/bin/drydock")"
	[ "$result" = "$DRYDOCK_HOME" ]
}

@test "resolve_drydock_home: result is an absolute path" {
	result="$(resolve_drydock_home "$DRYDOCK_HOME/bin/drydock")"
	[[ "$result" == /* ]]
}

@test "resolve_drydock_home: result is a non-empty string" {
	result="$(resolve_drydock_home "$DRYDOCK_HOME/bin/drydock")"
	[ -n "$result" ]
}

# ── resolve_project_dir ───────────────────────────────────────────────────────

@test "resolve_project_dir: empty arg returns cwd" {
	expected="$(pwd)"
	result="$(resolve_project_dir)"
	[ "$result" = "$expected" ]
}

@test "resolve_project_dir: valid directory arg returns its absolute path" {
	result="$(resolve_project_dir "$BATS_TEST_TMPDIR")"
	[ "$result" = "$BATS_TEST_TMPDIR" ]
}

@test "resolve_project_dir: valid directory returns an absolute path" {
	result="$(resolve_project_dir "$BATS_TEST_TMPDIR")"
	[[ "$result" == /* ]]
}

@test "resolve_project_dir: nonexistent dir exits non-zero" {
	run resolve_project_dir "/this/path/does/not/exist/ever"
	[ "$status" -ne 0 ]
}

@test "resolve_project_dir: nonexistent dir output contains error text" {
	run resolve_project_dir "/this/path/does/not/exist/ever"
	[[ "$output" == *"no existe"* ]]
}

# ── is_separate_mount ─────────────────────────────────────────────────────────

setup_mounts_fixture() {
	# Create a real directory that will appear as a mount point.
	MOUNTED_DIR="$BATS_TEST_TMPDIR/mounted"
	mkdir -p "$MOUNTED_DIR"

	# Another dir that exists but is NOT in the fixture.
	OTHER_DIR="$BATS_TEST_TMPDIR/other"
	mkdir -p "$OTHER_DIR"

	# Synthetic /proc/mounts — second field is the mount point.
	SYNTHETIC_MOUNTS="$BATS_TEST_TMPDIR/proc-mounts"
	cat >"$SYNTHETIC_MOUNTS" <<MOUNTS
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
drvfs $MOUNTED_DIR 9p rw,noatime,uid=1000,gid=1000 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev 0 0
MOUNTS

	export MOUNTS_FILE="$SYNTHETIC_MOUNTS"
}

@test "is_separate_mount: path in fixture returns exit 0" {
	setup_mounts_fixture
	run is_separate_mount "$MOUNTED_DIR"
	[ "$status" -eq 0 ]
}

@test "is_separate_mount: existing dir NOT in fixture returns non-zero" {
	setup_mounts_fixture
	run is_separate_mount "$OTHER_DIR"
	[ "$status" -ne 0 ]
}

@test "is_separate_mount: nonexistent path returns non-zero" {
	setup_mounts_fixture
	run is_separate_mount "/nonexistent/path/that/does/not/exist"
	[ "$status" -ne 0 ]
}

@test "is_separate_mount: MOUNTS_FILE with no entries returns non-zero for any real dir" {
	empty_mounts="$BATS_TEST_TMPDIR/empty-mounts"
	mkdir -p "$BATS_TEST_TMPDIR/somedir"
	cat >"$empty_mounts" <<'MOUNTS'
sysfs /sys sysfs rw 0 0
MOUNTS
	export MOUNTS_FILE="$empty_mounts"
	run is_separate_mount "$BATS_TEST_TMPDIR/somedir"
	[ "$status" -ne 0 ]
}

# ── host_is_linux ─────────────────────────────────────────────────────────────
# Uses UNAME seam so macOS / Linux branches are testable on any CI runner.

setup_uname_stub() {
	local retval="$1"
	local stub_dir="$BATS_TEST_TMPDIR/uname-stub-$$"
	mkdir -p "$stub_dir"
	printf '#!/usr/bin/env bash\necho "%s"\n' "$retval" >"$stub_dir/uname"
	chmod +x "$stub_dir/uname"
	echo "$stub_dir/uname"
}

@test "host_is_linux: returns 0 on Linux (default uname)" {
	# Real uname on this runner is Linux (WSL2 is still Linux for uname -s).
	# UNAME seam was set to 'uname' by lib/paths.sh sourcing in setup().
	run host_is_linux
	[ "$status" -eq 0 ]
}

@test "host_is_linux: returns non-zero when UNAME stub returns Darwin" {
	stub="$(setup_uname_stub Darwin)"
	export UNAME="$stub"
	run host_is_linux
	[ "$status" -ne 0 ]
}

# ── host_fs_locks_unreliable ──────────────────────────────────────────────────
# Uses both OSRELEASE_FILE and UNAME seams.

setup_osrelease_fixture() {
	local content="$1"
	local fixture="$BATS_TEST_TMPDIR/osrelease-$$"
	printf '%s\n' "$content" >"$fixture"
	echo "$fixture"
}

@test "host_fs_locks_unreliable: returns 0 when osrelease contains 'microsoft' (WSL2)" {
	fixture="$(setup_osrelease_fixture "6.6.87.2-microsoft-standard-WSL2")"
	export OSRELEASE_FILE="$fixture"
	unset UNAME
	run host_fs_locks_unreliable
	[ "$status" -eq 0 ]
}

@test "host_fs_locks_unreliable: returns non-zero on plain Linux (no microsoft in osrelease)" {
	fixture="$(setup_osrelease_fixture "6.5.0-45-generic")"
	export OSRELEASE_FILE="$fixture"
	stub="$(setup_uname_stub Linux)"
	export UNAME="$stub"
	run host_fs_locks_unreliable
	[ "$status" -ne 0 ]
}

@test "host_fs_locks_unreliable: returns 0 when UNAME stub returns Darwin" {
	# macOS: osrelease file absent (guard must not error); uname→Darwin triggers
	export OSRELEASE_FILE="$BATS_TEST_TMPDIR/no-such-osrelease-file"
	stub="$(setup_uname_stub Darwin)"
	export UNAME="$stub"
	run host_fs_locks_unreliable
	[ "$status" -eq 0 ]
}
