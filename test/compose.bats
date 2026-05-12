#!/usr/bin/env bats
# test/compose.bats — compose_files and export_compose_env function tests
#
# Spec: Behavior Preservation → Scenarios:
#   "compose_files — no docs sub-mount"
#   "compose_files — docs sub-mount present"
#   export_compose_env sets all 7 required env vars
#   "no hardcoded /home/rai in build/compose artifacts" (parameterize-paths)

load "helpers/load"

setup() {
  # Source bin/drydock so compose_files and export_compose_env are defined.
  # shellcheck disable=SC1090
  source "$DRYDOCK_HOME/bin/drydock"

  # Create a fresh test project directory.
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/myproject"
  mkdir -p "$TEST_PROJECT_DIR"

  # Default: synthetic mounts file with NO entry for the project dir.
  MOUNTS_FILE_NO_DOCS="$BATS_TEST_TMPDIR/proc-mounts-nodocs"
  cat > "$MOUNTS_FILE_NO_DOCS" <<'MOUNTS'
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev 0 0
MOUNTS

  # Synthetic mounts file WITH an entry for $TEST_PROJECT_DIR/docs.
  DOCS_MOUNT_POINT="$TEST_PROJECT_DIR/docs"
  mkdir -p "$DOCS_MOUNT_POINT"
  MOUNTS_FILE_WITH_DOCS="$BATS_TEST_TMPDIR/proc-mounts-withdocs"
  # The second field is the mount point; must be an existing path.
  cat > "$MOUNTS_FILE_WITH_DOCS" <<MOUNTS
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
drvfs $DOCS_MOUNT_POINT 9p rw,noatime,uid=1000,gid=1000 0 0
MOUNTS
}

# ── compose_files tests ──────────────────────────────────────────────────────

@test "compose_files: no docs sub-mount — output contains -f and COMPOSE_BASE" {
  export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
  run compose_files "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-f"* ]]
  [[ "$output" == *"docker-compose.yml"* ]]
}

@test "compose_files: no docs sub-mount — output does NOT contain COMPOSE_DOCS" {
  export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
  run compose_files "$TEST_PROJECT_DIR"
  [[ "$output" != *"docker-compose.docs.yml"* ]]
}

@test "compose_files: with docs sub-mount — output contains COMPOSE_BASE and COMPOSE_DOCS" {
  export MOUNTS_FILE="$MOUNTS_FILE_WITH_DOCS"
  run compose_files "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker-compose.yml"* ]]
  [[ "$output" == *"docker-compose.docs.yml"* ]]
}

@test "compose_files: docs dir exists but NOT in mounts file — no overlay" {
  # docs dir exists but MOUNTS_FILE has no entry for it.
  mkdir -p "$TEST_PROJECT_DIR/docs"
  export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
  run compose_files "$TEST_PROJECT_DIR"
  [[ "$output" != *"docker-compose.docs.yml"* ]]
}

# ── export_compose_env tests ─────────────────────────────────────────────────

@test "export_compose_env sets PROJECT_DIR" {
  export_compose_env "$TEST_PROJECT_DIR"
  [ -n "$PROJECT_DIR" ]
  [ "$PROJECT_DIR" = "$TEST_PROJECT_DIR" ]
}

@test "export_compose_env sets PROJECT_NAME to basename of dir" {
  export_compose_env "$TEST_PROJECT_DIR"
  [ -n "$PROJECT_NAME" ]
  [ "$PROJECT_NAME" = "myproject" ]
}

@test "export_compose_env sets USER_UID" {
  export_compose_env "$TEST_PROJECT_DIR"
  [ -n "$USER_UID" ]
}

@test "export_compose_env sets USER_GID" {
  export_compose_env "$TEST_PROJECT_DIR"
  [ -n "$USER_GID" ]
}

@test "export_compose_env sets HOST_DOCKER_GID" {
  export_compose_env "$TEST_PROJECT_DIR"
  # HOST_DOCKER_GID may be the real docker socket GID or the fallback 1001.
  [ -n "$HOST_DOCKER_GID" ]
}

@test "export_compose_env sets COMPOSE_PROJECT_NAME with drydock- prefix" {
  export_compose_env "$TEST_PROJECT_DIR"
  [ -n "$COMPOSE_PROJECT_NAME" ]
  [[ "$COMPOSE_PROJECT_NAME" == "drydock-myproject" ]]
}

@test "export_compose_env sets USER_NAME to id -un" {
  export_compose_env "$TEST_PROJECT_DIR"
  [ -n "$USER_NAME" ]
  [ "$USER_NAME" = "$(id -un)" ]
}

# ── build/compose artifact hygiene ───────────────────────────────────────────

@test "no hardcoded /home/rai in build/compose artifacts" {
  # parameterize-paths: container user + host paths derive from the invoking
  # user; no literal /home/rai may survive in the build inputs.
  ! grep -n '/home/rai' \
    "$DRYDOCK_HOME/Dockerfile" \
    "$DRYDOCK_HOME/docker-compose.yml" \
    "$DRYDOCK_HOME/docker-compose.docs.yml"
}
