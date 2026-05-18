#!/usr/bin/env bats
# test/examples.bats — drydock examples directory tests
#
# Spec: examples-directory acceptance criteria (AC #5)
#   - examples/minimal/ accepts `drydock init`
#   - examples/web-stack/ accepts `drydock init`
#   - examples/web-stack/docker-compose.yml parses with `docker compose config`

load "helpers/load"

setup() {
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/example-copy"
  mkdir -p "$TEST_PROJECT_DIR"
}

@test "examples/minimal/: drydock init populates settings.json" {
  cp -r "$DRYDOCK_HOME/examples/minimal/." "$TEST_PROJECT_DIR/"
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT_DIR/.claude/settings.json" ]
  ! grep -q '__HOME__' "$TEST_PROJECT_DIR/.claude/settings.json"
  run jq -e '."$schema"' "$TEST_PROJECT_DIR/.claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "examples/web-stack/: drydock init populates settings.json" {
  cp -r "$DRYDOCK_HOME/examples/web-stack/." "$TEST_PROJECT_DIR/"
  run "$DRYDOCK_HOME/bin/drydock" init "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT_DIR/.claude/settings.json" ]
  ! grep -q '__HOME__' "$TEST_PROJECT_DIR/.claude/settings.json"
  run jq -e '."$schema"' "$TEST_PROJECT_DIR/.claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "examples/web-stack/docker-compose.yml parses with docker compose config" {
  if ! command -v docker >/dev/null 2>&1; then
    skip "docker not available"
  fi
  rm -rf "$BATS_TMPDIR/ws-test"
  cp -r "$DRYDOCK_HOME/examples/web-stack" "$BATS_TMPDIR/ws-test"
  cp "$BATS_TMPDIR/ws-test/.env.example" "$BATS_TMPDIR/ws-test/.env"
  run docker compose -f "$BATS_TMPDIR/ws-test/docker-compose.yml" \
    --project-directory "$BATS_TMPDIR/ws-test" config
  [ "$status" -eq 0 ]
}
