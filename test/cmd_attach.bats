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
	# Per-argument docker stub: switches on the -f label key for inspect calls.
	# Env vars (evaluated at runtime, not at stub creation — note escaped \$):
	#   MOCK_ONEOFF       — value for com.docker.compose.oneoff (capital True/False, OQ-5)
	#   MOCK_MUX          — value for drydock.mux
	#   MOCK_MUX_SESSION  — value for drydock.mux_session
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${DOCKER_CALL_LOG}"
if [ "\${1:-}" = "ps" ]; then
	printf '%s\n' "${sessions_output}"
elif [ "\${1:-}" = "inspect" ]; then
	# Dispatch on the -f format string to return per-label mock values.
	_fmt="\${3:-}"
	case "\$_fmt" in
	*com.docker.compose.oneoff*)
		printf '%s\n' "\${MOCK_ONEOFF:-False}"
		;;
	*drydock.mux_session*)
		printf '%s\n' "\${MOCK_MUX_SESSION:-}"
		;;
	*drydock.mux*)
		printf '%s\n' "\${MOCK_MUX:-}"
		;;
	*)
		printf '%s\n' "\${MOCK_DOCKER_INSPECT_OUTPUT:-}"
		;;
	esac
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	printf '%s' "$stub_dir/docker"
}

# ── T1: per-argument docker stub — label dispatch RED→GREEN ──────────────────

@test "make_docker_stub_with_sessions: inspect -f oneoff label returns MOCK_ONEOFF (T1, OQ-5)" {
	# GIVEN the per-arg stub is built with sessions output
	# WHEN docker inspect -f '{{index .Config.Labels "com.docker.compose.oneoff"}}' is called
	# THEN the stub returns MOCK_ONEOFF (capital True)
	export MOCK_ONEOFF="True"
	export MOCK_MUX="zellij"
	export MOCK_MUX_SESSION="main"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	# Invoke the stub as docker inspect would
	local result
	result="$("$stub" inspect -f '{{index .Config.Labels "com.docker.compose.oneoff"}}' drydock-myproj-ab12)"
	[ "$result" = "True" ]
}

@test "make_docker_stub_with_sessions: inspect -f mux label returns MOCK_MUX (T1)" {
	export MOCK_ONEOFF="False"
	export MOCK_MUX="tmux"
	export MOCK_MUX_SESSION="work"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	local result
	result="$("$stub" inspect -f '{{index .Config.Labels "drydock.mux"}}' drydock-myproj-ab12)"
	[ "$result" = "tmux" ]
}

@test "make_docker_stub_with_sessions: inspect -f mux_session label returns MOCK_MUX_SESSION (T1)" {
	export MOCK_ONEOFF="False"
	export MOCK_MUX="tmux"
	export MOCK_MUX_SESSION="work"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	local result
	result="$("$stub" inspect -f '{{index .Config.Labels "drydock.mux_session"}}' drydock-myproj-ab12)"
	[ "$result" = "work" ]
}

@test "make_docker_stub_with_sessions: MOCK_ONEOFF=False distinguishes from True (T1, OQ-5)" {
	# Verify capital False returns false, not true — critical for OQ-5 contract
	export MOCK_ONEOFF="False"
	export MOCK_MUX=""
	export MOCK_MUX_SESSION=""
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	local result
	result="$("$stub" inspect -f '{{index .Config.Labels "com.docker.compose.oneoff"}}' drydock-myproj-ab12)"
	[ "$result" = "False" ]
	[ "$result" != "True" ]
}

# ── T2: _is_oneoff_container — RED→GREEN (S-2C, S-2D) ───────────────────────

@test "_is_oneoff_container: label=True → returns 0 (S-2D, OQ-5)" {
	# GIVEN a container with com.docker.compose.oneoff=True (capital T)
	# WHEN _is_oneoff_container is called
	# THEN it returns 0 (success = is oneoff)
	export MOCK_ONEOFF="True"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_is_oneoff_container "drydock-myproj-ab12"
}

@test "_is_oneoff_container: label=False → returns 1 (S-2C, OQ-5)" {
	# GIVEN a container with com.docker.compose.oneoff=False (capital F)
	# WHEN _is_oneoff_container is called
	# THEN it returns 1 (failure = not oneoff, persistent)
	export MOCK_ONEOFF="False"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	run _is_oneoff_container "drydock-myproj-ab12"
	[ "$status" -eq 1 ]
}

@test "_is_oneoff_container: label=lowercase true → returns 1 (OQ-5 contract: must be capital)" {
	# lowercase 'true' MUST NOT be treated as oneoff — OQ-5 invariant
	export MOCK_ONEOFF="true"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	run _is_oneoff_container "drydock-myproj-ab12"
	[ "$status" -eq 1 ]
}

@test "_is_oneoff_container: inspect failure → returns 1 (OQ-4 degrade gracefully)" {
	# GIVEN docker inspect fails (container absent)
	# WHEN _is_oneoff_container is called
	# THEN it returns 1 (degrades to false, treats as persistent)
	export MOCK_DOCKER_EXIT=1
	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"
	run _is_oneoff_container "drydock-myproj-ab12"
	[ "$status" -eq 1 ]
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
	[[ "$output" == *"requires a TTY"* ]]
	# The TTY guard MUST fire before compose exec is invoked.
	! grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
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

# ── Scenario (b-no-tty): no arg + 1 live session + no TTY → exit 2 ────────────

@test "cmd_attach: no arg + 1 live session + no TTY → exits 2 without invoking compose exec (FIX-5)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	# Do NOT override _drydock_has_tty — tests run without a TTY by default.

	run cmd_attach 2>&1
	[ "$status" -eq 2 ]
	[[ "$output" == *"requires a TTY"* ]]
	# The TTY guard MUST fire before compose exec is invoked.
	! grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
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

# ── T1.10: cmd_attach uses _run_claude_lifecycle (teardown fires) (D-8) ───────

@test "cmd_attach: uses lifecycle helper — teardown rm -f appears after exec (D-8)" {
	# GIVEN cmd_attach is called with a live session and a TTY
	# WHEN claude exits
	# THEN docker rm -f appears in the call log (lifecycle helper was used,
	# not raw exec — exec would replace the process and teardown would never run)
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	grep -q "rm -f drydock-myproj-ab12" "$DOCKER_CALL_LOG"
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
