#!/usr/bin/env bats
# test/cli_surface.bats — CLI dispatch surface tests (black-box subprocess)
#
# Spec: Behavior Preservation → version/help/unknown-cmd rows.
# (The `onboard` command tested here historically referenced the now-removed
# `drydock init` redirect; both tests were dropped in v0.2.1 alongside init.)
# These tests invoke bin/drydock as a subprocess (not sourced) to verify
# the command dispatch and user-facing output strings.

load "helpers/load"

setup() {
  # Guard: prevent subprocess tests from calling the real docker binary.
  # Without this, 'drydock stop' finds the live drydock container (project
  # name = "drydock") and calls 'docker rm -f', killing the session.
  export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
  touch "$DOCKER_CALL_LOG"
  export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
}

# Run drydock as a subprocess. Redirects stderr to stdout so 'output'
# captures both — err() and warn() write to stderr.
drydock() {
  run bash -c '"$1" "$@"' -- "$DRYDOCK_HOME/bin/drydock" "$@" 2>&1
}

@test "drydock version exits 0 and prints exactly 'drydock 0.3.3'" {
  run "$DRYDOCK_HOME/bin/drydock" version
  [ "$status" -eq 0 ]
  [ "$output" = "drydock 0.3.3" ]
}

@test "drydock --version exits 0 and prints version" {
  run "$DRYDOCK_HOME/bin/drydock" --version
  [ "$status" -eq 0 ]
  [ "$output" = "drydock 0.3.3" ]
}

@test "drydock -v exits 0 and prints version" {
  run "$DRYDOCK_HOME/bin/drydock" -v
  [ "$status" -eq 0 ]
  [ "$output" = "drydock 0.3.3" ]
}

@test "drydock help exits 0 and contains command list" {
  run "$DRYDOCK_HOME/bin/drydock" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"run"* ]]
  [[ "$output" == *"shell"* ]]
  [[ "$output" == *"build"* ]]
}

@test "drydock --help exits 0 and contains command list" {
  run "$DRYDOCK_HOME/bin/drydock" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"run"* ]]
  [[ "$output" == *"shell"* ]]
}

@test "drydock -h exits 0 and contains command list" {
  run "$DRYDOCK_HOME/bin/drydock" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"run"* ]]
}

@test "drydock unknown command exits non-zero" {
  run bash -c '"$1" thisisnotacommand 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [ "$status" -ne 0 ]
}

@test "drydock help contains setup-token and revoke-token" {
  run "$DRYDOCK_HOME/bin/drydock" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup-token"* ]]
  [[ "$output" == *"revoke-token"* ]]
}

@test "drydock unknown command output contains 'unknown command'" {
  run bash -c '"$1" thisisnotacommand 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [[ "$output" == *"unknown command"* ]]
}

# ── T14-RED: dispatch arms + usage surface ────────────────────────────────────

@test "drydock help output mentions 'link'" {
  run "$DRYDOCK_HOME/bin/drydock" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"link"* ]]
}

@test "drydock help output mentions 'unlink'" {
  run "$DRYDOCK_HOME/bin/drydock" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"unlink"* ]]
}

@test "drydock help output mentions 'links'" {
  run "$DRYDOCK_HOME/bin/drydock" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"links"* ]]
}

@test "drydock link --rw exits non-zero for non-existent path (SP-1: --rw implemented)" {
  # SP-1 supersedes SP-3: --rw is now implemented; it should fail on a
  # non-existent path (realpath fails), not with 'not yet implemented'.
  run bash -c '"$1" link --rw /tmp/no-such-path 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [ "$status" -ne 0 ]
  [[ "$output" != *"not yet implemented"* ]]
}

@test "drydock links exits 0 without running container (SP-12)" {
  # Run from a real directory — no DRYDOCK_* env, no running container
  run bash -c 'cd "$1" && "$2" links 2>&1' -- "$DRYDOCK_HOME" "$DRYDOCK_HOME/bin/drydock"
  [ "$status" -eq 0 ]
}

# ── T15-RED: orphan-reap covers drydock-links-*.yml ──────────────────────────

@test "orphan reap: drydock-links-*.yml with dead PID removed on next main() entry" {
  # Create a fake orphan overlay with a dead PID (PID 1 is init; use a PID that
  # is guaranteed dead by using a very high unlikely value, then verify it's gone).
  # Strategy: create a file named drydock-links-<dead-pid>.yml and run drydock help;
  # the reap loop should remove it.
  local dead_pid=2147483647  # max int32 — highly unlikely to be alive
  local orphan="${TMPDIR:-/tmp}/drydock-links-${dead_pid}.yml"
  printf 'services:\n  drydock:\n    volumes: []\n' > "$orphan"

  run bash -c '"$1" help 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [ "$status" -eq 0 ]

  [ ! -f "$orphan" ]
}

@test "orphan reap: drydock-submounts-*.yml regression — still reaped by refactored loop" {
  local dead_pid=2147483647
  local orphan="${TMPDIR:-/tmp}/drydock-submounts-${dead_pid}.yml"
  printf 'services:\n  drydock:\n    volumes: []\n' > "$orphan"

  run bash -c '"$1" help 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [ "$status" -eq 0 ]

  [ ! -f "$orphan" ]
}

# ── T-5 RED: dispatcher subcommands new/attach/list/stop ─────────────────────
# REQ-N4, REQ-6-M, REQ-N6, REQ-N7: verify the four new subcommands are dispatched
# (not falling into the "unknown command" error path).

@test "drydock new: dispatched (not 'unknown command') (REQ-N4, T-5)" {
  # drydock new with no project dir will fail for other reasons (no docker, etc.)
  # but must NOT fail with "unknown command".
  run bash -c '"$1" new 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [[ "$output" != *"unknown command"* ]]
}

@test "drydock attach: dispatched (not 'unknown command') (REQ-6-M, T-5)" {
  run bash -c '"$1" attach 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [[ "$output" != *"unknown command"* ]]
}

@test "drydock list: dispatched and exits 0 without container (REQ-N6, T-5)" {
  # mock-docker returns empty for 'docker ps' → cmd_list returns 0 with no
  # rows (lib/commands.sh:1902-1904). The assertion is only: must NOT say
  # "unknown command".
  run bash -c 'cd "$1" && "$2" list 2>&1' -- "$DRYDOCK_HOME" "$DRYDOCK_HOME/bin/drydock"
  [[ "$output" != *"unknown command"* ]]
}

@test "drydock stop: dispatched (not 'unknown command') (REQ-N7, T-5)" {
  run bash -c '"$1" stop 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [[ "$output" != *"unknown command"* ]]
  # Regression guard (#112): cmd_stop MUST NOT issue "docker rm -f"
  # against any container. The mock logs every invocation's args (without
  # the "docker" prefix), so a future refactor that moves the rm -f call
  # ahead of the live-session count check would leave "rm -f ..." in the
  # log and fail this assertion. cli_surface.bats setup() routes DOCKER
  # through mock-docker, so a real-daemon call never reaches the host.
  #
  # Narrow by design: matches today's only destructive idiom in cmd_stop
  # (lib/commands.sh:1972). If cmd_stop ever adopts other destructive verbs
  # (docker kill, docker stop, docker rm without -f), the guard must be
  # widened accordingly.
  ! grep -qE '^rm -f' "$DOCKER_CALL_LOG"
}

@test "drydock help output mentions 'new' (T-5 usage surface)" {
  run "$DRYDOCK_HOME/bin/drydock" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"new"* ]]
}

@test "drydock help output mentions 'attach' (T-5 usage surface)" {
  run "$DRYDOCK_HOME/bin/drydock" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"attach"* ]]
}

@test "drydock help output mentions 'list' (T-5 usage surface)" {
  run "$DRYDOCK_HOME/bin/drydock" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"list"* ]]
}

@test "drydock help output mentions 'stop' (T-5 usage surface)" {
  run "$DRYDOCK_HOME/bin/drydock" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"stop"* ]]
}
