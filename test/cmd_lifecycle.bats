#!/usr/bin/env bats
# test/cmd_lifecycle.bats — unit tests for _run_claude_lifecycle helper
#
# REQ-1, REQ-2, REQ-3, REQ-4, D-1, D-2, D-3:
# The _run_claude_lifecycle helper must:
#   - Run docker compose exec as a child (not exec) so drydock survives it
#   - Capture the exit code (|| _rc=$? idiom) without letting errexit abort early
#   - Teardown (rm -f <session_name>) UNCONDITIONALLY on parent survival (TRAP A):
#     regardless of _rc value (non-zero Ctrl+C exit must still trigger teardown)
#   - Teardown must NOT fire on SIGHUP (TRAP B — disconnect→persist)
#   - Teardown rm -f is guarded with || true so a failing rm does not suppress _rc
#   - The function returns the captured _rc as its own exit code

load "helpers/load"

# ── Setup ──────────────────────────────────────────────────────────────────────

setup() {
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/commands.sh"

	# DOCKER seam: log calls to a file; exit 0 by default.
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	# Stub TTY check — most lifecycle tests don't care about TTY.
	_drydock_has_tty() { return 0; }
}

# ── T1.1: parent-survival → teardown fires (D-3 single-name rm -f) ──────────

@test "_run_claude_lifecycle: parent survives exec → teardown rm -f session_name called (REQ-1, D-3)" {
	# GIVEN the docker exec exits 0 (clean exit)
	# WHEN _run_claude_lifecycle is called
	# THEN docker rm -f <session_name> is logged (teardown fired)
	# The call log will contain both the exec call and the rm -f teardown call.
	run _run_claude_lifecycle "drydock-myproj-ab12" compose -p "drydock-myproj-ab12" exec -it drydock claude
	[ "$status" -eq 0 ]
	# Teardown must appear: "rm -f drydock-myproj-ab12"
	grep -q "rm -f drydock-myproj-ab12" "$DOCKER_CALL_LOG"
}

# ── T1.2: teardown fires unconditionally on non-zero _rc (TRAP A) ────────────

@test "_run_claude_lifecycle: _rc=130 (Ctrl+C) → teardown still fires (REQ-2, TRAP A)" {
	# GIVEN the docker exec exits 130 (Ctrl+C equivalent)
	# WHEN _run_claude_lifecycle is called
	# THEN teardown rm -f fires regardless of the non-zero exit code
	# AND the function returns 130
	export MOCK_DOCKER_EXIT=130
	run _run_claude_lifecycle "drydock-myproj-ab12" compose -p "drydock-myproj-ab12" exec -it drydock claude
	[ "$status" -eq 130 ]
	# Teardown must still appear even though _rc=130.
	grep -q "rm -f drydock-myproj-ab12" "$DOCKER_CALL_LOG"
}

# ── T1.3: HUP trap → teardown NOT called, function exits 0 (TRAP B) ─────────

@test "_run_claude_lifecycle: SIGHUP → exit 0 and NO teardown (REQ-3, TRAP B)" {
	# GIVEN the docker stub sends SIGHUP to the bash process (simulates terminal-close)
	# WHEN _run_claude_lifecycle is called
	# THEN the function exits 0 (disconnect→persist)
	# AND docker rm -f is NOT logged (no teardown)

	# Build a custom stub that kills the parent with SIGHUP then exits non-zero.
	# Bash defers the HUP trap until the foreground command returns, then runs
	# the trap body (exit 0) before reaching the rm -f teardown line.
	local hup_stub_dir="$BATS_TEST_TMPDIR/hup-stub"
	mkdir -p "$hup_stub_dir"
	cat >"$hup_stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${DOCKER_CALL_LOG:?DOCKER_CALL_LOG must be set}"
# Send HUP to parent (the bash running _run_claude_lifecycle).
kill -HUP "$PPID"
exit 129
STUB
	chmod +x "$hup_stub_dir/docker"
	export DOCKER="$hup_stub_dir/docker"

	run _run_claude_lifecycle "drydock-myproj-ab12" compose -p "drydock-myproj-ab12" exec -it drydock claude
	[ "$status" -eq 0 ]
	# rm -f MUST NOT appear — teardown was skipped by the HUP trap path.
	! grep -q "rm -f" "$DOCKER_CALL_LOG"
}

# ── T1.4: _rc propagated as function return code (D-2) ───────────────────────

@test "_run_claude_lifecycle: exit code of docker exec is propagated as return code (D-2)" {
	# GIVEN the docker exec exits with code 42
	# WHEN _run_claude_lifecycle is called
	# THEN the function returns 42 (after teardown)
	export MOCK_DOCKER_EXIT=42
	run _run_claude_lifecycle "drydock-myproj-ab12" compose -p "drydock-myproj-ab12" exec -it drydock claude
	[ "$status" -eq 42 ]
}

# ── T1.5: failing teardown does not suppress _rc (D-2 || true guard) ─────────

@test "_run_claude_lifecycle: failing rm -f does NOT abort before returning _rc (D-2)" {
	# GIVEN docker exec exits 7 AND docker rm -f also fails (MOCK_DOCKER_EXIT applies to both)
	# WHEN _run_claude_lifecycle is called
	# THEN the function still returns 7 (teardown failure swallowed by || true)
	export MOCK_DOCKER_EXIT=7
	run _run_claude_lifecycle "drydock-myproj-ab12" compose -p "drydock-myproj-ab12" exec -it drydock claude
	# Even though rm -f exits 7, the || true guard means we still get _rc=7 returned.
	[ "$status" -eq 7 ]
}

# ── T2.1: SIGHUP path produces no docker rm -f (REQ-3, D-2 — P2 regression) ──

@test "_run_claude_lifecycle: SIGHUP path — no 'rm -f' in call log (P2 disconnect→persist regression)" {
	# This mirrors T1.3 but asserts the absence of rm -f from a P2 angle:
	# disconnect MUST NOT destroy the container.
	local hup_stub_dir="$BATS_TEST_TMPDIR/hup-stub-p2"
	mkdir -p "$hup_stub_dir"
	cat >"$hup_stub_dir/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${DOCKER_CALL_LOG:?DOCKER_CALL_LOG must be set}"
kill -HUP "$PPID"
exit 129
STUB
	chmod +x "$hup_stub_dir/docker"
	export DOCKER="$hup_stub_dir/docker"

	run _run_claude_lifecycle "drydock-myproj-ab12" compose -p "drydock-myproj-ab12" exec -it drydock claude
	[ "$status" -eq 0 ]
	# Confirm rm -f is truly absent — not just that teardown was skipped.
	local log_content
	log_content="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log_content" != *"rm -f"* ]]
}

# ── T2.2: teardown uses single-name rm -f, NEVER compose down (REQ-4, D-3) ───

@test "_run_claude_lifecycle: teardown is single-name rm -f, NOT compose down (REQ-4, D-3)" {
	# GIVEN two concurrent sessions could exist
	# WHEN _run_claude_lifecycle tears down one session
	# THEN it uses 'rm -f <name>' and NEVER 'compose down'
	run _run_claude_lifecycle "drydock-myproj-ab12" compose -p "drydock-myproj-ab12" exec -it drydock claude
	[ "$status" -eq 0 ]
	grep -q "rm -f drydock-myproj-ab12" "$DOCKER_CALL_LOG"
	# compose down must NOT appear.
	! grep -q "compose down" "$DOCKER_CALL_LOG"
}

# ── T1.7: _launch_new delegates exec to _run_claude_lifecycle (D-8) ──────────

@test "_launch_new: delegates to _run_claude_lifecycle — teardown rm -f appears after up -d (D-8)" {
	# GIVEN _launch_new is called with a TTY
	# WHEN it completes
	# THEN the call log contains both 'up -d' AND 'rm -f' (lifecycle helper ran)
	# (The presence of 'rm -f' is the observable that proves exec was dropped
	# and the lifecycle helper was used instead — exec would never reach teardown.)
	_drydock_has_tty() { return 0; }
	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}
	export_compose_env
	local compose_args=()
	compose_files() { printf ''; }
	run _launch_new "." compose_args
	[ "$status" -eq 0 ]
	# up -d must appear (container start)
	grep -q "up" "$DOCKER_CALL_LOG"
	# rm -f must appear (lifecycle helper teardown fired)
	grep -q "rm -f" "$DOCKER_CALL_LOG"
}

# ── T1.11: non-TTY guard on _launch_new still returns 2 (D-9, REQ-1) ─────────

@test "_launch_new: no TTY → exits 2 (non-TTY guard NOT relaxed by lifecycle refactor) (D-9)" {
	# GIVEN _drydock_has_tty returns 1 (no TTY)
	# WHEN _launch_new is called
	# THEN it returns 2 and makes no docker calls
	# (The refactor must NOT relax the non-TTY guard — D-9)
	_drydock_has_tty() { return 1; }
	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}
	export_compose_env
	local compose_args=()
	compose_files() { printf ''; }
	run _launch_new "." compose_args 2>&1
	[ "$status" -eq 2 ]
	[[ "$output" == *"TTY"* ]] || [[ "$output" == *"terminal"* ]]
	# No docker calls made.
	[ ! -s "$DOCKER_CALL_LOG" ]
}
