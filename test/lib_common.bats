#!/usr/bin/env bats
# test/lib_common.bats — unit tests for lib/common.sh output helpers
#
# Sources lib/common.sh directly (not bin/drydock). Proves the module is
# self-contained and its helpers behave correctly in isolation.

load "helpers/load"

setup() {
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
}

# ── DRYDOCK_VERSION ───────────────────────────────────────────────────────────

@test "DRYDOCK_VERSION is defined and non-empty" {
	[ -n "$DRYDOCK_VERSION" ]
}

# ── err ───────────────────────────────────────────────────────────────────────

@test "err exits with non-zero status" {
	run bash -c "source '$DRYDOCK_HOME/lib/common.sh'; err 'boom'"
	[ "$status" -ne 0 ]
}

@test "err writes to stderr" {
	run bash -c "source '$DRYDOCK_HOME/lib/common.sh'; err 'something wrong'" 2>&1
	[[ "$output" == *"something wrong"* ]]
}

# ── warn ──────────────────────────────────────────────────────────────────────

@test "warn writes to stderr" {
	run bash -c "source '$DRYDOCK_HOME/lib/common.sh'; warn 'heads up'" 3>&2 2>&1 1>&3
	[[ "$output" == *"heads up"* ]]
}

@test "warn exits 0" {
	run bash -c "source '$DRYDOCK_HOME/lib/common.sh'; warn 'heads up'"
	[ "$status" -eq 0 ]
}

# ── note ──────────────────────────────────────────────────────────────────────

@test "note writes to stdout" {
	run bash -c "source '$DRYDOCK_HOME/lib/common.sh'; note 'hello'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"hello"* ]]
}

# ── ok ────────────────────────────────────────────────────────────────────────

@test "ok writes to stdout" {
	run bash -c "source '$DRYDOCK_HOME/lib/common.sh'; ok 'done'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"done"* ]]
}
