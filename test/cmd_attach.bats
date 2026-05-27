#!/usr/bin/env bats
# test/cmd_attach.bats — unit tests for cmd_attach in lib/commands.sh
#
# REQ-N5, REQ-6-M, REQ-7-M: drydock attach reconnects to a live container via
# compose exec ... claude --resume. Disambiguation: (a) explicit name → direct;
# (b) no arg + 1 session → direct; (c) no arg + N>1 + TTY → menu;
# (d) no arg + N>1 + no-TTY → list + exit 2. Nonexistent → error + exit non-zero.

load "helpers/load"

setup() {
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/commands.sh"

	ensure_prereqs() { :; }
	ensure_image() { :; }
	ensure_runtime_dirs() { :; }
	ensure_synced() { :; }

	# DOCKER seam.
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	# Default PROJECT_NAME for tests.
	export PROJECT_NAME="myproj"

	local tmpdir="$BATS_TEST_TMPDIR/myproj"
	mkdir -p "$tmpdir"
	cd "$tmpdir"
}

# ── Helper: build a docker stub that returns N sessions ──────────────────────

make_docker_stub_with_sessions() {
	local stub_dir="$BATS_TEST_TMPDIR/docker-stub-attach-$$-$RANDOM"
	mkdir -p "$stub_dir"
	local sessions_output="$1"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${DOCKER_CALL_LOG}"
if [ "\${1:-}" = "ps" ]; then
	printf '%s\n' "${sessions_output}"
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	printf '%s' "$stub_dir/docker"
}

# ── Scenario (a): explicit disc arg → direct attach ───────────────────────────

@test "cmd_attach: explicit disc arg → invokes compose exec with claude --resume (REQ-6-M)" {
	# GIVEN a live container drydock-myproj-ab12
	# WHEN cmd_attach ab12 is called with a TTY
	# THEN docker compose exec is called with claude --resume
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	# Simulate TTY presence — cmd_attach requires a TTY (FIX-5).
	_drydock_has_tty() { return 0; }

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	# Log format: "compose <args> exec -it drydock claude --resume"
	grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
	grep -q -- "--resume" "$DOCKER_CALL_LOG"
}

@test "cmd_attach: explicit disc arg → NO menu shown (REQ-7-M sub-scenario a)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	# Must not show disambiguation menu
	[[ "$output" != *"[1]"* ]]
}

# ── Scenario (a-no-tty): explicit disc + no TTY → exit 2 with friendly error ──

@test "cmd_attach: explicit disc arg + no TTY → exits 2 with friendly error (FIX-5)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	# Do NOT override _drydock_has_tty — tests run without a TTY by default.

	run cmd_attach "ab12" 2>&1
	[ "$status" -eq 2 ]
	[[ "$output" == *"TTY"* ]] || [[ "$output" == *"terminal"* ]] || [[ "$output" == *"tty"* ]]
}

# ── Scenario (b): no arg + exactly 1 live session → direct attach ─────────────

@test "cmd_attach: no arg + 1 live session → attach directly without menu (REQ-7-M sub-scenario b)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	run cmd_attach
	[ "$status" -eq 0 ]
	grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
	grep -q -- "--resume" "$DOCKER_CALL_LOG"
	[[ "$output" != *"[1]"* ]]
}

# ── Scenario (d): no arg + N>1 + no-TTY → list + exit 2 ──────────────────────

@test "cmd_attach: no arg + N>1 sessions + no-TTY → exit 2 (REQ-7-M sub-scenario d)" {
	# Two live sessions; stdin is not a TTY when run via 'run cmd_attach'.
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12
drydock-myproj-ef56")"
	export DOCKER="$stub"

	run cmd_attach
	[ "$status" -eq 2 ]
}

@test "cmd_attach: no arg + N>1 sessions + no-TTY → stderr lists sessions (REQ-7-M sub-scenario d)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12
drydock-myproj-ef56")"
	export DOCKER="$stub"

	run cmd_attach 2>&1
	# output (stderr redirected) should contain the session names
	[[ "$output" == *"drydock-myproj"* ]]
}

# ── Nonexistent name → error + exit non-zero (REQ-N5) ─────────────────────────

@test "cmd_attach: explicit nonexistent name → exits non-zero (REQ-N5)" {
	# No containers running for project.
	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"

	run cmd_attach "deadbeef"
	[ "$status" -ne 0 ]
}

@test "cmd_attach: explicit nonexistent name → error message on stderr (REQ-N5)" {
	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"

	run cmd_attach "deadbeef" 2>&1
	[[ "$output" == *"deadbeef"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"no"* ]]
}

# ── No sessions at all → error + exit non-zero ────────────────────────────────

@test "cmd_attach: no arg + 0 live sessions → exits non-zero (no session to attach)" {
	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"

	run cmd_attach
	[ "$status" -ne 0 ]
}

# ── Filter: only matches current project (SR-NEW-1) ──────────────────────────

@test "cmd_attach: does NOT attach to a different project's container (SR-NEW-1)" {
	# A container from a different project should not match.
	local stub
	# Return a container from a different project only
	stub="$(make_docker_stub_with_sessions "drydock-otherproject-ab12")"
	export DOCKER="$stub"

	# With no arg and only a different project's container, should exit non-zero
	run cmd_attach
	[ "$status" -ne 0 ]
}
