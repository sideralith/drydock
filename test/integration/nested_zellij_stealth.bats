#!/usr/bin/env bats
# test/integration/nested_zellij_stealth.bats — REQ-16 / REQ-17 contract.
#
# Verifies that the drydock-wrapper.sh respects DRYDOCK_NESTED_ZELLIJ and
# DRYDOCK_FORCE_INNER_ZELLIJ_FULL environment variables, loading the stealth
# Zellij config (zellij-nested.kdl) in nested mode and falling back to the
# standard config when the full-mode override is set.
#
# Assertions:
#   S-A  DRYDOCK_NESTED_ZELLIJ=1 → PID 1 uses --config /etc/drydock/zellij-nested.kdl
#   S-B  DRYDOCK_NESTED_ZELLIJ=1 + DRYDOCK_FORCE_INNER_ZELLIJ_FULL=1 → no nested config
#   S-C  Zellij session named "drydock" is listed inside the container
#
# Requires: DRYDOCK_INTEGRATION=1 (skipped in unit mode).
# Requires: drydock:latest image already built (`bin/drydock build` first).
#
# These tests are INTENTIONALLY FAILING until Commit 1.2 ships the wrapper,
# shim, and zellij-nested.kdl into the image.

load "../helpers/load"

# ── Integration gate ──────────────────────────────────────────────────────────
setup_file() {
	[[ "${DRYDOCK_INTEGRATION:-}" == "1" ]] || skip "DRYDOCK_INTEGRATION not set — skipping integration tests"
}

setup() {
	[[ "${DRYDOCK_INTEGRATION:-}" == "1" ]] || skip "DRYDOCK_INTEGRATION not set — skipping integration tests"
	_NAME="drydock-stealthtest-$$"
}

teardown() {
	# Best-effort cleanup — do not fail the test on teardown errors
	docker kill "$_NAME" 2>/dev/null || true
	docker rm -f "$_NAME" 2>/dev/null || true
}

# ── S-A: Nested mode loads stealth config ────────────────────────────────────
@test "S-A: DRYDOCK_NESTED_ZELLIJ=1 causes PID 1 to use zellij-nested.kdl" {
	# Start container in nested mode with the wrapper as PID 1.
	# The wrapper execs into: zellij --config /etc/drydock/zellij-nested.kdl attach --create drydock ...
	docker run -d --name "$_NAME" \
		-e DRYDOCK_NESTED_ZELLIJ=1 \
		drydock:latest \
		/opt/drydock/hooks/drydock-wrapper.sh

	# Give Zellij time to start up
	sleep 5

	# Inspect PID 1 cmdline (null-delimited argv in /proc/1/cmdline)
	run docker exec "$_NAME" cat /proc/1/cmdline
	assert_success

	# The cmdline must contain the stealth config path
	# /proc/1/cmdline is NUL-delimited; tr translates NULs to spaces
	run docker exec "$_NAME" sh -c 'tr "\0" " " < /proc/1/cmdline'
	assert_output --partial '/etc/drydock/zellij-nested.kdl'
}

# ── S-B: Full-mode override bypasses stealth config ──────────────────────────
@test "S-B: DRYDOCK_NESTED_ZELLIJ=1 + DRYDOCK_FORCE_INNER_ZELLIJ_FULL=1 uses standard config" {
	# Start container with both nested and force-full flags set.
	# The wrapper should NOT load zellij-nested.kdl in this case.
	docker run -d --name "$_NAME" \
		-e DRYDOCK_NESTED_ZELLIJ=1 \
		-e DRYDOCK_FORCE_INNER_ZELLIJ_FULL=1 \
		drydock:latest \
		/opt/drydock/hooks/drydock-wrapper.sh

	sleep 5

	# Cmdline must NOT contain the nested config path
	run docker exec "$_NAME" sh -c 'tr "\0" " " < /proc/1/cmdline'
	assert_success
	refute_output --partial '/etc/drydock/zellij-nested.kdl'
}

# ── S-C: Zellij session named "drydock" is reachable inside the container ────
@test "S-C: zellij list-sessions lists the drydock session" {
	# Start container in default (non-nested) mode.
	docker run -d --name "$_NAME" \
		drydock:latest \
		/opt/drydock/hooks/drydock-wrapper.sh

	sleep 5

	# zellij list-sessions must exit 0 and print "drydock"
	run docker exec "$_NAME" zellij list-sessions
	assert_success
	assert_output --partial 'drydock'
}
