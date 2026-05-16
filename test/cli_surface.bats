#!/usr/bin/env bats
# test/cli_surface.bats — CLI dispatch surface tests (black-box subprocess)
#
# Spec: Behavior Preservation → version/help/unknown-cmd/onboard rows.
# These tests invoke bin/drydock as a subprocess (not sourced) to verify
# the command dispatch and user-facing output strings.

load "helpers/load"

# Run drydock as a subprocess. Redirects stderr to stdout so 'output'
# captures both — err() and warn() write to stderr.
drydock() {
  run bash -c '"$1" "$@"' -- "$DRYDOCK_HOME/bin/drydock" "$@" 2>&1
}

@test "drydock version exits 0 and prints exactly 'drydock 0.1.2' (v0.1.2)" {
  run "$DRYDOCK_HOME/bin/drydock" version
  [ "$status" -eq 0 ]
  [ "$output" = "drydock 0.1.2" ]
}

@test "drydock --version exits 0 and prints version" {
  run "$DRYDOCK_HOME/bin/drydock" --version
  [ "$status" -eq 0 ]
  [ "$output" = "drydock 0.1.2" ]
}

@test "drydock -v exits 0 and prints version" {
  run "$DRYDOCK_HOME/bin/drydock" -v
  [ "$status" -eq 0 ]
  [ "$output" = "drydock 0.1.2" ]
}

@test "drydock help exits 0 and contains command list" {
  run "$DRYDOCK_HOME/bin/drydock" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"run"* ]]
  [[ "$output" == *"init"* ]]
  [[ "$output" == *"build"* ]]
}

@test "drydock --help exits 0 and contains command list" {
  run "$DRYDOCK_HOME/bin/drydock" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"run"* ]]
  [[ "$output" == *"init"* ]]
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

@test "drydock unknown command output contains 'comando desconocido'" {
  run bash -c '"$1" thisisnotacommand 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [[ "$output" == *"comando desconocido"* ]]
}

@test "drydock onboard exits non-zero" {
  run bash -c '"$1" onboard 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [ "$status" -ne 0 ]
}

@test "drydock onboard output mentions 'drydock init'" {
  run bash -c '"$1" onboard 2>&1' -- "$DRYDOCK_HOME/bin/drydock"
  [[ "$output" == *"drydock init"* ]]
}
