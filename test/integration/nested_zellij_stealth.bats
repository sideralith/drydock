#!/usr/bin/env bats
# test/integration/nested_zellij_stealth.bats — REQ-16 / REQ-17 contract.
#
# Verifies that the drydock-wrapper.sh respects DRYDOCK_NESTED_ZELLIJ and
# DRYDOCK_FORCE_INNER_ZELLIJ_FULL environment variables, loading the stealth
# Zellij config (zellij-nested.kdl) in nested mode and falling back to the
# standard config when the full-mode override is set.
#
# Assertions:
#   S-A  DRYDOCK_NESTED_ZELLIJ=1 → PID 1 cmdline includes zellij-nested.kdl
#   S-B  DRYDOCK_NESTED_ZELLIJ=1 + DRYDOCK_FORCE_INNER_ZELLIJ_FULL=1 → no nested config
#   S-C  Zellij session named "drydock" is listed inside the container
#
# Uses -dt (allocate pseudo-TTY) — Zellij's client requires a TTY.
# Uses DRYDOCK_ZELLIJ_LAYOUT_OVERRIDE to bypass the default claude-shim layout.
#
# Requires: DRYDOCK_INTEGRATION=1 (skipped in unit mode).
# Requires: drydock:latest image already built (`bin/drydock build` first).

load "../helpers/load"

# ── Poll helper ───────────────────────────────────────────────────────────────
# Waits up to 30s for `zellij list-sessions` inside the named container to list
# the "drydock" session. Replaces fixed `sleep 5` to avoid flakes on slow runners.
_wait_for_zellij_session() {
	local container="$1"
	local timeout=30
	local elapsed=0
	while [ $elapsed -lt $timeout ]; do
		if docker exec "$container" zellij list-sessions 2>/dev/null | grep -q 'drydock'; then
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
	_NAME="drydock-stealthtest-$$"
	_LAYOUT_PATH="/tmp/drydock-gate-layout.kdl"
}

teardown() {
	# Best-effort cleanup — do not fail the test on teardown errors
	docker kill "$_NAME" 2>/dev/null || true
	docker rm -f "$_NAME" 2>/dev/null || true
}

# ── S-A: Nested mode loads stealth config ────────────────────────────────────
@test "S-A: DRYDOCK_NESTED_ZELLIJ=1 causes wrapper to pass zellij-nested.kdl" {
	# Start container in nested mode — wrapper should pass --config to Zellij
	docker run -dt --name "$_NAME" \
		-e DRYDOCK_NESTED_ZELLIJ=1 \
		-e DRYDOCK_ZELLIJ_LAYOUT_OVERRIDE="$_LAYOUT_PATH" \
		drydock:latest \
		/bin/bash -c "
			mkdir -p /tmp
			printf 'layout {\n  pane command=\"sleep\" {\n    args \"60\"\n  }\n}\n' > ${_LAYOUT_PATH}
			exec /opt/drydock/hooks/drydock-wrapper.sh
		"

	# Wait for Zellij to start (poll instead of fixed sleep to avoid flakes on slow runners)
	_wait_for_zellij_session "$_NAME" || { docker logs "$_NAME"; fail "Zellij session did not start within 30s"; }

	# The script child's cmdline (via script -qec) should include the nested config path.
	# We check the running Zellij processes inside the container.
	run docker exec "$_NAME" sh -c 'ps aux | grep zellij'
	assert_success
	assert_output --partial 'zellij-nested.kdl'
}

# ── S-B: Full-mode override bypasses stealth config ──────────────────────────
@test "S-B: DRYDOCK_NESTED_ZELLIJ=1 + DRYDOCK_FORCE_INNER_ZELLIJ_FULL=1 uses standard config" {
	# Start container with both nested and force-full flags — no stealth config
	docker run -dt --name "$_NAME" \
		-e DRYDOCK_NESTED_ZELLIJ=1 \
		-e DRYDOCK_FORCE_INNER_ZELLIJ_FULL=1 \
		-e DRYDOCK_ZELLIJ_LAYOUT_OVERRIDE="$_LAYOUT_PATH" \
		drydock:latest \
		/bin/bash -c "
			mkdir -p /tmp
			printf 'layout {\n  pane command=\"sleep\" {\n    args \"60\"\n  }\n}\n' > ${_LAYOUT_PATH}
			exec /opt/drydock/hooks/drydock-wrapper.sh
		"

	# Wait for Zellij to start (poll instead of fixed sleep to avoid flakes on slow runners)
	_wait_for_zellij_session "$_NAME" || { docker logs "$_NAME"; fail "Zellij session did not start within 30s"; }

	# Zellij process should NOT contain the nested config path
	run docker exec "$_NAME" sh -c 'ps aux | grep zellij'
	assert_success
	refute_output --partial 'zellij-nested.kdl'
}

# ── S-C: Zellij session named "drydock" is reachable inside the container ────
@test "S-C: zellij list-sessions lists the drydock session" {
	# Start container in default (non-nested) mode
	docker run -dt --name "$_NAME" \
		-e DRYDOCK_ZELLIJ_LAYOUT_OVERRIDE="$_LAYOUT_PATH" \
		drydock:latest \
		/bin/bash -c "
			mkdir -p /tmp
			printf 'layout {\n  pane command=\"sleep\" {\n    args \"60\"\n  }\n}\n' > ${_LAYOUT_PATH}
			exec /opt/drydock/hooks/drydock-wrapper.sh
		"

	# Wait for Zellij to start (poll instead of fixed sleep to avoid flakes on slow runners)
	_wait_for_zellij_session "$_NAME" || { docker logs "$_NAME"; fail "Zellij session did not start within 30s"; }

	run docker exec "$_NAME" zellij list-sessions
	assert_success
	assert_output --partial 'drydock'
}
