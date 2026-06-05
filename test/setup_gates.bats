#!/usr/bin/env bats
# test/setup_gates.bats — unit tests for the setup-gates.sh pure helper.
#
# Sources scripts/setup-gates.sh via the source-guard so the pure helper
# (_is_docker_desktop) can be exercised without running any orchestration.

load "helpers/load"

setup() {
	# Source the runner. The source-guard ensures main() is not invoked.
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/scripts/setup-gates.sh"
}

# ── source-guard ──────────────────────────────────────────────────────────────

@test "setup-gates: sourcing produces zero output" {
	output="$(source "$DRYDOCK_HOME/scripts/setup-gates.sh" 2>&1)"
	[ -z "$output" ]
}

@test "setup-gates: _is_docker_desktop is defined after sourcing" {
	declare -f _is_docker_desktop >/dev/null
}

# ── _is_docker_desktop ────────────────────────────────────────────────────────

@test "_is_docker_desktop: true for the bare 'Docker Desktop' OS string" {
	run bash -c 'source "$1/scripts/setup-gates.sh"; _is_docker_desktop "Docker Desktop"' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
}

@test "_is_docker_desktop: true when 'Docker Desktop' is a substring" {
	run bash -c 'source "$1/scripts/setup-gates.sh"; _is_docker_desktop "Docker Desktop 4.30 (LinuxKit)"' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
}

@test "_is_docker_desktop: false for native Debian" {
	run bash -c 'source "$1/scripts/setup-gates.sh"; _is_docker_desktop "Debian GNU/Linux 12 (bookworm)"' -- "$DRYDOCK_HOME"
	[ "$status" -ne 0 ]
}

@test "_is_docker_desktop: false for native Ubuntu" {
	run bash -c 'source "$1/scripts/setup-gates.sh"; _is_docker_desktop "Ubuntu 24.04 LTS"' -- "$DRYDOCK_HOME"
	[ "$status" -ne 0 ]
}

@test "_is_docker_desktop: false for empty string" {
	run bash -c 'source "$1/scripts/setup-gates.sh"; _is_docker_desktop ""' -- "$DRYDOCK_HOME"
	[ "$status" -ne 0 ]
}
