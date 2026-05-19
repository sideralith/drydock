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

  # Hermetic seam: unrelated tests must not be perturbed by real host submounts.
  export MOUNTINFO_FILE=/dev/null
  # Hermetic SUBMOUNT_OVERLAY so compose_files doesn't write to /tmp.
  export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/submount.yml"

  # Default DOCKER stub: returns empty for "ps" sub-commands so export_compose_env
  # GC/collision-check/seed calls are safe for tests that don't stub DOCKER.
  local _default_docker_stub="$BATS_TEST_TMPDIR/default-docker-stub-$$"
  cat >"$_default_docker_stub" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "ps" ]; then printf ''; fi
exit 0
STUB
  chmod +x "$_default_docker_stub"
  export DOCKER="$_default_docker_stub"

  # Default discriminator stub: emit "dflt" for predictable test output.
  _default_disc() { printf 'dflt'; }
  export DRYDOCK_DISCRIMINATOR_FN=_default_disc

  # Default fake HOME with prototype dirs for export_compose_env calls.
  local _default_home="$BATS_TEST_TMPDIR/default-home-$$"
  mkdir -p "$_default_home/.claude-container"
  touch "$_default_home/.claude-container.json"
  export HOME="$_default_home"
}

# ── compose_files tests ──────────────────────────────────────────────────────

@test "compose_files: no docs sub-mount — output contains -f and COMPOSE_BASE" {
  export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
  run compose_files "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-f"* ]]
  [[ "$output" == *"docker-compose.yml"* ]]
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

@test "export_compose_env sets COMPOSE_PROJECT_NAME with drydock- prefix and discriminator" {
  _fixed_disc() { printf 'test'; }
  export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc
  # Stub DOCKER for collision-check and GC (empty ps = no containers).
  local stub_file="$BATS_TEST_TMPDIR/docker-disc-stub-$$"
  cat >"$stub_file" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "ps" ]; then printf ''; fi
exit 0
STUB
  chmod +x "$stub_file"
  export DOCKER="$stub_file"
  export HOME="$BATS_TEST_TMPDIR/compose-ecpn-home-$$"
  mkdir -p "$HOME/.claude-container"
  touch "$HOME/.claude-container.json"
  export_compose_env "$TEST_PROJECT_DIR"
  [ -n "$COMPOSE_PROJECT_NAME" ]
  [[ "$COMPOSE_PROJECT_NAME" == "drydock-myproject-test" ]]
}

@test "export_compose_env sets USER_NAME to id -un" {
  export_compose_env "$TEST_PROJECT_DIR"
  [ -n "$USER_NAME" ]
  [ "$USER_NAME" = "$(id -un)" ]
}

# ── optional git-credential overlays (ssh deploy key + sandbox gpg) ──────────

@test "compose_files: no DRYDOCK_SSH_DEPLOY_KEY — ssh overlay absent" {
  export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
  run compose_files "$TEST_PROJECT_DIR"
  [[ "$output" != *"docker-compose.ssh.yml"* ]]
}

@test "compose_files: DRYDOCK_SSH_DEPLOY_KEY set — ssh overlay present" {
  export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
  export DRYDOCK_SSH_DEPLOY_KEY="$BATS_TEST_TMPDIR/fake_deploy"
  run compose_files "$TEST_PROJECT_DIR"
  [[ "$output" == *"docker-compose.ssh.yml"* ]]
}

@test "compose_files: no DRYDOCK_GPG_SIGNINGKEY — gpg overlay absent" {
  export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
  run compose_files "$TEST_PROJECT_DIR"
  [[ "$output" != *"docker-compose.gpg.yml"* ]]
}

@test "compose_files: DRYDOCK_GPG_SIGNINGKEY set — gpg overlay present" {
  export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
  export DRYDOCK_GPG_SIGNINGKEY="DEADBEEFCAFE"
  run compose_files "$TEST_PROJECT_DIR"
  [[ "$output" == *"docker-compose.gpg.yml"* ]]
}

@test "export_compose_env: deploy key present — sets DRYDOCK_SSH_DEPLOY_KEY" {
  HOME="$BATS_TEST_TMPDIR/fakehome-dk-$$"
  mkdir -p "$HOME/.config/drydock/keys"
  mkdir -p "$HOME/.claude-container"
  touch "$HOME/.claude-container.json"
  : > "$HOME/.config/drydock/keys/myproject_deploy"
  export_compose_env "$TEST_PROJECT_DIR"
  [ "$DRYDOCK_SSH_DEPLOY_KEY" = "$HOME/.config/drydock/keys/myproject_deploy" ]
}

@test "export_compose_env: no deploy key — DRYDOCK_SSH_DEPLOY_KEY unset" {
  HOME="$BATS_TEST_TMPDIR/fakehome-nodk-$$"
  mkdir -p "$HOME/.claude-container"
  touch "$HOME/.claude-container.json"
  export_compose_env "$TEST_PROJECT_DIR"
  [ -z "${DRYDOCK_SSH_DEPLOY_KEY:-}" ]
}

# ── build/compose artifact hygiene ───────────────────────────────────────────

@test "no hardcoded /home/rai in build/compose artifacts" {
  # parameterize-paths + optional-git-credentials: container user + host paths
  # derive from the invoking user; no literal /home/rai may survive.
  ! grep -n '/home/rai' \
    "$DRYDOCK_HOME/Dockerfile" \
    "$DRYDOCK_HOME/docker-compose.yml" \
    "$DRYDOCK_HOME/docker-compose.ssh.yml" \
    "$DRYDOCK_HOME/docker-compose.gpg.yml" \
    "$DRYDOCK_HOME/docker-compose.engram.yml"
}

@test "no ~/.ssh or ~/.gnupg bind-mount in any compose file" {
  # The drydock-namespace invariant: credential material lives under
  # ~/.config/drydock/, never ~/.ssh or ~/.gnupg, so the hook/deny rules on
  # those host dirs stay strong and unconditional. Check volume list-items only
  # (explanatory comments may mention .ssh/.gnupg — that's fine).
  run bash -c 'grep -hE "^[[:space:]]+- " "$1"/docker-compose*.yml | grep -E "\.(ssh|gnupg)/" || true' -- "$DRYDOCK_HOME"
  [ -z "$output" ]
}

@test "base compose forwards GITHUB_PERSONAL_ACCESS_TOKEN from the invoking shell" {
  # The GitHub MCP server (and `gh` PAT auth) read GITHUB_PERSONAL_ACCESS_TOKEN
  # from the process environment. `docker compose run` does not inherit the
  # host environment, so the base compose declares a value-less passthrough:
  # claude inside the box sees the var iff the shell that invoked drydock had
  # it set. (~/.config/gh is already mounted RW, so this widens nothing — the
  # agent could already `gh auth token`.)
  grep -qE '^[[:space:]]+- GITHUB_PERSONAL_ACCESS_TOKEN[[:space:]]*$' \
    "$DRYDOCK_HOME/docker-compose.yml"
}

# ── docker-compose.yml parametrization (concurrent-sessions, PR 2 Wire-in) ───
# Task 2.4: verify docker-compose.yml uses per-session env vars for container_name
# and Claude config mounts. These tests check the YAML source directly (grepping
# for the expected variable interpolation patterns).

@test "docker-compose.yml: container_name uses DRYDOCK_DISCRIMINATOR in interpolation" {
  # After PR 2, container_name must include ${DRYDOCK_DISCRIMINATOR} so each
  # session gets a unique container name.
  grep -qE 'container_name:.*\$\{DRYDOCK_DISCRIMINATOR\}' \
    "$DRYDOCK_HOME/docker-compose.yml"
}

@test "docker-compose.yml: Claude dir mount uses DRYDOCK_SESSION_CLAUDE_DIR" {
  # The per-session Claude config dir mount source must reference
  # ${DRYDOCK_SESSION_CLAUDE_DIR} instead of the old ${HOME}/.claude-container.
  grep -qF '${DRYDOCK_SESSION_CLAUDE_DIR}' \
    "$DRYDOCK_HOME/docker-compose.yml"
}

@test "docker-compose.yml: Claude json mount uses DRYDOCK_SESSION_CLAUDE_JSON" {
  # The per-session Claude config json mount source must reference
  # ${DRYDOCK_SESSION_CLAUDE_JSON} instead of the old ${HOME}/.claude-container.json.
  grep -qF '${DRYDOCK_SESSION_CLAUDE_JSON}' \
    "$DRYDOCK_HOME/docker-compose.yml"
}

@test "docker-compose.yml: old hardcoded .claude-container mount is gone" {
  # Ensure the old literal ${HOME}/.claude-container: mount is replaced.
  # Note: .claude-container/ itself (as a string) should not appear in volume
  # source positions — only the new ${DRYDOCK_SESSION_*} vars should.
  ! grep -E '^\s+-\s+"\$\{HOME\}/\.claude-container:' \
    "$DRYDOCK_HOME/docker-compose.yml"
}
