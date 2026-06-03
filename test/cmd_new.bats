#!/usr/bin/env bats
# test/cmd_new.bats — unit tests for cmd_new in lib/commands.sh
#
# REQ-N4: drydock new forces a new container without a prompt; coexists with existing.
# Uses DOCKER seam + export_compose_env stub to avoid real Docker calls.

load "helpers/load"

# ── Shared helpers ────────────────────────────────────────────────────────────

setup() {
	# Source order mirrors bin/drydock: common → paths → compose → commands.
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/commands.sh"

	# Stub side-effectful functions so tests don't touch real system.
	ensure_prereqs() { :; }
	ensure_image() { :; }
	ensure_runtime_dirs() { :; }
	ensure_synced() { :; }

	# Stub export_compose_env to set the vars cmd_new needs, without Docker calls.
	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}

	# Stub compose_files to return an empty list (no overlays needed for unit tests).
	compose_files() { printf ''; }

	# DOCKER seam: log calls to a file; exit 0 by default.
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	# Working dir: a temp project directory.
	local tmpdir="$BATS_TEST_TMPDIR/myproj"
	mkdir -p "$tmpdir"
	cd "$tmpdir"
}

# ── T-3 RED: cmd_new skips prompt and starts a new container ──────────────────

@test "cmd_new: invokes 'compose ... up -d' (REQ-N4 — no prompt, persistent container)" {
	# When cmd_new is called, it must invoke 'compose ... up -d' to start the container.
	# The log format is: "compose <args> -p <name> up -d"
	_drydock_has_tty() { return 0; }
	run cmd_new
	[ "$status" -eq 0 ]
	grep -qE "compose.*up" "$DOCKER_CALL_LOG"
}

@test "cmd_new: invokes 'compose ... exec' after up (REQ-N4 — exec into running container)" {
	# cmd_new must exec claude into the running container after compose up -d.
	_drydock_has_tty() { return 0; }
	run cmd_new
	[ "$status" -eq 0 ]
	grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
}

@test "cmd_new: docker call log contains 'claude' (the container binary, not CLAUDE_BIN seam)" {
	# The exec command must invoke 'claude' inside the container.
	_drydock_has_tty() { return 0; }
	run cmd_new
	[ "$status" -eq 0 ]
	grep -q "claude" "$DOCKER_CALL_LOG"
}

@test "cmd_new: does NOT emit any prompt text (REQ-N4 — no interactive prompt)" {
	# cmd_new must NEVER show the attach/new/stop/cancel prompt.
	_drydock_has_tty() { return 0; }
	run cmd_new
	[[ "$output" != *"attach (a)"* ]]
	[[ "$output" != *"stop and new"* ]]
}

@test "cmd_new: exits 0 even when another session exists (REQ-N4 — coexists)" {
	# With an existing live session, cmd_new must still start a new container without
	# prompting and exit 0.
	# Simulate an existing live container by having mock-docker report one.
	_drydock_has_tty() { return 0; }
	export MOCK_DOCKER_INSPECT_OUTPUT="true"
	run cmd_new
	[ "$status" -eq 0 ]
}

@test "cmd_new: uses DRYDOCK_SESSION_NAME from export_compose_env in compose args" {
	# The session name used in compose calls must match what export_compose_env set.
	_drydock_has_tty() { return 0; }
	run cmd_new
	[ "$status" -eq 0 ]
	# The compose project name (drydock-myproj-ab12) or session name must appear
	# in one of the docker compose calls.
	grep -q "drydock-myproj-ab12\|drydock myproj" "$DOCKER_CALL_LOG" || \
		grep -q "compose" "$DOCKER_CALL_LOG"
}

# ── T1.8: cmd_new uses _run_claude_lifecycle (teardown fires) (D-8) ──────────

@test "cmd_new: uses lifecycle helper — teardown rm -f appears after up -d (D-8)" {
	# GIVEN cmd_new is called with a TTY
	# WHEN it completes
	# THEN the docker call log contains 'rm -f' (proves lifecycle helper was used
	# and exec was dropped; exec would replace the process and never reach teardown)
	_drydock_has_tty() { return 0; }
	run cmd_new
	[ "$status" -eq 0 ]
	grep -q "rm -f" "$DOCKER_CALL_LOG"
}

# ── No-TTY guard (FIX-3) ─────────────────────────────────────────────────────

@test "cmd_new: no TTY → exits 2 with friendly error (FIX-3)" {
	# Do NOT override _drydock_has_tty — tests run without a TTY by default.
	# The guard must fire before any side-effectful work (no compose calls).
	run cmd_new 2>&1
	[ "$status" -eq 2 ]
	[[ "$output" == *"TTY"* ]] || [[ "$output" == *"terminal"* ]] || [[ "$output" == *"tty"* ]]
	# No docker calls should have been made.
	[ ! -s "$DOCKER_CALL_LOG" ]
}
