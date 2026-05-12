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

@test "drydock init: settings.json has at least one deny entry with HOME path" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # At least one deny entry referencing the actual home directory must exist.
  grep -q "Read($HOME/.ssh" "$SETTINGS_FILE"
}

@test "drydock init: settings.json denies the drydock credential dir" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # optional-git-credentials: deploy key + sandbox GPG key live under
  # ~/.config/drydock/ and must be off-limits to the agent's file tools.
  grep -q "Read($HOME/.config/drydock/" "$SETTINGS_FILE"
}

@test "drydock init: settings.json denies git force-push" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  grep -q 'git push --force' "$SETTINGS_FILE"
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

# ── drydock init --update tests ───────────────────────────────────────────────

@test "drydock init --update creates settings.json when absent" {
  run "$DRYDOCK_HOME/bin/drydock" init --update "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -f "$SETTINGS_FILE" ]
  grep -q "Read($HOME/.ssh" "$SETTINGS_FILE"
}

@test "drydock init --update merges new template denies into an existing file" {
  mkdir -p "$TEST_PROJECT_DIR/.claude"
  cat > "$SETTINGS_FILE" <<JSON
{ "permissions": { "deny": [ "Read($HOME/.ssh/**)", "Read(/tmp/custom/**)" ], "allow": [ "Bash(ls *)" ] } }
JSON
  run "$DRYDOCK_HOME/bin/drydock" init --update "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  grep -q "Read(/tmp/custom/" "$SETTINGS_FILE"
  grep -q '"Bash(ls \*)"' "$SETTINGS_FILE"
  grep -q "Read($HOME/.config/drydock/" "$SETTINGS_FILE"
  grep -q 'git push --force' "$SETTINGS_FILE"
}

@test "drydock init --update is a no-op when settings.json already has all template denies" {
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  saved="$(cat "$SETTINGS_FILE")"

  run "$DRYDOCK_HOME/bin/drydock" init --update "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sin cambios"* ]]
  [ "$(cat "$SETTINGS_FILE")" = "$saved" ]
}

@test "drydock init --update errors on invalid JSON" {
  mkdir -p "$TEST_PROJECT_DIR/.claude"
  printf 'not json\n' > "$SETTINGS_FILE"
  run bash -c '"$1" init --update "$2" 2>&1' -- "$DRYDOCK_HOME/bin/drydock" "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"JSON"* ]]
}

@test "drydock init: unknown flag errors" {
  run bash -c '"$1" init --bogus "$2" 2>&1' -- "$DRYDOCK_HOME/bin/drydock" "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"opción desconocida"* ]]
}
