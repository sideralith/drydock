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

	# Hermetic seam: unrelated ssh/gpg/engram tests must not be perturbed by the
	# host machine having real submounts under $TEST_PROJECT_DIR.
	export MOUNTINFO_FILE=/dev/null
}

# ── compose_files / generate_submount_overlay ─────────────────────────────────

@test "compose_files: no sub-mounts — output contains base only" {
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-no-submounts.txt"
	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/submount.yml"
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.yml"* ]]
	[[ "$output" != *"submount.yml"* ]]
	[ ! -f "$SUBMOUNT_OVERLAY" ]
}

@test "generate_submount_overlay: writes valid YAML when sub-mounts detected" {
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-drvfs-c.txt"
	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/submount.yml"
	generate_submount_overlay "/home/rai/git/serendipilink"
	[ -f "$SUBMOUNT_OVERLAY" ]
	grep -q '^services:' "$SUBMOUNT_OVERLAY"
	grep -q '^  drydock:' "$SUBMOUNT_OVERLAY"
	grep -q '^    volumes:' "$SUBMOUNT_OVERLAY"
	grep -q '/mnt/c/Users/Rai/Documents/Obsidian/Vaults/Serendipilink:/home/rai/git/serendipilink/docs:rw' "$SUBMOUNT_OVERLAY"
	# The overlay must also declare an environment: block with KEY-only entries
	# so docker compose inherits the DRYDOCK_SUBMOUNT_*_HOST_PATH vars from the
	# CLI shell into the container drydock (DooD passthrough).
	grep -q '^    environment:' "$SUBMOUNT_OVERLAY"
	grep -q '^      - DRYDOCK_SUBMOUNT_DOCS_HOST_PATH$' "$SUBMOUNT_OVERLAY"
}

@test "generate_submount_overlay: nested sub-mounts → distinct environment entries" {
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-nested.txt"
	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/submount-nested.yml"
	generate_submount_overlay "/home/rai/git/proj"
	[ -f "$SUBMOUNT_OVERLAY" ]
	grep -q '^      - DRYDOCK_SUBMOUNT_DOCS_HOST_PATH$' "$SUBMOUNT_OVERLAY"
	grep -q '^      - DRYDOCK_SUBMOUNT_DOCS_SUB_HOST_PATH$' "$SUBMOUNT_OVERLAY"
}

@test "generate_submount_overlay: does NOT write file when no sub-mounts" {
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-no-submounts.txt"
	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/submount.yml"
	generate_submount_overlay "$TEST_PROJECT_DIR"
	[ ! -f "$SUBMOUNT_OVERLAY" ]
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

# ── container hardening overlay (default on, literal-"1" opt-out) ────────────
# DRYDOCK_NO_HARDENING=1 (literal) disables; other values do NOT disable.
# Per D-Apply-1: guard is [ "${DRYDOCK_NO_HARDENING:-0}" = "1" ] — only "1" suppresses.

@test "compose_files: default — hardening overlay present" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	unset DRYDOCK_NO_HARDENING
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.hardening.yml"* ]]
}

@test "compose_files: DRYDOCK_NO_HARDENING=1 — hardening overlay absent" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export DRYDOCK_NO_HARDENING=1
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" != *"docker-compose.hardening.yml"* ]]
}

@test "compose_files: DRYDOCK_NO_HARDENING=true — hardening overlay PRESENT (non-\"1\" value does not suppress)" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export DRYDOCK_NO_HARDENING="true"
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.hardening.yml"* ]]
}

@test "compose_files: DRYDOCK_NO_HARDENING=0 — hardening overlay PRESENT (\"0\" is not the disable sentinel)" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export DRYDOCK_NO_HARDENING=0
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.hardening.yml"* ]]
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

# ── mcp-auth + ccstatusline opt-in overlays ───────────────────────────────────

@test "compose_files: no ~/.mcp-auth/ — mcp-auth overlay absent" {
	HOME="$BATS_TEST_TMPDIR/fakehome-no-mcp"
	mkdir -p "$HOME"
	[ ! -d "$HOME/.mcp-auth" ]
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" != *"docker-compose.mcp-auth.yml"* ]]
}

@test "compose_files: ~/.mcp-auth/ exists — mcp-auth overlay present" {
	HOME="$BATS_TEST_TMPDIR/fakehome-with-mcp"
	mkdir -p "$HOME/.mcp-auth"
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" == *"docker-compose.mcp-auth.yml"* ]]
}

@test "compose_files: no ~/.config/ccstatusline/ — ccstatusline overlay absent" {
	HOME="$BATS_TEST_TMPDIR/fakehome-no-ccsl"
	mkdir -p "$HOME"
	[ ! -d "$HOME/.config/ccstatusline" ]
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" != *"docker-compose.ccstatusline.yml"* ]]
}

@test "compose_files: ~/.config/ccstatusline/ exists — ccstatusline overlay present" {
	HOME="$BATS_TEST_TMPDIR/fakehome-with-ccsl"
	mkdir -p "$HOME/.config/ccstatusline"
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" == *"docker-compose.ccstatusline.yml"* ]]
}

@test "compose_files: ccstatusline overlay activates → cache dir auto-created (idempotent)" {
	HOME="$BATS_TEST_TMPDIR/fakehome-ccsl-cache"
	mkdir -p "$HOME/.config/ccstatusline"
	[ ! -d "$HOME/.cache/ccstatusline" ]
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	# Cache dir must exist post-call so the bind mount in the overlay doesn't fail.
	[ -d "$HOME/.cache/ccstatusline" ]
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

# ── DRYDOCK_SUBMOUNT_*_HOST_PATH passthrough (DooD gap) ──────────────────────

@test "export_compose_env: drvfs sub-mount → DRYDOCK_SUBMOUNT_<NAME>_HOST_PATH exported" {
	# Use the drvfs-c fixture (mount_point = /home/rai/git/serendipilink/docs).
	# project_dir basename is "serendipilink", sub-mount relpath is "docs" → DOCS.
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-drvfs-c.txt"
	# Use the fixture's project root path so the prefix filter matches.
	mkdir -p "$BATS_TEST_TMPDIR/serendipilink"
	export_compose_env "/home/rai/git/serendipilink"
	[ "${DRYDOCK_SUBMOUNT_DOCS_HOST_PATH:-}" = "/mnt/c/Users/Rai/Documents/Obsidian/Vaults/Serendipilink" ]
}

@test "export_compose_env: nested sub-mount → distinct env var with relpath name" {
	# Use the nested fixture (mount points docs/ and docs/sub).
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-nested.txt"
	mkdir -p "$BATS_TEST_TMPDIR/proj"
	export_compose_env "/home/rai/git/proj"
	# Both env vars must be set. Nested 'docs/sub' relative to project_dir
	# becomes DOCS_SUB after upper+non-alnum→_.
	[ -n "${DRYDOCK_SUBMOUNT_DOCS_HOST_PATH:-}" ]
	[ -n "${DRYDOCK_SUBMOUNT_DOCS_SUB_HOST_PATH:-}" ]
	[ "$DRYDOCK_SUBMOUNT_DOCS_HOST_PATH" != "$DRYDOCK_SUBMOUNT_DOCS_SUB_HOST_PATH" ]
}

@test "export_compose_env: no sub-mounts → no DRYDOCK_SUBMOUNT_* vars" {
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-no-submounts.txt"
	# Clean any leftover from prior tests in same shell (defensive).
	unset DRYDOCK_SUBMOUNT_DOCS_HOST_PATH DRYDOCK_SUBMOUNT_DOCS_SUB_HOST_PATH
	export_compose_env "$TEST_PROJECT_DIR"
	[ -z "${DRYDOCK_SUBMOUNT_DOCS_HOST_PATH:-}" ]
	[ -z "${DRYDOCK_SUBMOUNT_DOCS_SUB_HOST_PATH:-}" ]
}

@test "export_compose_env: duplicate drvfs mounts → single env var (dedup applied)" {
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-duplicate-drvfs.txt"
	export_compose_env "/home/rai/git/serendipilink"
	# Only ONE env var, set to the first (post-sort) docker-source.
	[ "${DRYDOCK_SUBMOUNT_DOCS_HOST_PATH:-}" = "/mnt/c/Users/Rai/Documents/Obsidian/Vaults/Serendipilink" ]
}

# ── sync_submount_env_file (auto-maintain ${PROJECT_DIR}/.env) ───────────────

@test "sync_submount_env_file: .env absent + no sub-mounts → no file created" {
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-no-submounts.txt"
	local proj="$BATS_TEST_TMPDIR/proj-noenv-nosubs"
	mkdir -p "$proj"
	sync_submount_env_file "$proj"
	[ ! -f "$proj/.env" ]
}

@test "sync_submount_env_file: .env absent + sub-mounts → file created with marker block" {
	local proj="$BATS_TEST_TMPDIR/proj-noenv-subs"
	mkdir -p "$proj"
	# Synthesize a mountinfo fixture pointing the sub-mount at $proj/docs so
	# the project_dir-prefix filter in detect_submounts matches.
	local tmp_mi="$BATS_TEST_TMPDIR/mi-noenv.txt"
	cat >"$tmp_mi" <<MI
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
686 80 0:67 /Users/Rai/Documents/Obsidian/Vaults/Serendipilink $proj/docs rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
MI
	MOUNTINFO_FILE="$tmp_mi" sync_submount_env_file "$proj"
	[ -f "$proj/.env" ]
	grep -qF '# >>> drydock managed' "$proj/.env"
	grep -qF '# <<< end drydock managed' "$proj/.env"
	grep -qF 'DRYDOCK_SUBMOUNT_DOCS_HOST_PATH=/mnt/c/Users/Rai/Documents/Obsidian/Vaults/Serendipilink' "$proj/.env"
}

@test "sync_submount_env_file: .env present + no marker + sub-mounts → marker block appended, user content intact" {
	local proj="$BATS_TEST_TMPDIR/proj-existing-nomarker"
	mkdir -p "$proj"
	cat >"$proj/.env" <<'USER_ENV'
APP_KEY=base64:secret
DB_PASSWORD=hunter2
USER_ENV
	local tmp_mi="$BATS_TEST_TMPDIR/mi-existing.txt"
	cat >"$tmp_mi" <<MI
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
686 80 0:67 /Users/X/Vault $proj/docs rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
MI
	MOUNTINFO_FILE="$tmp_mi" sync_submount_env_file "$proj"
	# User content preserved
	grep -qF 'APP_KEY=base64:secret' "$proj/.env"
	grep -qF 'DB_PASSWORD=hunter2' "$proj/.env"
	# Marker block present
	grep -qF '# >>> drydock managed' "$proj/.env"
	grep -qF 'DRYDOCK_SUBMOUNT_DOCS_HOST_PATH=/mnt/c/Users/X/Vault' "$proj/.env"
	grep -qF '# <<< end drydock managed' "$proj/.env"
}

@test "sync_submount_env_file: marker present + sub-mounts changed → block replaced, user content intact" {
	local proj="$BATS_TEST_TMPDIR/proj-stale-marker"
	mkdir -p "$proj"
	cat >"$proj/.env" <<'OLD_ENV'
APP_KEY=base64:secret

# >>> drydock managed (auto-generated, do not edit manually) <<<
DRYDOCK_SUBMOUNT_OLD_HOST_PATH=/mnt/c/Old
# <<< end drydock managed >>>
OLD_ENV
	local tmp_mi="$BATS_TEST_TMPDIR/mi-replace.txt"
	cat >"$tmp_mi" <<MI
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
686 80 0:67 /Users/X/NewVault $proj/newdir rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
MI
	MOUNTINFO_FILE="$tmp_mi" sync_submount_env_file "$proj"
	# User content preserved
	grep -qF 'APP_KEY=base64:secret' "$proj/.env"
	# Old line gone
	! grep -qF 'DRYDOCK_SUBMOUNT_OLD_HOST_PATH' "$proj/.env"
	# New line present
	grep -qF 'DRYDOCK_SUBMOUNT_NEWDIR_HOST_PATH=/mnt/c/Users/X/NewVault' "$proj/.env"
}

@test "sync_submount_env_file: marker present + no sub-mounts → marker block removed (cleanup)" {
	local proj="$BATS_TEST_TMPDIR/proj-cleanup"
	mkdir -p "$proj"
	cat >"$proj/.env" <<'STALE_ENV'
APP_KEY=base64:secret

# >>> drydock managed (auto-generated, do not edit manually) <<<
DRYDOCK_SUBMOUNT_OLD_HOST_PATH=/mnt/c/Old
# <<< end drydock managed >>>
STALE_ENV
	# Empty mountinfo (no sub-mounts under proj).
	local tmp_mi="$BATS_TEST_TMPDIR/mi-empty.txt"
	cat >"$tmp_mi" <<'MI'
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
MI
	MOUNTINFO_FILE="$tmp_mi" sync_submount_env_file "$proj"
	# User content preserved
	grep -qF 'APP_KEY=base64:secret' "$proj/.env"
	# Marker block fully removed
	! grep -qE '^# >>> drydock managed' "$proj/.env"
	! grep -qF 'DRYDOCK_SUBMOUNT_OLD_HOST_PATH' "$proj/.env"
}

@test "sync_submount_env_file: idempotent — second call leaves same content" {
	local proj="$BATS_TEST_TMPDIR/proj-idempotent"
	mkdir -p "$proj"
	local tmp_mi="$BATS_TEST_TMPDIR/mi-idem.txt"
	cat >"$tmp_mi" <<MI
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
686 80 0:67 /Users/X/V $proj/docs rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
MI
	export MOUNTINFO_FILE="$tmp_mi"
	sync_submount_env_file "$proj"
	local first_content
	first_content=$(cat "$proj/.env")
	sync_submount_env_file "$proj"
	local second_content
	second_content=$(cat "$proj/.env")
	[ "$first_content" = "$second_content" ]
}

@test "sync_submount_env_file: DRYDOCK_SKIP_ENV_WRITE=1 → no-op (file untouched)" {
	local proj="$BATS_TEST_TMPDIR/proj-skip"
	mkdir -p "$proj"
	cat >"$proj/.env" <<'USER_ENV'
APP_KEY=base64:secret
USER_ENV
	local tmp_mi="$BATS_TEST_TMPDIR/mi-skip.txt"
	cat >"$tmp_mi" <<MI
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
686 80 0:67 /Users/X/V $proj/docs rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
MI
	export MOUNTINFO_FILE="$tmp_mi"
	export DRYDOCK_SKIP_ENV_WRITE=1
	sync_submount_env_file "$proj"
	! grep -qF '# >>> drydock managed' "$proj/.env"
	! grep -qF 'DRYDOCK_SUBMOUNT_' "$proj/.env"
	# Original content preserved
	grep -qF 'APP_KEY=base64:secret' "$proj/.env"
	unset DRYDOCK_SKIP_ENV_WRITE
}

# ── sanitize_project_name (REQ-1, S1.1–S1.11) ────────────────────────────────

@test "sanitize_project_name: S1.1 — period mapped to dash" {
	run sanitize_project_name "sideralith.com"
	[ "$status" -eq 0 ]
	[ "$output" = "sideralith-com" ]
}

@test "sanitize_project_name: S1.2 — lowercase + space mapped to dash" {
	run sanitize_project_name "My Project"
	[ "$status" -eq 0 ]
	[ "$output" = "my-project" ]
}

@test "sanitize_project_name: S1.3 — uppercase only lowercased" {
	run sanitize_project_name "Foo"
	[ "$status" -eq 0 ]
	[ "$output" = "foo" ]
}

@test "sanitize_project_name: S1.4 — leading underscore stripped" {
	run sanitize_project_name "_foo"
	[ "$status" -eq 0 ]
	[ "$output" = "foo" ]
}

@test "sanitize_project_name: S1.5 — leading dash stripped" {
	run sanitize_project_name "-foo"
	[ "$status" -eq 0 ]
	[ "$output" = "foo" ]
}

@test "sanitize_project_name: S1.6 — leading digit preserved (alphanumeric)" {
	run sanitize_project_name "2foo"
	[ "$status" -eq 0 ]
	[ "$output" = "2foo" ]
}

@test "sanitize_project_name: S1.7 — all invalid chars → fallback 'project'" {
	run sanitize_project_name "...."
	[ "$status" -eq 0 ]
	[ "$output" = "project" ]
}

@test "sanitize_project_name: S1.8 — already-valid name is idempotent" {
	run sanitize_project_name "drydock"
	[ "$status" -eq 0 ]
	[ "$output" = "drydock" ]
}

@test "sanitize_project_name: S1.9 — dotted run collapsed to single dash" {
	run sanitize_project_name "a...b"
	[ "$status" -eq 0 ]
	[ "$output" = "a-b" ]
}

@test "sanitize_project_name: S1.9b — underscore run preserved (mid-string-valid)" {
	run sanitize_project_name "a___b"
	[ "$status" -eq 0 ]
	[ "$output" = "a___b" ]
}

@test "sanitize_project_name: S1.10 — trailing dash/underscore stripped" {
	run sanitize_project_name "foo-"
	[ "$status" -eq 0 ]
	[ "$output" = "foo" ]
	run sanitize_project_name "foo_"
	[ "$status" -eq 0 ]
	[ "$output" = "foo" ]
}

@test "sanitize_project_name: S1.11 — idempotency (sanitize of sanitized output)" {
	run sanitize_project_name "sideralith.com"
	[ "$status" -eq 0 ]
	local once="$output"
	run sanitize_project_name "$once"
	[ "$status" -eq 0 ]
	[ "$output" = "sideralith-com" ]
}

# ── export_compose_env PROJECT_NAME sanitization integration (REQ-2, S2.1–S2.2) ─

@test "export_compose_env: S2.1 — dotted basename sanitized to PROJECT_NAME=sideralith-com" {
	local dotted_dir="$BATS_TEST_TMPDIR/sideralith.com"
	mkdir -p "$dotted_dir"
	export_compose_env "$dotted_dir"
	[ "$PROJECT_NAME" = "sideralith-com" ]
}

@test "export_compose_env: S2.2 — valid basename unchanged (drydock → drydock)" {
	local valid_dir="$BATS_TEST_TMPDIR/drydock"
	mkdir -p "$valid_dir"
	export_compose_env "$valid_dir"
	[ "$PROJECT_NAME" = "drydock" ]
}

# ── consumer propagation (REQ-3, S3.1–S3.2) ──────────────────────────────────
# S3.3 and S3.4 (cmd_run/cmd_shell DOCKER_CALL_LOG) live in lib_commands.bats
# because those commands are only available after sourcing commands.sh.

@test "export_compose_env: S3.1 — COMPOSE_PROJECT_NAME equals drydock-sideralith-com" {
	# Use a parent dir so basename is exactly "sideralith.com"
	local parent_dir="$BATS_TEST_TMPDIR/s31-parent"
	local dotted_dir="$parent_dir/sideralith.com"
	mkdir -p "$dotted_dir"
	export_compose_env "$dotted_dir"
	[ "$COMPOSE_PROJECT_NAME" = "drydock-sideralith-com" ]
}

@test "export_compose_env: S3.2 — deploy-key path uses sanitized PROJECT_NAME" {
	# Use a parent dir so basename is exactly "sideralith.com"
	local parent_dir="$BATS_TEST_TMPDIR/s32-parent"
	local dotted_dir="$parent_dir/sideralith.com"
	mkdir -p "$dotted_dir"
	HOME="$BATS_TEST_TMPDIR/fakehome-s32"
	mkdir -p "$HOME/.config/drydock/keys"
	# Create only the sanitized key — assert it is found (i.e., the path uses sideralith-com)
	: >"$HOME/.config/drydock/keys/sideralith-com_deploy"
	export_compose_env "$dotted_dir"
	[ "$DRYDOCK_SSH_DEPLOY_KEY" = "$HOME/.config/drydock/keys/sideralith-com_deploy" ]
}

# ── deploy-key migration warning (REQ-11, S11.1–S11.4) ───────────────────────

@test "export_compose_env: S11.1 — old-named key exists → warn names new key filename" {
	local parent_dir="$BATS_TEST_TMPDIR/s11-parent"
	local dotted_dir="$parent_dir/sideralith.com"
	mkdir -p "$dotted_dir"
	HOME="$BATS_TEST_TMPDIR/fakehome-s11"
	mkdir -p "$HOME/.config/drydock/keys"
	# Create the OLD-named key file (raw basename, not sanitized)
	: >"$HOME/.config/drydock/keys/sideralith.com_deploy"
	# Run and capture stderr
	local stderr_out
	stderr_out="$(export_compose_env "$dotted_dir" 2>&1 >/dev/null)"
	[[ "$stderr_out" == *"sideralith-com_deploy"* ]]
}

@test "export_compose_env: S11.2 — dotted basename but NO old key → no warning" {
	local parent_dir="$BATS_TEST_TMPDIR/s112-parent"
	local dotted_dir="$parent_dir/sideralith.com"
	mkdir -p "$dotted_dir"
	HOME="$BATS_TEST_TMPDIR/fakehome-s112"
	mkdir -p "$HOME/.config/drydock/keys"
	# No key file at all
	local stderr_out
	stderr_out="$(export_compose_env "$dotted_dir" 2>&1 >/dev/null)"
	[[ "$stderr_out" != *"rename"* ]]
}

@test "export_compose_env: S11.3 — valid basename (no drift) + old key exists → no warning" {
	local parent_dir="$BATS_TEST_TMPDIR/s113-parent"
	local valid_dir="$parent_dir/drydock"
	mkdir -p "$valid_dir"
	HOME="$BATS_TEST_TMPDIR/fakehome-s113"
	mkdir -p "$HOME/.config/drydock/keys"
	# The basename "drydock" sanitizes to "drydock" — raw == sanitized, condition a fails
	: >"$HOME/.config/drydock/keys/drydock_deploy"
	local stderr_out
	stderr_out="$(export_compose_env "$valid_dir" 2>&1 >/dev/null)"
	[[ "$stderr_out" != *"rename"* ]]
}

@test "export_compose_env: S11.4 — warning is non-fatal, function exits 0" {
	local parent_dir="$BATS_TEST_TMPDIR/s114-parent"
	local dotted_dir="$parent_dir/sideralith.com"
	mkdir -p "$dotted_dir"
	HOME="$BATS_TEST_TMPDIR/fakehome-s114"
	mkdir -p "$HOME/.config/drydock/keys"
	: >"$HOME/.config/drydock/keys/sideralith.com_deploy"
	run export_compose_env "$dotted_dir"
	[ "$status" -eq 0 ]
}

# ── identity markers (issue #8, Slice A) ─────────────────────────────────────
# Use subshell checks for DRYDOCK and DRYDOCK_VERSION because the function must
# export (not just set) them — the test validates the export attribute, not the
# value alone. A plain `[ -n "$DRYDOCK_VERSION" ]` would pass green immediately
# because common.sh sets the var in the current shell before export_compose_env runs.

@test "export_compose_env: A-1 — exports DRYDOCK=1 (visible in child process)" {
	export_compose_env "$TEST_PROJECT_DIR"
	run bash -c 'printf "%s" "${DRYDOCK-UNSET}"'
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

@test "export_compose_env: A-2 — exports DRYDOCK_VERSION (non-empty in child process)" {
	export_compose_env "$TEST_PROJECT_DIR"
	run bash -c 'printf "%s" "${DRYDOCK_VERSION-UNSET}"'
	[ "$status" -eq 0 ]
	[ "$output" != "UNSET" ]
	[ -n "$output" ]
}

@test "export_compose_env: A-3 — exports DRYDOCK_HOME (non-empty in child process)" {
	export_compose_env "$TEST_PROJECT_DIR"
	run bash -c 'printf "%s" "${DRYDOCK_HOME-UNSET}"'
	[ "$status" -eq 0 ]
	[ "$output" != "UNSET" ]
	[ -n "$output" ]
}

# ── gc_orphan_session_dirs (concurrent-sessions, PR 1 Foundation) ─────────────
# Uses a fake HOME (BATS_TEST_TMPDIR/gc-fakehome-*) and a per-test docker stub
# written to BATS_TEST_TMPDIR so docker ps -a output is controllable.
# PROJECT_NAME must be exported by the test (not via export_compose_env).

# Helper: write a docker stub that emits $1 on stdout for any "ps" sub-command.
_make_docker_ps_stub() {
	local stub_file="$BATS_TEST_TMPDIR/docker-ps-stub-$$"
	local ps_output="$1"
	cat >"$stub_file" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "\${DOCKER_CALL_LOG:?}"
if [ "\${1:-}" = "ps" ]; then
	printf '%s\n' '$ps_output'
fi
exit 0
STUB
	chmod +x "$stub_file"
	printf '%s' "$stub_file"
}

@test "gc_orphan_session_dirs: prunes orphan session dir when no container exists" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-orphan"
	mkdir -p "$fake_home"
	# Create an orphan session dir + sibling json
	mkdir -p "$fake_home/.claude-container-dead1"
	touch "$fake_home/.claude-container-dead1.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Docker stub: ps -a returns empty (no matching container)
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ ! -d "$fake_home/.claude-container-dead1" ]
}

@test "gc_orphan_session_dirs: prunes sibling .json alongside orphan dir" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-json"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-dead2"
	touch "$fake_home/.claude-container-dead2.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ ! -f "$fake_home/.claude-container-dead2.json" ]
}

@test "gc_orphan_session_dirs: does NOT prune prototype ~/.claude-container/ (no discriminator suffix)" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-proto"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ -d "$fake_home/.claude-container" ]
}

@test "gc_orphan_session_dirs: does NOT prune dir when run container is live" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-live-run"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-a1b2"
	touch "$fake_home/.claude-container-a1b2.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Docker stub: ps -a shows the run container as live
	local stub
	stub="$(_make_docker_ps_stub "drydock-myproject-a1b2")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ -d "$fake_home/.claude-container-a1b2" ]
}

@test "gc_orphan_session_dirs: does NOT prune dir when shell container is live" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-live-shell"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-c3d4"
	touch "$fake_home/.claude-container-c3d4.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Docker stub: ps -a shows the shell container as live
	local stub
	stub="$(_make_docker_ps_stub "drydock-myproject-c3d4-shell")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ -d "$fake_home/.claude-container-c3d4" ]
}

@test "gc_orphan_session_dirs: is idempotent — second call on clean state is a no-op" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-idempotent"
	mkdir -p "$fake_home"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	# First call on empty HOME — no dirs to prune
	gc_orphan_session_dirs
	# Second call — still no error
	gc_orphan_session_dirs
	# No .claude-container-* dirs appeared
	local count
	count=0
	for d in "$fake_home"/.claude-container-?*/; do
		[ -d "$d" ] && count=$((count + 1))
	done
	[ "$count" -eq 0 ]
}

# ── seed_session_config_dir (concurrent-sessions, PR 1 Foundation) ────────────
# Uses a fake HOME with a pre-populated prototype ~/.claude-container/ and
# ~/.claude-container.json. Per-test docker stubs control liveness checks.

# Helper: populate prototype dirs in a fake HOME
_make_prototype() {
	local fake_home="$1"
	mkdir -p "$fake_home/.claude-container/skills"
	printf 'proto-settings' >"$fake_home/.claude-container/settings.json"
	printf 'proto-marker' >"$fake_home/.claude-container/.drydock-last-sync"
	printf 'proto-json' >"$fake_home/.claude-container.json"
}

@test "seed_session_config_dir: fresh seed creates session dir from prototype" {
	local fake_home="$BATS_TEST_TMPDIR/seed-home-fresh"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	seed_session_config_dir "abcd"
	[ -d "$fake_home/.claude-container-abcd" ]
}

@test "seed_session_config_dir: fresh seed copies prototype .json sibling" {
	local fake_home="$BATS_TEST_TMPDIR/seed-home-json"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	seed_session_config_dir "abcd"
	[ -f "$fake_home/.claude-container-abcd.json" ]
}

@test "seed_session_config_dir: session dir contains prototype files" {
	local fake_home="$BATS_TEST_TMPDIR/seed-home-content"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	seed_session_config_dir "ef01"
	[ -f "$fake_home/.claude-container-ef01/settings.json" ]
	content="$(cat "$fake_home/.claude-container-ef01/settings.json")"
	[ "$content" = "proto-settings" ]
}

@test "seed_session_config_dir: .drydock-last-sync marker NOT copied into session dir" {
	local fake_home="$BATS_TEST_TMPDIR/seed-home-nosync"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	seed_session_config_dir "2345"
	[ ! -f "$fake_home/.claude-container-2345/.drydock-last-sync" ]
}

@test "seed_session_config_dir: re-seed safety — safe to call when no live container" {
	local fake_home="$BATS_TEST_TMPDIR/seed-home-reseed"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	# Pre-create session dir with stale content
	mkdir -p "$fake_home/.claude-container-6789"
	printf 'stale' >"$fake_home/.claude-container-6789/old.txt"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	seed_session_config_dir "6789"
	# Stale file gone, prototype content present
	[ ! -f "$fake_home/.claude-container-6789/old.txt" ]
	[ -f "$fake_home/.claude-container-6789/settings.json" ]
}

@test "seed_session_config_dir: live-container guard — does NOT reseed when run container is live" {
	local fake_home="$BATS_TEST_TMPDIR/seed-home-live-run"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	# Pre-create session dir with sentinel content
	mkdir -p "$fake_home/.claude-container-cafe"
	printf 'live-content' >"$fake_home/.claude-container-cafe/live.txt"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Docker stub: run container is live
	local stub
	stub="$(_make_docker_ps_stub "drydock-myproject-cafe")"
	export DOCKER="$stub"
	seed_session_config_dir "cafe"
	# Should NOT have wiped the live dir
	[ -f "$fake_home/.claude-container-cafe/live.txt" ]
}

@test "seed_session_config_dir: live-container guard — does NOT reseed when shell container is live" {
	local fake_home="$BATS_TEST_TMPDIR/seed-home-live-shell"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	mkdir -p "$fake_home/.claude-container-babe"
	printf 'shell-content' >"$fake_home/.claude-container-babe/shell.txt"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Docker stub: shell container is live
	local stub
	stub="$(_make_docker_ps_stub "drydock-myproject-babe-shell")"
	export DOCKER="$stub"
	seed_session_config_dir "babe"
	[ -f "$fake_home/.claude-container-babe/shell.txt" ]
}

# ── Cross-project GC/seed hazard fix (concurrent-sessions, PR 2) ─────────────
# A foreign-project live container (drydock-otherproject-<disc>) MUST protect
# ~/.claude-container-<disc>/ from being pruned or re-seeded by the current
# project's GC / seed passes. The liveness check must be project-agnostic:
# match <disc> against ANY drydock-*-<disc> name in docker ps -a output.

@test "gc_orphan_session_dirs: foreign-project live run container protects the disc dir" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-foreign-run"
	mkdir -p "$fake_home"
	# Session dir for disc "f00d" — belongs to projectA, but we run as projectB.
	mkdir -p "$fake_home/.claude-container-f00d"
	touch "$fake_home/.claude-container-f00d.json"
	HOME="$fake_home"
	export PROJECT_NAME="projectb"
	# Docker stub: drydock-projecta-f00d is live (different project, same disc).
	local stub
	stub="$(_make_docker_ps_stub "drydock-projecta-f00d")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ -d "$fake_home/.claude-container-f00d" ]
}

@test "gc_orphan_session_dirs: foreign-project live shell container protects the disc dir" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-foreign-shell"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-beef"
	touch "$fake_home/.claude-container-beef.json"
	HOME="$fake_home"
	export PROJECT_NAME="projectb"
	# Docker stub: drydock-projecta-beef-shell is live (different project, same disc).
	local stub
	stub="$(_make_docker_ps_stub "drydock-projecta-beef-shell")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ -d "$fake_home/.claude-container-beef" ]
}

@test "seed_session_config_dir: foreign-project live run container prevents re-seed" {
	local fake_home="$BATS_TEST_TMPDIR/seed-home-foreign-run"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	mkdir -p "$fake_home/.claude-container-d00d"
	printf 'foreign-content' >"$fake_home/.claude-container-d00d/live.txt"
	HOME="$fake_home"
	export PROJECT_NAME="projectb"
	# Docker stub: drydock-projecta-d00d is live (different project, same disc).
	local stub
	stub="$(_make_docker_ps_stub "drydock-projecta-d00d")"
	export DOCKER="$stub"
	seed_session_config_dir "d00d"
	# Dir must NOT have been wiped — foreign-project's live content intact.
	[ -f "$fake_home/.claude-container-d00d/live.txt" ]
}

@test "seed_session_config_dir: foreign-project live shell container prevents re-seed" {
	local fake_home="$BATS_TEST_TMPDIR/seed-home-foreign-shell"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	mkdir -p "$fake_home/.claude-container-b00b"
	printf 'foreign-shell-content' >"$fake_home/.claude-container-b00b/live.txt"
	HOME="$fake_home"
	export PROJECT_NAME="projectb"
	# Docker stub: drydock-projecta-b00b-shell is live (different project, same disc).
	local stub
	stub="$(_make_docker_ps_stub "drydock-projecta-b00b-shell")"
	export DOCKER="$stub"
	seed_session_config_dir "b00b"
	[ -f "$fake_home/.claude-container-b00b/live.txt" ]
}
