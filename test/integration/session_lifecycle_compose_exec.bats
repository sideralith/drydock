#!/usr/bin/env bats
# test/integration/session_lifecycle_compose_exec.bats — empirical lifecycle gate
#
# PRODUCTION PATH: This file exercises the actual drydock production lifecycle via
# export_compose_env + compose_files + docker compose up -d, matching what _launch_new
# and cmd_new do. It is the empirical gate for REQ-N10 (Modelo X "Detect + Delegate").
#
# REQ-N10: Asserts L-A..L-D for the "Detect + Delegate" (Modelo X) session model:
#
#   L-A: compose up -d → container Up; /proc/1/cmdline contains "sleep" (REQ-1-M).
#   L-B: SIGHUP to host-side compose exec PID → container PID 1 survives (REQ-1-M).
#   L-C: Second compose exec connects to the same container (same container ID) (SR-1-M).
#   L-D: compose down → container absent; new compose up -d starts clean (REQ-N7).
#
# REQUIRES: DRYDOCK_INTEGRATION=1 (env var) to run.
# NEVER run bats test/integration/ directly — use scripts/test.sh.
# NEVER execute with DRYDOCK_INTEGRATION=1 without explicit maintainer authorization.
#
# Pre-conditions:
#   - drydock image built (drydock:latest present)
#   - Docker socket available (/var/run/docker.sock) — provided by dood mode overlay
#     (docker-compose.dood.yml); DRYDOCK_DOOD=1 is set in setup() so compose_files()
#     resolves to the dood overlay, keeping host net + socket for these exec tests
#   - scripts/test.sh used as the test runner
#
# NOTE: Double-attach across two terminals (two concurrent compose exec calls) is
# unsupported and can produce concurrent writers on the same per-session config dir.
# These tests exercise the normal one-attach-at-a-time lifecycle only.
#
# These tests start REAL Docker containers using the production compose stack.
# Each test cleans up after itself.

# ── Integration gate ────────────────────────────────────────────────────────
# Skip the entire file if DRYDOCK_INTEGRATION is not set to "1".
# This prevents unit-mode test runs from failing when no Docker is available.
# `skip` inside setup_file() is the bats-core (>= 1.5) mechanism for skipping
# a whole file: every @test reports as skipped and per-test setup() — which
# would touch the real Docker daemon — never runs.
setup_file() {
	if [ "${DRYDOCK_INTEGRATION:-0}" != "1" ]; then
		skip "Skipping integration tests (DRYDOCK_INTEGRATION != 1)"
	fi
}

load "../helpers/load"

# ── Source the drydock library stack ────────────────────────────────────────
# Required to call export_compose_env and compose_files.
# shellcheck disable=SC1090
source "$DRYDOCK_HOME/lib/common.sh"
# shellcheck disable=SC1090
source "$DRYDOCK_HOME/lib/paths.sh"
# shellcheck disable=SC1090
source "$DRYDOCK_HOME/lib/compose.sh"
# shellcheck disable=SC1090
source "$DRYDOCK_HOME/lib/commands.sh"

# ── Constants ────────────────────────────────────────────────────────────────

INTEGRATION_PROJECT_DIR="$BATS_TEST_TMPDIR/integ-project"
INTEGRATION_SESSION_NAME=""

# ── Shared setup/teardown ────────────────────────────────────────────────────

setup() {
	# Pin to DooD mode so compose_files() resolves to docker-compose.dood.yml.
	# These tests do real compose up/exec against the stack and require the Docker
	# socket (for compose exec) and host network. Without this, the factory-default
	# contained mode would attach a bridge network with no socket, breaking exec.
	export DRYDOCK_DOOD=1

	# Create a real project directory for export_compose_env.
	mkdir -p "$INTEGRATION_PROJECT_DIR"

	# Set up the production env vars, including a per-session discriminator.
	export_compose_env "$INTEGRATION_PROJECT_DIR"
	INTEGRATION_SESSION_NAME="$DRYDOCK_SESSION_NAME"

	# Remove any leftover container from a previous failed run.
	docker compose -p "$INTEGRATION_SESSION_NAME" down --remove-orphans -v >/dev/null 2>&1 || true
}

teardown() {
	# Best-effort cleanup: stop the compose project after each test.
	if [ -n "${INTEGRATION_SESSION_NAME:-}" ]; then
		docker compose -p "$INTEGRATION_SESSION_NAME" down --remove-orphans -v >/dev/null 2>&1 || true
	fi
}

# ── Helper: get overlay compose args for the integration project dir ─────────

get_compose_args() {
	local -a args=()
	while IFS= read -r arg; do args+=("$arg"); done < <(compose_files "$INTEGRATION_PROJECT_DIR")
	printf '%s\n' "${args[@]}"
}

# ── L-A: compose up -d → container Up; PID 1 = sleep ───────────────────────

@test "L-A: compose up -d starts a persistent container with sleep as PID 1 (REQ-1-M)" {
	local -a compose_args=()
	while IFS= read -r arg; do compose_args+=("$arg"); done < <(get_compose_args)

	# Start the container in detached mode via the production compose stack.
	docker compose "${compose_args[@]}" -p "$INTEGRATION_SESSION_NAME" up -d

	# Assert container is Up.
	local state
	state="$(docker inspect --format '{{.State.Status}}' \
		"$(docker compose -p "$INTEGRATION_SESSION_NAME" ps -q drydock 2>/dev/null | head -1)" \
		2>/dev/null)"
	[ "$state" = "running" ]

	# Assert PID 1 command is "sleep".
	local cid
	cid="$(docker compose -p "$INTEGRATION_SESSION_NAME" ps -q drydock 2>/dev/null | head -1)"
	local pid1_cmd
	pid1_cmd="$(docker exec "$cid" cat /proc/1/cmdline | tr '\0' ' ' | xargs)"
	[[ "$pid1_cmd" == *"sleep"* ]]
}

# ── L-B: SIGHUP to host-side exec process → container PID 1 survives ───────

@test "L-B: SIGHUP to host-side compose exec child does NOT kill the container (REQ-1-M)" {
	local -a compose_args=()
	while IFS= read -r arg; do compose_args+=("$arg"); done < <(get_compose_args)

	docker compose "${compose_args[@]}" -p "$INTEGRATION_SESSION_NAME" up -d

	local cid
	cid="$(docker compose -p "$INTEGRATION_SESSION_NAME" ps -q drydock 2>/dev/null | head -1)"

	# Start a background compose exec and immediately SIGHUP the host-side process.
	# This simulates the user's terminal closing (SIGHUP to the attach child).
	local exec_pid
	docker compose "${compose_args[@]}" -p "$INTEGRATION_SESSION_NAME" exec drydock sleep 2 &
	exec_pid="$!"
	sleep 0.2
	kill -HUP "$exec_pid" 2>/dev/null || true
	wait "$exec_pid" 2>/dev/null || true

	# Container PID 1 must still be running after the SIGHUP.
	local state_after
	state_after="$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)"
	[ "$state_after" = "running" ]
}

# ── L-C: Second exec connects to the same container (same container ID) ─────

@test "L-C: second compose exec connects to the same container — same container ID (SR-1-M)" {
	local -a compose_args=()
	while IFS= read -r arg; do compose_args+=("$arg"); done < <(get_compose_args)

	docker compose "${compose_args[@]}" -p "$INTEGRATION_SESSION_NAME" up -d

	# Capture the container's identity FROM INSIDE the container.
	# /etc/hostname is set by Docker to the container's short ID by default;
	# two exec calls landing in DIFFERENT containers would return DIFFERENT
	# hostnames. (The prior assertion compared the first field of /proc/1/stat,
	# which is always "1" in any container's PID namespace — trivially true.)
	#
	# Dependency: no compose overlay in this repo sets a `hostname:` override;
	# if one is added, /etc/hostname will no longer equal the container short ID
	# and the host/in-container cross-check on the last line will need a different
	# identity source (e.g., docker inspect --format '{{.Id}}').
	local hostname_first
	hostname_first="$(docker compose "${compose_args[@]}" -p "$INTEGRATION_SESSION_NAME" \
		exec -T drydock cat /etc/hostname | tr -d '[:space:]')"

	local hostname_second
	hostname_second="$(docker compose "${compose_args[@]}" -p "$INTEGRATION_SESSION_NAME" \
		exec -T drydock cat /etc/hostname | tr -d '[:space:]')"

	# Cross-check against the host-side compose-project view to confirm both
	# exec calls landed in the container compose tracks for this project.
	local cid_short
	cid_short="$(docker compose -p "$INTEGRATION_SESSION_NAME" ps -q drydock 2>/dev/null \
		| head -1 | cut -c1-12)"

	[ -n "$hostname_first" ]
	[ -n "$cid_short" ]
	[ "$hostname_first" = "$hostname_second" ]
	[ "$hostname_first" = "$cid_short" ]
}

# ── L-D: compose down → absent; new compose up -d starts clean ──────────────

@test "L-D: compose down removes container; new compose up -d starts fresh (REQ-N7, SR-1-M)" {
	local -a compose_args=()
	while IFS= read -r arg; do compose_args+=("$arg"); done < <(get_compose_args)

	docker compose "${compose_args[@]}" -p "$INTEGRATION_SESSION_NAME" up -d

	local cid_first
	cid_first="$(docker compose -p "$INTEGRATION_SESSION_NAME" ps -q drydock 2>/dev/null | head -1)"

	# Tear it down.
	docker compose "${compose_args[@]}" -p "$INTEGRATION_SESSION_NAME" down --remove-orphans -v

	# Assert container is gone.
	local inspect_exit=0
	docker inspect "$cid_first" >/dev/null 2>&1 || inspect_exit=1
	[ "$inspect_exit" -ne 0 ]

	# Start a NEW session — mint a fresh discriminator.
	export_compose_env "$INTEGRATION_PROJECT_DIR"
	INTEGRATION_SESSION_NAME="$DRYDOCK_SESSION_NAME"
	local -a compose_args2=()
	while IFS= read -r arg; do compose_args2+=("$arg"); done < <(get_compose_args)

	docker compose "${compose_args2[@]}" -p "$INTEGRATION_SESSION_NAME" up -d

	local cid_second
	cid_second="$(docker compose -p "$INTEGRATION_SESSION_NAME" ps -q drydock 2>/dev/null | head -1)"

	local new_state
	new_state="$(docker inspect --format '{{.State.Status}}' "$cid_second" 2>/dev/null)"
	[ "$new_state" = "running" ]

	# Cleanup the second session (teardown will use the updated name).
	true
}
