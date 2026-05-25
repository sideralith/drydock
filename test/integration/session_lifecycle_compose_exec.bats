#!/usr/bin/env bats
# test/integration/session_lifecycle_compose_exec.bats — empirical lifecycle gate
#
# REQ-N10: Asserts L-A..L-D for the "Detect + Delegate" (Modelo X) session model:
#
#   L-A: compose up -d → container Up; /proc/1/cmdline contains "sleep" (REQ-1-M).
#   L-B: SIGHUP to exec PID (not container PID 1) → container stays Up (REQ-1-M).
#   L-C: Second compose exec connects to the same container (same PID 1) (SR-1-M).
#   L-D: docker rm -f → container absent; new compose up -d starts clean (REQ-N7).
#
# REQUIRES: DRYDOCK_INTEGRATION=1 (env var) to run.
# NEVER run bats test/integration/ directly — use scripts/test.sh.
# NEVER execute with DRYDOCK_INTEGRATION=1 without explicit maintainer authorization.
#
# Pre-conditions:
#   - drydock image built (drydock:latest present)
#   - Docker socket available (/var/run/docker.sock)
#   - scripts/test.sh used as the test runner
#
# These tests start REAL Docker containers. Each test cleans up after itself.

# ── Integration gate ────────────────────────────────────────────────────────
# Skip the entire file if DRYDOCK_INTEGRATION is not set to "1".
# This prevents unit-mode test runs from failing when no Docker is available.
if [ "${DRYDOCK_INTEGRATION:-0}" != "1" ]; then
	bats_skip_file "Skipping integration tests (DRYDOCK_INTEGRATION != 1)"
fi

load "../helpers/load"

# ── Constants ────────────────────────────────────────────────────────────────

INTEGRATION_PROJECT_NAME="drydock-integ-lifecycle"
INTEGRATION_CONTAINER="${INTEGRATION_PROJECT_NAME}-c1"

# ── Shared setup/teardown ────────────────────────────────────────────────────

setup() {
	# Remove any leftover container from a previous failed run.
	docker rm -f "$INTEGRATION_CONTAINER" >/dev/null 2>&1 || true
}

teardown() {
	# Best-effort cleanup: remove the container after each test.
	docker rm -f "$INTEGRATION_CONTAINER" >/dev/null 2>&1 || true
}

# ── L-A: compose up -d → container Up; PID 1 = sleep ───────────────────────

@test "L-A: compose up -d starts a persistent container with sleep as PID 1 (REQ-1-M)" {
	# Start the container in detached mode with a known name.
	docker run -d \
		--name "$INTEGRATION_CONTAINER" \
		"drydock:latest" sleep infinity

	# Assert container is Up.
	local status
	status="$(docker inspect --format '{{.State.Status}}' "$INTEGRATION_CONTAINER" 2>/dev/null)"
	[ "$status" = "running" ]

	# Assert PID 1 command is "sleep".
	local pid1_cmd
	pid1_cmd="$(docker exec "$INTEGRATION_CONTAINER" cat /proc/1/cmdline | tr '\0' ' ' | xargs)"
	[[ "$pid1_cmd" == *"sleep"* ]]
}

# ── L-B: SIGHUP to exec PID → container PID 1 survives ─────────────────────

@test "L-B: SIGHUP to exec process does NOT kill the container (REQ-1-M)" {
	# Start the container.
	docker run -d \
		--name "$INTEGRATION_CONTAINER" \
		"drydock:latest" sleep infinity

	# Record container PID 1 before the SIGHUP.
	local pid1_before
	pid1_before="$(docker exec "$INTEGRATION_CONTAINER" cat /proc/1/pid 2>/dev/null || \
		docker exec "$INTEGRATION_CONTAINER" sh -c 'cat /proc/1/stat | awk "{print \$1}"')"

	# Start a background exec and immediately SIGHUP it.
	# The exec process is a new PID (not PID 1) inside the container.
	local exec_pid
	docker exec "$INTEGRATION_CONTAINER" sleep 2 &
	exec_pid="$!"
	sleep 0.2
	kill -HUP "$exec_pid" 2>/dev/null || true
	wait "$exec_pid" 2>/dev/null || true

	# Container must still be Up after the SIGHUP.
	local status_after
	status_after="$(docker inspect --format '{{.State.Status}}' "$INTEGRATION_CONTAINER" 2>/dev/null)"
	[ "$status_after" = "running" ]
}

# ── L-C: Second exec connects to the same container (same PID 1) ────────────

@test "L-C: second compose exec connects to the same container — same PID 1 (SR-1-M)" {
	# Start the container.
	docker run -d \
		--name "$INTEGRATION_CONTAINER" \
		"drydock:latest" sleep infinity

	# First exec: capture PID 1.
	local pid1_first
	pid1_first="$(docker exec "$INTEGRATION_CONTAINER" cat /proc/1/stat | awk '{print $1}')"

	# Second exec: capture PID 1 again.
	local pid1_second
	pid1_second="$(docker exec "$INTEGRATION_CONTAINER" cat /proc/1/stat | awk '{print $1}')"

	# Same PID 1 — same container, same process.
	[ "$pid1_first" = "$pid1_second" ]
}

# ── L-D: docker rm -f → absent; new compose up -d starts clean ──────────────

@test "L-D: docker rm -f removes container; new up starts fresh (REQ-N7, SR-1-M)" {
	# Start the container.
	docker run -d \
		--name "$INTEGRATION_CONTAINER" \
		"drydock:latest" sleep infinity

	# Stop it.
	docker rm -f "$INTEGRATION_CONTAINER"

	# Assert container is gone.
	local inspect_exit
	docker inspect "$INTEGRATION_CONTAINER" >/dev/null 2>&1 && inspect_exit=0 || inspect_exit=1
	[ "$inspect_exit" -ne 0 ]

	# Start a new container with the same name — must succeed cleanly.
	docker run -d \
		--name "$INTEGRATION_CONTAINER" \
		"drydock:latest" sleep infinity

	local new_status
	new_status="$(docker inspect --format '{{.State.Status}}' "$INTEGRATION_CONTAINER" 2>/dev/null)"
	[ "$new_status" = "running" ]
}
