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
	HOME="$BATS_TEST_TMPDIR/fakehome"
	mkdir -p "$HOME/.config/drydock/keys"
	: >"$HOME/.config/drydock/keys/myproject_deploy"
	export_compose_env "$TEST_PROJECT_DIR"
	[ "$DRYDOCK_SSH_DEPLOY_KEY" = "$HOME/.config/drydock/keys/myproject_deploy" ]
}

@test "export_compose_env: no deploy key — DRYDOCK_SSH_DEPLOY_KEY unset" {
	HOME="$BATS_TEST_TMPDIR/fakehome"
	export_compose_env "$TEST_PROJECT_DIR"
	[ -z "${DRYDOCK_SSH_DEPLOY_KEY:-}" ]
}

@test "export_compose_env: signing dir with a key — sets DRYDOCK_GPG_SIGNINGKEY" {
	command -v gpg >/dev/null 2>&1 || skip "gpg not installed"
	HOME="$BATS_TEST_TMPDIR/fakehome"
	mkdir -p "$HOME/.config/drydock/signing"
	chmod 700 "$HOME/.config/drydock/signing"
	GNUPGHOME="$HOME/.config/drydock/signing" gpg --batch --pinentry-mode loopback --passphrase '' \
		--quick-generate-key "drydock test <t@example.com>" ed25519 sign 0 >/dev/null 2>&1 \
		|| skip "gpg quick-generate-key unavailable on this runner"
	export_compose_env "$TEST_PROJECT_DIR"
	[ -n "${DRYDOCK_GPG_SIGNINGKEY:-}" ]
	[ "$DRYDOCK_GPG_SIGNING_HOME" = "$HOME/.config/drydock/signing" ]
}

# ── engram overlay (compose gate) ────────────────────────────────────────────

@test "compose_files: no DRYDOCK_ENGRAM_SOURCE — engram overlay absent" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	unset DRYDOCK_ENGRAM_SOURCE
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" != *"docker-compose.engram.yml"* ]]
}

@test "compose_files: DRYDOCK_ENGRAM_SOURCE set — engram overlay present" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export DRYDOCK_ENGRAM_SOURCE="$BATS_TEST_TMPDIR/fakehome/.engram-container"
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" == *"docker-compose.engram.yml"* ]]
}

@test "export_compose_env: engram usable (engram on PATH + Linux) — DRYDOCK_ENGRAM_SOURCE set to engram-container" {
	# Simulate engram on PATH via a fake binary in a tmpdir.
	local fake_bin="$BATS_TEST_TMPDIR/fake-bin"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\n' >"$fake_bin/engram"
	chmod +x "$fake_bin/engram"
	export PATH="$fake_bin:$PATH"
	# Override OSRELEASE_FILE to plain Linux (not WSL2) so host_fs_locks_unreliable
	# doesn't interfere; and UNAME to Linux so host_is_linux returns true.
	local plain_osrelease="$BATS_TEST_TMPDIR/osrelease-plain"
	printf '6.5.0-45-generic\n' >"$plain_osrelease"
	export OSRELEASE_FILE="$plain_osrelease"
	local uname_stub_dir="$BATS_TEST_TMPDIR/uname-stub-ece"
	mkdir -p "$uname_stub_dir"
	printf '#!/usr/bin/env bash\necho "Linux"\n' >"$uname_stub_dir/uname-cmd"
	chmod +x "$uname_stub_dir/uname-cmd"
	export UNAME="$uname_stub_dir/uname-cmd"
	HOME="$BATS_TEST_TMPDIR/fakehome"
	mkdir -p "$HOME"
	export_compose_env "$TEST_PROJECT_DIR"
	[ -n "${DRYDOCK_ENGRAM_SOURCE:-}" ]
	[ "$DRYDOCK_ENGRAM_SOURCE" = "$HOME/.engram-container" ]
}

@test "export_compose_env: engram not on PATH — DRYDOCK_ENGRAM_SOURCE unset" {
	# Prepend a dir with no engram binary and replace PATH so engram is absent.
	local empty_bin="$BATS_TEST_TMPDIR/empty-bin-no-engram"
	mkdir -p "$empty_bin"
	# Keep system paths for mkdir/stat/etc but strip ~/.local/bin where engram lives.
	export PATH="$empty_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	unset DRYDOCK_ENGRAM_SOURCE
	HOME="$BATS_TEST_TMPDIR/fakehome"
	mkdir -p "$HOME"
	export_compose_env "$TEST_PROJECT_DIR"
	[ -z "${DRYDOCK_ENGRAM_SOURCE:-}" ]
}

@test "export_compose_env: macOS host (UNAME→Darwin) — DRYDOCK_ENGRAM_SOURCE unset even with engram on PATH" {
	local fake_bin="$BATS_TEST_TMPDIR/fake-bin-macos"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\n' >"$fake_bin/engram"
	chmod +x "$fake_bin/engram"
	export PATH="$fake_bin:$PATH"
	local stub_dir="$BATS_TEST_TMPDIR/uname-darwin"
	mkdir -p "$stub_dir"
	printf '#!/usr/bin/env bash\necho "Darwin"\n' >"$stub_dir/uname-cmd"
	chmod +x "$stub_dir/uname-cmd"
	export UNAME="$stub_dir/uname-cmd"
	HOME="$BATS_TEST_TMPDIR/fakehome"
	mkdir -p "$HOME"
	export_compose_env "$TEST_PROJECT_DIR"
	[ -z "${DRYDOCK_ENGRAM_SOURCE:-}" ]
}

# ── shared mode (PR2) ─────────────────────────────────────────────────────────
# Shared helpers for PR2 tests: fake engram on PATH + plain Linux seams.

_setup_pr2_engram_and_linux() {
	local fake_bin="$BATS_TEST_TMPDIR/fake-bin-pr2-$$"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\n' >"$fake_bin/engram"
	chmod +x "$fake_bin/engram"
	export PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	local plain_osrelease="$BATS_TEST_TMPDIR/osrelease-pr2-$$"
	printf '6.5.0-45-generic\n' >"$plain_osrelease"
	export OSRELEASE_FILE="$plain_osrelease"
	local stub_dir="$BATS_TEST_TMPDIR/uname-linux-pr2-$$"
	mkdir -p "$stub_dir"
	printf '#!/usr/bin/env bash\necho "Linux"\n' >"$stub_dir/uname"
	chmod +x "$stub_dir/uname"
	export UNAME="$stub_dir/uname"
}

@test "export_compose_env: shared sentinel present + usable + plain Linux — DRYDOCK_ENGRAM_SOURCE set to ~/.engram" {
	_setup_pr2_engram_and_linux
	HOME="$BATS_TEST_TMPDIR/fakehome-shared-$$"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/engram-shared"
	unset DRYDOCK_ENGRAM_SOURCE
	local stderr_file="$BATS_TEST_TMPDIR/stderr-shared-$$"
	export_compose_env "$TEST_PROJECT_DIR" 2>"$stderr_file"
	[ "$DRYDOCK_ENGRAM_SOURCE" = "$HOME/.engram" ]
	# native-Linux shared mode emits a one-line multi-writer caveat warn to stderr
	grep -q "avoid running host Claude" "$stderr_file"
}

@test "export_compose_env: no sentinel + usable + plain Linux — DRYDOCK_ENGRAM_SOURCE set to ~/.engram-container (isolated)" {
	_setup_pr2_engram_and_linux
	HOME="$BATS_TEST_TMPDIR/fakehome-isolated-$$"
	mkdir -p "$HOME"
	rm -f "$HOME/.config/drydock/engram-shared"
	unset DRYDOCK_ENGRAM_SOURCE
	export_compose_env "$TEST_PROJECT_DIR"
	[ "$DRYDOCK_ENGRAM_SOURCE" = "$HOME/.engram-container" ]
}

@test "export_compose_env: sentinel + WSL2 (OSRELEASE_FILE=microsoft) — DRYDOCK_ENGRAM_SOURCE forced isolated" {
	_setup_pr2_engram_and_linux
	# Override OSRELEASE_FILE to WSL2 kernel
	local wsl2_osrelease="$BATS_TEST_TMPDIR/osrelease-wsl2-$$"
	printf '6.6.87.2-microsoft-standard-WSL2\n' >"$wsl2_osrelease"
	export OSRELEASE_FILE="$wsl2_osrelease"
	HOME="$BATS_TEST_TMPDIR/fakehome-wsl2-$$"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/engram-shared"
	unset DRYDOCK_ENGRAM_SOURCE
	local stderr_file="$BATS_TEST_TMPDIR/stderr-wsl2-$$"
	export_compose_env "$TEST_PROJECT_DIR" 2>"$stderr_file"
	[ "${DRYDOCK_ENGRAM_SOURCE:-}" = "$HOME/.engram-container" ]
	# WSL2 downgrade: warn must mention lock unreliability
	grep -q "POSIX locks unreliable" "$stderr_file"
}

@test "export_compose_env: sentinel + macOS (UNAME=Darwin) — DRYDOCK_ENGRAM_SOURCE forced isolated" {
	local fake_bin="$BATS_TEST_TMPDIR/fake-bin-darwin-pr2-$$"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\n' >"$fake_bin/engram"
	chmod +x "$fake_bin/engram"
	export PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	# macOS seams — BUT on macOS host_is_linux() returns false so engram_usable() is false
	# macOS with engram on PATH still fails engram_usable because host_is_linux is false
	# so DRYDOCK_ENGRAM_SOURCE stays unset (not forced-isolated path — just unset)
	# Actually: on macOS engram_usable() = false → we never enter the engram block
	# So the test is: DRYDOCK_ENGRAM_SOURCE must be unset (same as absent case)
	local stub_dir="$BATS_TEST_TMPDIR/uname-darwin-pr2-$$"
	mkdir -p "$stub_dir"
	printf '#!/usr/bin/env bash\necho "Darwin"\n' >"$stub_dir/uname"
	chmod +x "$stub_dir/uname"
	export UNAME="$stub_dir/uname"
	HOME="$BATS_TEST_TMPDIR/fakehome-darwin-pr2-$$"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/engram-shared"
	unset DRYDOCK_ENGRAM_SOURCE
	export_compose_env "$TEST_PROJECT_DIR"
	[ -z "${DRYDOCK_ENGRAM_SOURCE:-}" ]
}

@test "export_compose_env: sentinel + WSL2 + DRYDOCK_ENGRAM_SHARED=force — DRYDOCK_ENGRAM_SOURCE set to ~/.engram" {
	_setup_pr2_engram_and_linux
	local wsl2_osrelease="$BATS_TEST_TMPDIR/osrelease-wsl2-force-$$"
	printf '6.6.87.2-microsoft-standard-WSL2\n' >"$wsl2_osrelease"
	export OSRELEASE_FILE="$wsl2_osrelease"
	HOME="$BATS_TEST_TMPDIR/fakehome-force-$$"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/engram-shared"
	export DRYDOCK_ENGRAM_SHARED=force
	unset DRYDOCK_ENGRAM_SOURCE
	local stderr_file="$BATS_TEST_TMPDIR/stderr-force-$$"
	export_compose_env "$TEST_PROJECT_DIR" 2>"$stderr_file"
	[ "$DRYDOCK_ENGRAM_SOURCE" = "$HOME/.engram" ]
	# force override on WSL2: sharper warn about bypassing data-safety check
	grep -q "shared DB override active" "$stderr_file"
	unset DRYDOCK_ENGRAM_SHARED
}

@test "export_compose_env: no sentinel + DRYDOCK_ENGRAM_SHARED=force — still isolated (force without sentinel is no-op)" {
	_setup_pr2_engram_and_linux
	HOME="$BATS_TEST_TMPDIR/fakehome-force-nosentinel-$$"
	mkdir -p "$HOME"
	rm -f "$HOME/.config/drydock/engram-shared"
	export DRYDOCK_ENGRAM_SHARED=force
	unset DRYDOCK_ENGRAM_SOURCE
	export_compose_env "$TEST_PROJECT_DIR"
	[ "$DRYDOCK_ENGRAM_SOURCE" = "$HOME/.engram-container" ]
	unset DRYDOCK_ENGRAM_SHARED
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
