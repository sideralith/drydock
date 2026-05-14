#!/usr/bin/env bats
# test/source_guard.bats — verify that sourcing bin/drydock is side-effect-free
#
# Spec: CLI Sourceability → Scenario "Source without dispatch"
# bin/drydock MUST be sourceable with zero output and no command dispatch.

load "helpers/load"

setup() {
  # Source bin/drydock into the test shell so public functions are callable.
  # Note: source (not 'run source') so functions are defined in THIS shell.
  # set -euo pipefail is propagated from drydock when sourced; the
  # source-guard '|| true' prevents a false exit from the guard from failing.
  # shellcheck disable=SC1090
  source "$DRYDOCK_HOME/bin/drydock"

  # Also set up a mock-docker call log so we can verify no docker calls fire.
  export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
  export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
}

@test "sourcing bin/drydock produces zero output" {
  # Run in a subshell to capture any output from the source itself.
  # We deliberately do NOT use 'run source' because run executes in a
  # subprocess and function definitions would not persist.
  output="$(source "$DRYDOCK_HOME/bin/drydock" 2>&1)"
  [ -z "$output" ]
}

@test "sourcing bin/drydock does not invoke docker" {
  # The call log file must not exist (no calls made during setup() source).
  # Note: setup() sourced drydock without DOCKER_CALL_LOG set yet, so the
  # mock was not active — we test here that the mock-docker is NOT called
  # when sourcing a second time with the mock active.
  output="$(DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker" \
            DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls2.log" \
            bash -c 'source "$1/bin/drydock"' -- "$DRYDOCK_HOME" 2>&1)"
  [ -z "$output" ]
  [ ! -f "$BATS_TEST_TMPDIR/docker-calls2.log" ]
}

@test "compose_files is defined after sourcing" {
  declare -f compose_files > /dev/null
}

@test "detect_submounts is defined after sourcing" {
  declare -f detect_submounts > /dev/null
}

@test "cmd_init is defined after sourcing" {
  declare -f cmd_init > /dev/null
}

@test "main is defined after sourcing" {
  declare -f main > /dev/null
}

@test "resolve_project_dir is defined after sourcing" {
  declare -f resolve_project_dir > /dev/null
}

@test "export_compose_env is defined after sourcing" {
  declare -f export_compose_env > /dev/null
}
