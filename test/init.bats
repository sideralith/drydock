#!/usr/bin/env bats
# test/init.bats — drydock init behavior tests
#
# Spec: Behavior Preservation → Scenarios:
#   "drydock init creates settings with substitution"
#   "drydock init is idempotent"

load "helpers/load"

setup() {
  # Each test gets a fresh temporary project directory.
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/test-project"
  mkdir -p "$TEST_PROJECT_DIR"
  SETTINGS_FILE="$TEST_PROJECT_DIR/.claude/settings.json"
}

@test "drydock init creates .claude/settings.json" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -f "$SETTINGS_FILE" ]
}

@test "drydock init: settings.json contains no literal __HOME__" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  ! grep -q '__HOME__' "$SETTINGS_FILE"
}

@test "drydock init: settings.json contains a real HOME-derived path" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # The template substitutes __HOME__ with $HOME. Assert at least one deny
  # entry contains the real $HOME path (e.g. ~/.ssh/).
  grep -q "$HOME/.ssh" "$SETTINGS_FILE"
}

@test "drydock init: settings.json has _comment field" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  grep -q '_comment' "$SETTINGS_FILE"
}

@test "drydock init: settings.json has at least one deny entry with HOME path" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # At least one deny entry referencing the actual home directory must exist.
  grep -q "Read($HOME/.ssh" "$SETTINGS_FILE"
}

@test "drydock init is idempotent: does not overwrite existing settings.json" {
  # First run: creates the file.
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  original_content="$(cat "$SETTINGS_FILE")"

  # Second run: must not overwrite.
  run bash -c '"$1" init "$2" 2>&1' -- "$DRYDOCK_HOME/bin/drydock" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # File content must be unchanged.
  second_content="$(cat "$SETTINGS_FILE")"
  [ "$original_content" = "$second_content" ]
}

@test "drydock init re-run emits a warning" {
  # First run.
  "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"

  # Second run must emit a warn message.
  run bash -c '"$1" init "$2" 2>&1' -- "$DRYDOCK_HOME/bin/drydock" "$TEST_PROJECT_DIR"
  [[ "$output" == *"warn"* ]] || [[ "$output" == *"ya existe"* ]]
}
