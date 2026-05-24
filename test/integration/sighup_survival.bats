#!/usr/bin/env bats
# test/integration/sighup_survival.bats — Empirical SIGHUP-survival gate (design D-14).
#
# This is the GO/NO-GO gate for Commit 1.2 (session-persistence Slice 1).
# All four assertions must pass before the slice ships.
#
# Assertions:
#   A  Container stays up 5s after `docker run` (wrapper starts cleanly)
#   B  Container stays up 5s after `docker kill -s HUP` (SIGHUP-survivable)
#   C  `zellij list-sessions` inside the container exits 0 and lists "drydock"
#   D  Container exits within 5s after `zellij kill-session drydock`
#
# Gate uses a `sleep 60` test layout (DRYDOCK_ZELLIJ_LAYOUT_OVERRIDE) to avoid
# a dependency on the `claude` binary (not present during `docker run` gates).
#
# Requires: DRYDOCK_INTEGRATION=1 (skipped in unit mode).
# Requires: drydock:latest image already built (`bin/drydock build` first).

load "../helpers/load"

# ── Integration gate ──────────────────────────────────────────────────────────
setup_file() {
	[[ "${DRYDOCK_INTEGRATION:-}" == "1" ]] || skip "DRYDOCK_INTEGRATION not set — skipping integration tests"
}

setup() {
	[[ "${DRYDOCK_INTEGRATION:-}" == "1" ]] || skip "DRYDOCK_INTEGRATION not set — skipping integration tests"
	_NAME="drydock-sighuptest-$$"
	_LAYOUT_PATH="/tmp/drydock-gate-layout.kdl"

	# Start container with:
	#   -dt   allocate pseudo-TTY (Zellij client requires a TTY)
	#   --rm  auto-remove when it exits (used in D assertion)
	# The wrapper reads DRYDOCK_ZELLIJ_LAYOUT_OVERRIDE to use the test layout.
	# Test layout created inside container by the wrapper's subshell via -e:
	# We create the layout inside the container using docker exec after start.
	docker run -dt --rm --name "$_NAME" \
		-e DRYDOCK_ZELLIJ_LAYOUT_OVERRIDE="$_LAYOUT_PATH" \
		drydock:latest \
		/bin/bash -c "
			mkdir -p /tmp
			printf 'layout {\n  pane command=\"sleep\" {\n    args \"60\"\n  }\n}\n' > ${_LAYOUT_PATH}
			exec /opt/drydock/hooks/drydock-wrapper.sh
		"

	# Give Zellij time to start up
	sleep 5
}

teardown() {
	# Best-effort cleanup — container may already be gone (test D)
	docker kill "$_NAME" 2>/dev/null || true
	docker rm -f "$_NAME" 2>/dev/null || true
}

# ── A: Container is up 5 seconds after start ─────────────────────────────────
@test "A: container stays up for 5s after start (wrapper boots cleanly)" {
	run docker ps --filter "name=^${_NAME}$" --format '{{.Names}}'
	assert_success
	assert_output --partial "$_NAME"
}

# ── B: Container survives SIGHUP ─────────────────────────────────────────────
@test "B: container stays up 5s after docker kill -s HUP (SIGHUP-survivable)" {
	# Send SIGHUP — mimics terminal close
	docker kill -s HUP "$_NAME"

	sleep 5

	run docker ps --filter "name=^${_NAME}$" --format '{{.Names}}'
	assert_success
	assert_output --partial "$_NAME"
}

# ── C: Zellij session named "drydock" exists ─────────────────────────────────
@test "C: zellij list-sessions lists a session named 'drydock'" {
	run docker exec "$_NAME" zellij list-sessions
	assert_success
	assert_output --partial 'drydock'
}

# ── D: Container exits after zellij kill-session ─────────────────────────────
@test "D: container exits within 5s after zellij kill-session drydock" {
	# Kill the named session — wrapper's `wait` returns, container exits cleanly
	docker exec "$_NAME" zellij kill-session drydock || true

	sleep 5

	# Container must be gone (--rm removes it after exit; docker ps returns empty)
	run docker ps --filter "name=^${_NAME}$" --format '{{.Names}}'
	assert_success
	assert_output ''
}
