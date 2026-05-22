#!/usr/bin/env bats
# test/examples.bats — drydock examples directory tests
#
# Scope (v0.2.1+, after `drydock init` removal):
#   - examples/web-stack/docker-compose.yml parses with `docker compose config`
#
# The previous `drydock init populates settings.json` tests (for both
# examples/minimal/ and examples/web-stack/) were removed when `drydock init`
# itself was removed in v0.2.1 — examples now ship without a `.claude/` and
# rely on the image-baked managed-settings layer (INV-3).

load "helpers/load"

setup() {
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/example-copy"
  mkdir -p "$TEST_PROJECT_DIR"
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
