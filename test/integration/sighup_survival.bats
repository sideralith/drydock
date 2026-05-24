#!/usr/bin/env bats
# test/integration/sighup_survival.bats — Empirical SIGHUP-survival gate (design D-14).
#
# This is the GO/NO-GO gate for Commit 1.2 (session-persistence Slice 1).
# All four assertions must pass before the slice ships.
#
# Assertions:
#   A  Container stays up after `docker run` (wrapper starts cleanly)
#   B  Container stays up after `docker kill -s HUP` (SIGHUP-survivable); poll up to 30s
#   C  `zellij list-sessions` inside the container exits 0 and lists "drydock"
#   D  Container exits within 30s after `zellij kill-session drydock`
#
# Gate uses a `sleep 60` test layout (DRYDOCK_ZELLIJ_LAYOUT_OVERRIDE) to avoid
# a dependency on the `claude` binary (not present during `docker run` gates).
#
# Requires: DRYDOCK_INTEGRATION=1 (skipped in unit mode).
# Requires: drydock:latest image already built (`bin/drydock build` first).

load "../helpers/load"

# ── Poll helper ───────────────────────────────────────────────────────────────
# Waits up to 30s for `zellij list-sessions` inside the named container to list
# the "drydock" session. Replaces fixed `sleep 5` to avoid flakes on slow runners.
# Uses --short (strips ANSI formatting) and grep -qxF (exact whole-line match)
# to avoid false-positives from future sessions whose names contain "drydock" as
# a substring (e.g. "drydock-foo").
_wait_for_zellij_session() {
	local container="$1"
	local timeout=30
	local elapsed=0
	while [ $elapsed -lt $timeout ]; do
		if docker exec "$container" zellij list-sessions --short 2>/dev/null | grep -qxF 'drydock'; then
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	return 1
}

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

	# Wait for Zellij to start (poll instead of fixed sleep to avoid flakes on slow runners)
	_wait_for_zellij_session "$_NAME" || { docker logs "$_NAME"; fail "Zellij session did not start within 30s"; }
}

teardown() {
	# Best-effort cleanup — container may already be gone (test D)
	docker kill "$_NAME" 2>/dev/null || true
	docker rm -f "$_NAME" 2>/dev/null || true
}

# ── A: Container is up after start ───────────────────────────────────────────
@test "A: container stays up after start (wrapper boots cleanly)" {
	run docker ps --filter "name=^${_NAME}$" --format '{{.Names}}'
	assert_success
	assert_output --partial "$_NAME"
}

# ── B: Container survives SIGHUP ─────────────────────────────────────────────
@test "B: container stays up after docker kill -s HUP (SIGHUP-survivable; poll 30s)" {
	# Send SIGHUP — mimics terminal close
	docker kill -s HUP "$_NAME"

	# Wait for Zellij session to recover / remain after SIGHUP (poll instead of fixed sleep)
	_wait_for_zellij_session "$_NAME" || { docker logs "$_NAME"; fail "Zellij session not alive after SIGHUP within 30s"; }

	run docker ps --filter "name=^${_NAME}$" --format '{{.Names}}'
	assert_success
	assert_output --partial "$_NAME"

	# Zellij session must still be alive inside the container — not just the container.
	# A regression where SIGHUP killed only the Zellij session but left PID 1 alive
	# would pass the docker ps check above but fail here (the original #64 failure mode).
	run docker exec "$_NAME" zellij list-sessions --short
	assert_success
	assert_line 'drydock'
}

# ── C: Zellij session named "drydock" exists ─────────────────────────────────
@test "C: zellij list-sessions lists a session named 'drydock'" {
	run docker exec "$_NAME" zellij list-sessions --short
	assert_success
	assert_line 'drydock'
}

# ── D: Container exits after zellij kill-session ─────────────────────────────
@test "D: container exits within 30s after zellij kill-session drydock" {
	# Kill the named session — wrapper's `wait` returns, container exits cleanly
	docker exec "$_NAME" zellij kill-session drydock || true

	# Poll until container disappears (--rm removes it after exit) instead of fixed sleep.
	local timeout=30
	local elapsed=0
	while [ $elapsed -lt $timeout ]; do
		if ! docker ps --filter "name=^${_NAME}$" --format '{{.Names}}' | grep -q "$_NAME"; then
			break
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	# Container must be gone (--rm removes it after exit; docker ps returns empty)
	run docker ps --filter "name=^${_NAME}$" --format '{{.Names}}'
	assert_success
	assert_output ''
}
