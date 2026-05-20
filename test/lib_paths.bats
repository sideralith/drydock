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

# ── DRYDOCK_DISCRIMINATOR_FN seam ─────────────────────────────────────────────

@test "discriminator seam: DRYDOCK_DISCRIMINATOR_FN defaults to _gen_discriminator" {
	[ "$DRYDOCK_DISCRIMINATOR_FN" = "_gen_discriminator" ]
}

@test "discriminator seam: _gen_discriminator emits exactly 4 hex chars" {
	result="$(_gen_discriminator)"
	[[ "$result" =~ ^[0-9a-f]{4}$ ]]
}

@test "discriminator seam: _gen_discriminator output is 4 characters long" {
	result="$(_gen_discriminator)"
	[ "${#result}" -eq 4 ]
}

@test "discriminator seam: DRYDOCK_DISCRIMINATOR_FN override is respected" {
	_fixed_disc() { printf 'cafe'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc
	result="$("$DRYDOCK_DISCRIMINATOR_FN")"
	[ "$result" = "cafe" ]
}
