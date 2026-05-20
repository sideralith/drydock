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


@test "drydock init: settings.json has _comment field" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  grep -q '_comment' "$SETTINGS_FILE"
}

@test "drydock init: settings.json declares the canonical \$schema URL" {
  # The schemastore validator (and Claude Code's /doctor) expects the trailing
  # `.json` — `https://json.schemastore.org/claude-code-settings.json`. Guard
  # against the template regressing to the suffix-less form.
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  run jq -r '."$schema"' "$SETTINGS_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "https://json.schemastore.org/claude-code-settings.json" ]
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


@test "drydock init: unknown flag errors" {
  run bash -c '"$1" init --bogus "$2" 2>&1' -- "$DRYDOCK_HOME/bin/drydock" "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "drydock init: --update flag errors as unknown option" {
  run bash -c '"$1" init --update "$2" 2>&1' -- "$DRYDOCK_HOME/bin/drydock" "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

# ── stub content assertions (design D4, D5, D6) ──────────────────────────────

@test "drydock init: settings.json stub has no drydock policy deny entries" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  local count
  count="$(jq '(.permissions.deny // []) | length' "$SETTINGS_FILE")"
  [ "$count" -eq 0 ]
}

@test "drydock init: settings.json stub has no hooks.SessionStart entry" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  local count
  count="$(jq '(.hooks.SessionStart // []) | length' "$SETTINGS_FILE")"
  [ "$count" -eq 0 ]
}

@test "lib/commands.sh: cmd_init does not perform __HOME__ substitution" {
  ! grep -q '__HOME__' "$DRYDOCK_HOME/lib/commands.sh"
  ! grep -q '__HOME__' "$DRYDOCK_HOME/templates/default-settings.json"
}
