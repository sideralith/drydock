#!/usr/bin/env bats
# test/passthrough.bats — cmd_run / cmd_shell passthrough args tests
#
# Tests the [-- ARGS] passthrough for cmd_run and cmd_shell, and the
# top-level `drydock -- ARGS` shorthand routed via main().
# Uses DOCKER=echo so exec prints the docker command line without
# actually running Docker.

load "helpers/load"

# ── helpers ────────────────────────────────────────────────────────────────────

# Source bin/drydock and stub the heavy prereq functions, then run cmd_run.
# $@ forwarded to cmd_run.
_run_cmd_run() {
  run bash -c '
    drydock_home="$1"; shift
    source "$drydock_home/bin/drydock"
    ensure_prereqs()    { :; }
    ensure_runtime_dirs() { :; }
    ensure_image()      { :; }
    ensure_synced()     { :; }
    export_compose_env() {
      PROJECT_NAME="$(sanitize_project_name "$(basename "$1")")"
      export DRYDOCK_SESSION_NAME="drydock-${PROJECT_NAME}-test"
    }
    compose_files()     { printf "%s\n" "-f" "/tmp/x.yml"; }
    DOCKER=echo
    cmd_run "$@"
  ' -- "$DRYDOCK_HOME" "$@"
}

# Source bin/drydock and stub the heavy prereq functions, then run cmd_shell.
# $@ forwarded to cmd_shell.
_run_cmd_shell() {
  run bash -c '
    drydock_home="$1"; shift
    source "$drydock_home/bin/drydock"
    ensure_prereqs()    { :; }
    ensure_runtime_dirs() { :; }
    ensure_image()      { :; }
    ensure_synced()     { :; }
    export_compose_env() {
      PROJECT_NAME="$(sanitize_project_name "$(basename "$1")")"
      export DRYDOCK_SESSION_NAME="drydock-${PROJECT_NAME}-test"
    }
    compose_files()     { printf "%s\n" "-f" "/tmp/x.yml"; }
    DOCKER=echo
    cmd_shell "$@"
  ' -- "$DRYDOCK_HOME" "$@"
}

# Source bin/drydock and stub the heavy prereq functions, then run main().
# $@ forwarded to main.
_run_main() {
  run bash -c '
    drydock_home="$1"; shift
    source "$drydock_home/bin/drydock"
    ensure_prereqs()    { :; }
    ensure_runtime_dirs() { :; }
    ensure_image()      { :; }
    ensure_synced()     { :; }
    export_compose_env() {
      PROJECT_NAME="$(sanitize_project_name "$(basename "$1")")"
      export DRYDOCK_SESSION_NAME="drydock-${PROJECT_NAME}-test"
    }
    compose_files()     { printf "%s\n" "-f" "/tmp/x.yml"; }
    DOCKER=echo
    main "$@"
  ' -- "$DRYDOCK_HOME" "$@"
}

# ── cmd_run tests ──────────────────────────────────────────────────────────────

@test "cmd_run: no extra args -> runs claude with no passthrough" {
  _run_cmd_run "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run --rm --name drydock-"* ]]
  [[ "$output" == *" drydock claude" ]]
}

@test "cmd_run: DIR -- --resume foo -> passes args to claude" {
  _run_cmd_run "$BATS_TEST_TMPDIR" -- --resume foo
  [ "$status" -eq 0 ]
  [[ "$output" == *"run --rm --name drydock-"* ]]
  [[ "$output" == *" drydock claude --resume foo" ]]
}

@test "cmd_run: -- --resume foo (no DIR) -> passes args to claude" {
  _run_cmd_run -- --resume foo
  [ "$status" -eq 0 ]
  [[ "$output" == *"run --rm --name drydock-"* ]]
  [[ "$output" == *" drydock claude --resume foo" ]]
}

# ── cmd_shell tests ────────────────────────────────────────────────────────────

@test "cmd_shell: no passthrough -> runs bash" {
  _run_cmd_shell "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run --rm --name drydock-"* ]]
  [[ "$output" == *"-shell "* ]]
  [[ "$output" == *" drydock bash" ]]
}

@test "cmd_shell: DIR -- ls -la -> runs ls -la, not bash" {
  _run_cmd_shell "$BATS_TEST_TMPDIR" -- ls -la
  [ "$status" -eq 0 ]
  [[ "$output" == *"run --rm --name drydock-"* ]]
  [[ "$output" == *"-shell "* ]]
  [[ "$output" == *" drydock ls -la" ]]
  [[ "$output" != *"drydock bash"* ]]
}

# ── main() dispatch tests ──────────────────────────────────────────────────────

@test "main -- --resume foo -> routes to cmd_run with passthrough" {
  _run_main -- --resume foo
  [ "$status" -eq 0 ]
  [[ "$output" == *"run --rm --name drydock-"* ]]
  [[ "$output" == *" drydock claude --resume foo" ]]
}

@test "main run -- --resume foo -> routes to cmd_run with passthrough" {
  _run_main run -- --resume foo
  [ "$status" -eq 0 ]
  [[ "$output" == *"run --rm --name drydock-"* ]]
  [[ "$output" == *" drydock claude --resume foo" ]]
}
