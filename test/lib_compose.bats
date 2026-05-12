#!/usr/bin/env bats
# test/lib_compose.bats — unit tests for lib/compose.sh
#
# Sources lib/common.sh + lib/paths.sh + lib/compose.sh directly (not
# bin/drydock). Tests compose_files(), export_compose_env(), and image_exists()
# via the DOCKER seam. Does NOT test ensure_runtime_dirs / ensure_prereqs /
# ensure_image — those reach into cmd_setup/cmd_build from lib/commands.sh.

load "helpers/load"

setup() {
	# Source order mirrors bin/drydock: common → paths → compose.
	# Stub cmd_setup so ensure_runtime_dirs is safe if anything edges toward it.
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"

	# Provide a stub so any accidental call to ensure_runtime_dirs doesn't fail.
	cmd_setup() { :; }

	# Create a fresh test project directory.
	TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/myproject"
	mkdir -p "$TEST_PROJECT_DIR"

	# Synthetic mounts file with NO entry for the project docs dir.
	MOUNTS_FILE_NO_DOCS="$BATS_TEST_TMPDIR/proc-mounts-nodocs"
	cat >"$MOUNTS_FILE_NO_DOCS" <<'MOUNTS'
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev 0 0
MOUNTS

	# Synthetic mounts file WITH an entry for $TEST_PROJECT_DIR/docs.
	DOCS_MOUNT_POINT="$TEST_PROJECT_DIR/docs"
	mkdir -p "$DOCS_MOUNT_POINT"
	MOUNTS_FILE_WITH_DOCS="$BATS_TEST_TMPDIR/proc-mounts-withdocs"
	cat >"$MOUNTS_FILE_WITH_DOCS" <<MOUNTS
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
drvfs $DOCS_MOUNT_POINT 9p rw,noatime,uid=1000,gid=1000 0 0
MOUNTS

	# Docker mock for image_exists tests.
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
	touch "$DOCKER_CALL_LOG"
}

# ── compose_files ─────────────────────────────────────────────────────────────

@test "compose_files: no docs dir — output contains -f and COMPOSE_BASE" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"-f"* ]]
	[[ "$output" == *"docker-compose.yml"* ]]
}

@test "compose_files: no docs dir — output does NOT contain COMPOSE_DOCS" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" != *"docker-compose.docs.yml"* ]]
}

@test "compose_files: docs dir present and in MOUNTS_FILE — adds COMPOSE_DOCS" {
	export MOUNTS_FILE="$MOUNTS_FILE_WITH_DOCS"
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.yml"* ]]
	[[ "$output" == *"docker-compose.docs.yml"* ]]
}

@test "compose_files: docs dir exists but NOT in mounts file — just base" {
	mkdir -p "$TEST_PROJECT_DIR/docs"
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" != *"docker-compose.docs.yml"* ]]
}

# ── export_compose_env ────────────────────────────────────────────────────────

@test "export_compose_env sets PROJECT_DIR" {
	export_compose_env "$TEST_PROJECT_DIR"
	[ "$PROJECT_DIR" = "$TEST_PROJECT_DIR" ]
}

@test "export_compose_env sets PROJECT_NAME to basename" {
	export_compose_env "$TEST_PROJECT_DIR"
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
	[ -n "$HOST_DOCKER_GID" ]
}

@test "export_compose_env sets COMPOSE_PROJECT_NAME with drydock- prefix" {
	export_compose_env "$TEST_PROJECT_DIR"
	[ "$COMPOSE_PROJECT_NAME" = "drydock-myproject" ]
}

@test "export_compose_env sets USER_NAME to id -un" {
	export_compose_env "$TEST_PROJECT_DIR"
	[ -n "$USER_NAME" ]
	[ "$USER_NAME" = "$(id -un)" ]
}

# ── image_exists (via DOCKER mock) ────────────────────────────────────────────

@test "image_exists: mock exits 0 — function returns 0" {
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export MOCK_DOCKER_EXIT=0
	run image_exists
	[ "$status" -eq 0 ]
}

@test "image_exists: mock exits 1 — function returns non-zero" {
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export MOCK_DOCKER_EXIT=1
	run image_exists
	[ "$status" -ne 0 ]
}

@test "image_exists: mock records an 'image inspect' invocation" {
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export MOCK_DOCKER_EXIT=0
	run image_exists
	log_contents="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log_contents" == *"image inspect"* ]]
}
