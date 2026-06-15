#!/usr/bin/env bats
# test/cmd_reap.bats — unit tests for _reap_orphan_claude helper
#
# REQ-5, D-7: _reap_orphan_claude must:
#   - Issue `docker exec <session_name> pkill -f "<uuid>"` to kill orphaned claude
#   - Be idempotent — pkill non-zero (no process) → reap returns 0
#   - Be PID-1-safe — uuid targeting means PID 1 (sleep infinity) is never matched
#   - Fall back to broad `pkill -f claude` when uuid is empty (pre-#131 detach)

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

	# DOCKER seam: log all calls; exit 0 by default.
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
}

# ── T3.1: reap issues docker exec <session_name> pkill -f "<uuid>" ────────────

@test "_reap_orphan_claude: issues docker exec <name> pkill -f <uuid> (REQ-5, D-7)" {
	# GIVEN a session name and a uuid
	# WHEN _reap_orphan_claude is called
	# THEN docker exec <name> pkill -f <uuid> appears in the call log
	run _reap_orphan_claude "drydock-myproj-ab12" "550e8400-e29b-41d4-a716-446655440000"
	[ "$status" -eq 0 ]
	# The call must use 'exec' (not 'compose exec') with pkill -f <uuid>
	grep -q "exec drydock-myproj-ab12 pkill -f 550e8400-e29b-41d4-a716-446655440000" "$DOCKER_CALL_LOG"
}

# ── T3.2: reap is idempotent — pkill non-zero → reap returns 0 ──────────────

@test "_reap_orphan_claude: idempotent — pkill exits non-zero (no process) → reap returns 0 (REQ-5)" {
	# GIVEN docker (pkill proxy) exits non-zero (orphan already dead)
	# WHEN _reap_orphan_claude is called
	# THEN the function returns 0 (no-op, not an error)
	export MOCK_DOCKER_EXIT=1
	run _reap_orphan_claude "drydock-myproj-ab12" "550e8400-e29b-41d4-a716-446655440000"
	[ "$status" -eq 0 ]
}

# ── T3.3: PID-1 safety — by-uuid match never targets PID 1 ─────────────────

@test "_reap_orphan_claude: PID-1-safe — pkill uses uuid pattern, never a PID-1 bypass (D-7)" {
	# GIVEN a reap call with a specific uuid
	# WHEN the docker exec call is examined
	# THEN it must use pkill -f <uuid> and NOT contain any explicit PID-1 bypass
	# (no --signal with pid 1, no explicit PID 1 kill, no pkill -9 PID 1 approach)
	# The safety property is structural: 'sleep infinity' (PID 1) does not carry
	# the uuid in its cmdline, so pkill -f <uuid> never matches it.
	run _reap_orphan_claude "drydock-myproj-ab12" "550e8400-e29b-41d4-a716-446655440000"
	[ "$status" -eq 0 ]
	# Must contain pkill -f <uuid>
	grep -q "pkill -f 550e8400-e29b-41d4-a716-446655440000" "$DOCKER_CALL_LOG"
	# Must NOT contain any explicit reference to PID 1 or kill-all bypass
	! grep -q "pid.*1\b\|kill.*1\b\|signal.*1\b" "$DOCKER_CALL_LOG"
}

# ── T3.4: no-marker fallback — empty uuid → pkill -f claude ─────────────────

@test "_reap_orphan_claude: empty uuid → fallback broad pkill -f claude (D-7)" {
	# GIVEN no uuid is available (pre-#131 session, marker absent)
	# WHEN _reap_orphan_claude is called with an empty uuid
	# THEN it falls back to pkill -f claude (per-container scope is safe since
	# each session lives in its own container)
	run _reap_orphan_claude "drydock-myproj-ab12" ""
	[ "$status" -eq 0 ]
	# Must use the broad fallback pattern
	grep -q "pkill -f claude" "$DOCKER_CALL_LOG"
	# Must NOT attempt an empty-pattern pkill (would match every process,
	# including PID 1). mock-docker logs `echo "$*"`, so an empty uuid argument
	# leaves NO quotes in the log — the old `pkill -f ""` grep was tautological.
	# The empty-pattern failure signature is a logged line ENDING at `pkill -f`
	# (optionally with trailing whitespace from the empty arg).
	run grep -E 'pkill -f[[:space:]]*$' "$DOCKER_CALL_LOG"
	[ "$status" -ne 0 ]
}

@test "_reap_orphan_claude: empty uuid fallback — still runs unconditionally (D-7)" {
	# Even when uuid is empty the reap still executes — it must not bail early
	run _reap_orphan_claude "drydock-myproj-ab12" ""
	[ "$status" -eq 0 ]
	grep -q "exec drydock-myproj-ab12" "$DOCKER_CALL_LOG"
}
