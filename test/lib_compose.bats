#!/usr/bin/env bats
# test/lib_compose.bats — unit tests for lib/compose.sh
#
# Sources lib/common.sh + lib/paths.sh + lib/compose.sh directly (not
# bin/drydock). Tests compose_files(), export_compose_env(), image_exists(), and
# _ensure_docker_responsive() via the DOCKER seam. Does NOT test
# ensure_runtime_dirs / ensure_image — those reach into cmd_setup/cmd_build from
# lib/commands.sh.

load "helpers/load"

setup() {
	# Source order mirrors bin/drydock: common → paths → compose → sibling_ssh.
	# Stub cmd_setup so ensure_runtime_dirs is safe if anything edges toward it.
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/sibling_ssh.sh"

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

	# Default DOCKER stub: returns empty for "ps" sub-commands so export_compose_env
	# GC/collision-check/seed calls are safe for tests that don't stub DOCKER.
	local _default_docker_stub="$BATS_TEST_TMPDIR/default-docker-stub-$$"
	cat >"$_default_docker_stub" <<'STUB'
#!/usr/bin/env bash
printf '' >> "${DOCKER_CALL_LOG:-/dev/null}"
if [ "${1:-}" = "ps" ]; then printf ''; fi
exit 0
STUB
	chmod +x "$_default_docker_stub"
	export DOCKER="$_default_docker_stub"

	# Default discriminator stub: emit "dflt" so export_compose_env tests that
	# don't care about the disc value get a stable, predictable result.
	_default_disc() { printf 'dflt'; }
	export DRYDOCK_DISCRIMINATOR_FN=_default_disc

	# Default fake HOME with prototype dirs for export_compose_env calls.
	# Tests that need a specific HOME override it inline.
	local _default_home="$BATS_TEST_TMPDIR/default-home-$$"
	mkdir -p "$_default_home/.claude-container"
	touch "$_default_home/.claude-container.json"
	export HOME="$_default_home"
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
	generate_submount_overlay "/home/you/projects/myproject"
	[ -f "$SUBMOUNT_OVERLAY" ]
	grep -q '^services:' "$SUBMOUNT_OVERLAY"
	grep -q '^  drydock:' "$SUBMOUNT_OVERLAY"
	grep -q '^    volumes:' "$SUBMOUNT_OVERLAY"
	grep -q '/mnt/c/Users/You/Documents/Obsidian/Vaults/MyProject:/home/you/projects/myproject/docs:rw' "$SUBMOUNT_OVERLAY"
	# The overlay must also declare an environment: block with KEY-only entries
	# so docker compose inherits the DRYDOCK_SUBMOUNT_*_HOST_PATH vars from the
	# CLI shell into the container drydock (DooD passthrough).
	grep -q '^    environment:' "$SUBMOUNT_OVERLAY"
	grep -q '^      - DRYDOCK_SUBMOUNT_DOCS_HOST_PATH$' "$SUBMOUNT_OVERLAY"
}

@test "generate_submount_overlay: nested sub-mounts → distinct environment entries" {
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-nested.txt"
	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/submount-nested.yml"
	generate_submount_overlay "/home/you/projects/proj"
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

@test "export_compose_env sets COMPOSE_PROJECT_NAME with drydock- prefix and discriminator" {
	_fixed_disc() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc
	export DOCKER="$(_make_docker_ps_stub "")"
	export HOME="$BATS_TEST_TMPDIR/ecpn-home-$$"
	mkdir -p "$HOME/.claude-container"
	touch "$HOME/.claude-container.json"
	export_compose_env "$TEST_PROJECT_DIR"
	[[ "$COMPOSE_PROJECT_NAME" == "drydock-myproject-test" ]]
}

@test "export_compose_env sets USER_NAME to id -un" {
	export_compose_env "$TEST_PROJECT_DIR"
	[ -n "$USER_NAME" ]
	[ "$USER_NAME" = "$(id -un)" ]
}

# ── optional git-credential overlays (ssh deploy key + sandbox gpg) ──────────

@test "compose_files: no DRYDOCK_SSH_CONFIG — ssh overlay absent" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" != *"docker-compose.ssh.yml"* ]]
}

@test "compose_files: DRYDOCK_SSH_CONFIG set — ssh overlay present" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export DRYDOCK_SSH_CONFIG="$BATS_TEST_TMPDIR/fake_ssh_config"
	touch "$BATS_TEST_TMPDIR/fake_ssh_config"
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
	HOME="$BATS_TEST_TMPDIR/fakehome-dk-$$"
	mkdir -p "$HOME/.config/drydock/keys"
	mkdir -p "$HOME/.claude-container"
	touch "$HOME/.claude-container.json"
	: >"$HOME/.config/drydock/keys/myproject_deploy"
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

@test "export_compose_env: signing dir with a key — sets DRYDOCK_GPG_SIGNINGKEY" {
	command -v gpg >/dev/null 2>&1 || skip "gpg not installed"
	HOME="$BATS_TEST_TMPDIR/fakehome-gpg-$$"
	mkdir -p "$HOME/.claude-container"
	touch "$HOME/.claude-container.json"
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

# ── OAuth token overlay (compose gate) ───────────────────────────────────────

@test "compose_files: DRYDOCK_OAUTH_TOKEN_VALUE unset — oauth overlay absent" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	unset DRYDOCK_OAUTH_TOKEN_VALUE
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" != *"docker-compose.oauth.yml"* ]]
}

@test "compose_files: DRYDOCK_OAUTH_TOKEN_VALUE set — oauth overlay present" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export DRYDOCK_OAUTH_TOKEN_VALUE="sk-ant-oat-v1-testtoken1234567890123456789012345678"
	run compose_files "$TEST_PROJECT_DIR"
	[[ "$output" == *"docker-compose.oauth.yml"* ]]
	unset DRYDOCK_OAUTH_TOKEN_VALUE
}

# ── export_compose_env OAuth token block ──────────────────────────────────────

@test "export_compose_env: token file present with valid content — DRYDOCK_OAUTH_TOKEN_VALUE exported" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-oauth-present-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	mkdir -p "$fakehome/.config/drydock"
	printf 'sk-ant-oat-v1-testtoken1234567890123456789012345678' >"$fakehome/.config/drydock/claude-oauth-token"
	export HOME="$fakehome"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	unset DRYDOCK_OAUTH_TOKEN_VALUE
	export_compose_env "$TEST_PROJECT_DIR"
	[ -n "${DRYDOCK_OAUTH_TOKEN_VALUE:-}" ]
	[ "$DRYDOCK_OAUTH_TOKEN_VALUE" = "sk-ant-oat-v1-testtoken1234567890123456789012345678" ]
}

@test "export_compose_env: token file with trailing newline — exported value is trimmed" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-oauth-newline-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	mkdir -p "$fakehome/.config/drydock"
	printf 'sk-ant-oat-v1-testtoken1234567890123456789012345678\n' >"$fakehome/.config/drydock/claude-oauth-token"
	export HOME="$fakehome"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	unset DRYDOCK_OAUTH_TOKEN_VALUE
	export_compose_env "$TEST_PROJECT_DIR"
	[ "$DRYDOCK_OAUTH_TOKEN_VALUE" = "sk-ant-oat-v1-testtoken1234567890123456789012345678" ]
}

@test "export_compose_env: multi-line token file — only first line exported, second line not concatenated (Fix6)" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-oauth-multiline-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	mkdir -p "$fakehome/.config/drydock"
	# Two-line file: first line is the real token; second is junk that must NOT appear.
	printf 'sk-ant-oat-v1-testtoken1234567890123456789012345678\nsecond-line-should-be-ignored\n' \
		>"$fakehome/.config/drydock/claude-oauth-token"
	export HOME="$fakehome"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	unset DRYDOCK_OAUTH_TOKEN_VALUE
	export_compose_env "$TEST_PROJECT_DIR"
	[ -n "${DRYDOCK_OAUTH_TOKEN_VALUE:-}" ]
	[ "$DRYDOCK_OAUTH_TOKEN_VALUE" = "sk-ant-oat-v1-testtoken1234567890123456789012345678" ]
}

@test "export_compose_env: token file absent — DRYDOCK_OAUTH_TOKEN_VALUE unset" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-oauth-absent-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	mkdir -p "$fakehome/.config/drydock"
	# Explicitly no token file
	export HOME="$fakehome"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	unset DRYDOCK_OAUTH_TOKEN_VALUE
	export_compose_env "$TEST_PROJECT_DIR"
	[ -z "${DRYDOCK_OAUTH_TOKEN_VALUE:-}" ]
}

@test "export_compose_env: token file present but empty — DRYDOCK_OAUTH_TOKEN_VALUE not exported" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-oauth-empty-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	mkdir -p "$fakehome/.config/drydock"
	printf '' >"$fakehome/.config/drydock/claude-oauth-token"
	export HOME="$fakehome"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	unset DRYDOCK_OAUTH_TOKEN_VALUE
	export_compose_env "$TEST_PROJECT_DIR"
	[ -z "${DRYDOCK_OAUTH_TOKEN_VALUE:-}" ]
}

@test "export_compose_env: token file absent but DRYDOCK_OAUTH_TOKEN_VALUE pre-set stale — unset after call (Fix6 idempotency)" {
	# Regression: export_compose_env must unset DRYDOCK_OAUTH_TOKEN_VALUE at the
	# top of its OAuth block so re-invocations re-derive state from the file.
	# A stale var from a previous call (e.g. after revoke-token) must NOT survive.
	local fakehome="$BATS_TEST_TMPDIR/fakehome-oauth-stale-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	mkdir -p "$fakehome/.config/drydock"
	# No token file — but a stale env var from a prior invocation.
	export HOME="$fakehome"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	export DRYDOCK_OAUTH_TOKEN_VALUE="stale-token-from-previous-session"
	export_compose_env "$TEST_PROJECT_DIR"
	[ -z "${DRYDOCK_OAUTH_TOKEN_VALUE:-}" ]
}

@test "export_compose_env: token file contains only a newline — DRYDOCK_OAUTH_TOKEN_VALUE not exported (Fix7 whitespace-only)" {
	# Regression guard: a file containing only a newline is whitespace-only after
	# head -1 | tr -d '[:space:]' — must behave the same as empty (no export).
	local fakehome="$BATS_TEST_TMPDIR/fakehome-oauth-newline-only-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	mkdir -p "$fakehome/.config/drydock"
	printf '\n' >"$fakehome/.config/drydock/claude-oauth-token"
	export HOME="$fakehome"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	unset DRYDOCK_OAUTH_TOKEN_VALUE
	export_compose_env "$TEST_PROJECT_DIR"
	[ -z "${DRYDOCK_OAUTH_TOKEN_VALUE:-}" ]
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

# ── _ensure_docker_responsive (daemon fail-fast) ──────────────────────────────

@test "_ensure_docker_responsive: daemon replies (mock exit 0) — returns 0" {
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export MOCK_DOCKER_EXIT=0
	run _ensure_docker_responsive
	[ "$status" -eq 0 ]
}

@test "_ensure_docker_responsive: daemon errors (mock exit 1) — errs, names not-responding" {
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export MOCK_DOCKER_EXIT=1
	run _ensure_docker_responsive
	[ "$status" -ne 0 ]
	[[ "$output" == *"not responding"* ]]
}

@test "_ensure_docker_responsive: guidance is backend-agnostic (Docker Desktop AND Docker Engine)" {
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export MOCK_DOCKER_EXIT=1
	run _ensure_docker_responsive
	[ "$status" -ne 0 ]
	[[ "$output" == *"Docker Desktop"* ]]
	[[ "$output" == *"Docker Engine"* ]]
}

@test "_ensure_docker_responsive: a hanging daemon is bounded by the probe timeout" {
	# A stub that never returns; the timeout must kill it and the function must err.
	local stub="$BATS_TEST_TMPDIR/docker-hang"
	printf '#!/bin/sh\nsleep 5\n' >"$stub"
	chmod +x "$stub"
	export DOCKER="$stub"
	export DRYDOCK_DOCKER_PROBE_TIMEOUT=1
	run _ensure_docker_responsive
	[ "$status" -ne 0 ]
	[[ "$output" == *"not responding"* ]]
}

# ── DRYDOCK_SUBMOUNT_*_HOST_PATH passthrough (DooD gap) ──────────────────────

@test "export_compose_env: drvfs sub-mount → DRYDOCK_SUBMOUNT_<NAME>_HOST_PATH exported" {
	# Use the drvfs-c fixture (mount_point = /home/you/projects/myproject/docs).
	# project_dir basename is "myproject", sub-mount relpath is "docs" → DOCS.
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-drvfs-c.txt"
	# Use the fixture's project root path so the prefix filter matches.
	mkdir -p "$BATS_TEST_TMPDIR/myproject"
	export_compose_env "/home/you/projects/myproject"
	[ "${DRYDOCK_SUBMOUNT_DOCS_HOST_PATH:-}" = "/mnt/c/Users/You/Documents/Obsidian/Vaults/MyProject" ]
}

@test "export_compose_env: nested sub-mount → distinct env var with relpath name" {
	# Use the nested fixture (mount points docs/ and docs/sub).
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-nested.txt"
	mkdir -p "$BATS_TEST_TMPDIR/proj"
	export_compose_env "/home/you/projects/proj"
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
	export_compose_env "/home/you/projects/myproject"
	# Only ONE env var, set to the first (post-sort) docker-source.
	[ "${DRYDOCK_SUBMOUNT_DOCS_HOST_PATH:-}" = "/mnt/c/Users/You/Documents/Obsidian/Vaults/MyProject" ]
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
686 80 0:67 /Users/You/Documents/Obsidian/Vaults/MyProject $proj/docs rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
MI
	MOUNTINFO_FILE="$tmp_mi" sync_submount_env_file "$proj"
	[ -f "$proj/.env" ]
	grep -qF '# >>> drydock managed' "$proj/.env"
	grep -qF '# <<< end drydock managed' "$proj/.env"
	grep -qF 'DRYDOCK_SUBMOUNT_DOCS_HOST_PATH=/mnt/c/Users/You/Documents/Obsidian/Vaults/MyProject' "$proj/.env"
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

# ── close-marker isolation + idempotency (#140) ──────────────────────────────
# Regression for #140: the managed-block serializer emitted $block with no
# trailing newline, gluing "# <<< end drydock managed >>>" onto the last
# DRYDOCK_SUBMOUNT_*_HOST_PATH value (Docker then bind-mounts a nonexistent
# path it silently creates as an empty dir). These assert the RAW .env, NOT a
# round-trip through the extraction awk — whose /^# <<< end/ anchor is blind to
# the glued marker and would hide the bug (the green-false trap that shipped it).

@test "sync_submount_env_file: close marker on its own line, never glued to last value (#140, 1 sub-mount)" {
	local proj="$BATS_TEST_TMPDIR/proj-marker-glue-1"
	mkdir -p "$proj"
	local tmp_mi="$BATS_TEST_TMPDIR/mi-glue-1.txt"
	cat >"$tmp_mi" <<MI
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
686 80 0:67 /Users/X/Vault $proj/docs rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
MI
	MOUNTINFO_FILE="$tmp_mi" sync_submount_env_file "$proj"
	# Guard against a false RED: the managed block must actually be written.
	grep -qE '^DRYDOCK_SUBMOUNT_DOCS_HOST_PATH=' "$proj/.env"
	# (1) The close marker MUST occupy its own line.
	grep -qxF '# <<< end drydock managed >>>' "$proj/.env"
	# (2) The close marker MUST NOT be concatenated onto a KEY=VALUE line (#140).
	run grep -qE '=.*# <<< end drydock managed' "$proj/.env"
	[ "$status" -ne 0 ]
}

@test "sync_submount_env_file: close marker on its own line with multiple sub-mounts (#140)" {
	local proj="$BATS_TEST_TMPDIR/proj-marker-glue-multi"
	mkdir -p "$proj"
	local tmp_mi="$BATS_TEST_TMPDIR/mi-glue-multi.txt"
	cat >"$tmp_mi" <<MI
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
686 80 0:67 /Users/X/Vault $proj/docs rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
687 80 0:68 /Users/X/Media $proj/assets rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
MI
	MOUNTINFO_FILE="$tmp_mi" sync_submount_env_file "$proj"
	# Both sub-mounts present → managed block has ≥2 value lines (the bug glues
	# the marker onto the last one); assert the close marker stays isolated.
	grep -qE '^DRYDOCK_SUBMOUNT_DOCS_HOST_PATH=' "$proj/.env"
	grep -qE '^DRYDOCK_SUBMOUNT_ASSETS_HOST_PATH=' "$proj/.env"
	grep -qxF '# <<< end drydock managed >>>' "$proj/.env"
	run grep -qE '=.*# <<< end drydock managed' "$proj/.env"
	[ "$status" -ne 0 ]
}

@test "sync_submount_env_file: second call does not rewrite the file — glued-marker idempotency (#140)" {
	local proj="$BATS_TEST_TMPDIR/proj-marker-noop"
	mkdir -p "$proj"
	local tmp_mi="$BATS_TEST_TMPDIR/mi-glue-noop.txt"
	cat >"$tmp_mi" <<MI
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
686 80 0:67 /Users/X/Vault $proj/docs rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
MI
	export MOUNTINFO_FILE="$tmp_mi"
	sync_submount_env_file "$proj"
	grep -qE '^DRYDOCK_SUBMOUNT_DOCS_HOST_PATH=' "$proj/.env"
	local inode_before
	inode_before=$(stat -c %i "$proj/.env")
	# A glued close marker defeats the idempotency check (existing_block carries
	# the marker → never equals the rebuilt block), so the file is rewritten
	# (mktemp + mv → new inode) on every run. Fixed: the second call is a no-op.
	sync_submount_env_file "$proj"
	local inode_after
	inode_after=$(stat -c %i "$proj/.env")
	[ "$inode_before" = "$inode_after" ]
}

@test "sync_submount_env_file: heals a pre-existing glued-marker .env (#140 upgrade path)" {
	local proj="$BATS_TEST_TMPDIR/proj-marker-heal"
	mkdir -p "$proj"
	# Simulate an .env already corrupted by the pre-fix serializer: the close
	# marker glued onto the (otherwise correct) last value. The seed value MUST
	# match the detected sub-mount so this exercises the no-skip idempotency path
	# (only the glued marker differs), not a trivial value-diff rewrite.
	cat >"$proj/.env" <<'GLUED'
# >>> drydock managed (auto-generated, do not edit manually) <<<
DRYDOCK_SUBMOUNT_DOCS_HOST_PATH=/mnt/c/Users/X/Vault# <<< end drydock managed >>>
GLUED
	local tmp_mi="$BATS_TEST_TMPDIR/mi-heal.txt"
	cat >"$tmp_mi" <<MI
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
686 80 0:67 /Users/X/Vault $proj/docs rw,noatime - 9p drvfs rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/
MI
	MOUNTINFO_FILE="$tmp_mi" sync_submount_env_file "$proj"
	# The var survives and the close marker is repaired onto its own line.
	grep -qE '^DRYDOCK_SUBMOUNT_DOCS_HOST_PATH=' "$proj/.env"
	grep -qxF '# <<< end drydock managed >>>' "$proj/.env"
	run grep -qE '=.*# <<< end drydock managed' "$proj/.env"
	[ "$status" -ne 0 ]
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

@test "export_compose_env: S3.1 — COMPOSE_PROJECT_NAME equals drydock-sideralith-com-<disc>" {
	# Use a parent dir so basename is exactly "sideralith.com"
	local parent_dir="$BATS_TEST_TMPDIR/s31-parent"
	local dotted_dir="$parent_dir/sideralith.com"
	mkdir -p "$dotted_dir"
	_fixed_disc() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc
	export DOCKER="$(_make_docker_ps_stub "")"
	export HOME="$BATS_TEST_TMPDIR/s31-home-$$"
	mkdir -p "$HOME/.claude-container"
	touch "$HOME/.claude-container.json"
	export_compose_env "$dotted_dir"
	[[ "$COMPOSE_PROJECT_NAME" == "drydock-sideralith-com-test" ]]
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
	# Create an orphan session dir + sibling json (4-char hex disc matches generator shape)
	mkdir -p "$fake_home/.claude-container-d1d1"
	touch "$fake_home/.claude-container-d1d1.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Docker stub: ps -a returns empty (no matching container)
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ ! -d "$fake_home/.claude-container-d1d1" ]
}

@test "gc_orphan_session_dirs: prunes sibling .json alongside orphan dir" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-json"
	mkdir -p "$fake_home"
	# 4-char hex disc so it passes the generator-shape validation guard.
	mkdir -p "$fake_home/.claude-container-d2d2"
	touch "$fake_home/.claude-container-d2d2.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ ! -f "$fake_home/.claude-container-d2d2.json" ]
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

# ── concurrent-launch race hardening ──────────────────────────────────────────
# GRACE: a dir with a FRESH .launching marker is protected from gc reap even
# when no matching container exists in docker ps -a.
# SENTINEL: seed_session_config_dir creates .launching in the new session dir.
# DIR-CHECK: collision loop treats a dir with .launching as "disc taken".

@test "gc_orphan_session_dirs: GRACE protect — fresh .launching marker shields orphan dir from reap" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-grace-protect-$$"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-aaaa"
	touch "$fake_home/.claude-container-aaaa.json"
	# Create a FRESH .launching marker (mtime = now — well within grace window).
	: >"$fake_home/.claude-container-aaaa/.launching"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Docker stub: ps -a returns empty (no matching container exists yet).
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	# Dir must NOT have been removed — fresh marker protects it.
	[ -d "$fake_home/.claude-container-aaaa" ]
}

@test "gc_orphan_session_dirs: GRACE reap-stale — expired .launching marker → dir IS reaped" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-grace-stale-$$"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-bbbb"
	touch "$fake_home/.claude-container-bbbb.json"
	# Create a .launching marker aged well past the grace window (>300 s).
	local marker="$fake_home/.claude-container-bbbb/.launching"
	: >"$marker"
	touch -d "@$(( $(date +%s) - 1000 ))" "$marker"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	# Stale marker should not protect the dir — it must be removed.
	[ ! -d "$fake_home/.claude-container-bbbb" ]
}

@test "gc_orphan_session_dirs: GRACE compat — no .launching marker preserves existing orphan semantics" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-grace-compat-$$"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-cccc"
	touch "$fake_home/.claude-container-cccc.json"
	# Deliberately NO .launching marker.
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	# No marker → existing orphan semantics: dir is removed.
	[ ! -d "$fake_home/.claude-container-cccc" ]
}

# ── gc daemon-failure guard (audit F1) ────────────────────────────────────────
# When `docker ps -a` itself FAILS (daemon unreachable), empty output is
# indistinguishable from "no containers": every live session dir would look
# orphaned and gc would rm -rf the bind-mounted ~/.claude of running sessions.
# gc must detect the failure and SKIP the entire pass.

@test "gc_orphan_session_dirs: docker ps failure — gc SKIPPED, orphan-looking dir survives" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-daemon-down-$$"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-abcd"
	touch "$fake_home/.claude-container-abcd.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Docker stub: exits non-zero with no output — daemon unreachable.
	local stub="$BATS_TEST_TMPDIR/docker-fail-stub-$$"
	printf '#!/usr/bin/env bash\nexit 1\n' >"$stub"
	chmod +x "$stub"
	export DOCKER="$stub"
	run gc_orphan_session_dirs
	[ "$status" -eq 0 ]
	[[ "$output" == *"skipping"* ]]
	# Dir + json must SURVIVE — empty-because-failed must not be read as orphan.
	[ -d "$fake_home/.claude-container-abcd" ]
	[ -f "$fake_home/.claude-container-abcd.json" ]
}

@test "gc_orphan_session_dirs: docker ps success with EMPTY output — orphan still reaped" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-empty-ok-$$"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-abce"
	touch "$fake_home/.claude-container-abce.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Docker stub: exits 0, prints nothing — genuinely no containers.
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ ! -d "$fake_home/.claude-container-abce" ]
	[ ! -f "$fake_home/.claude-container-abce.json" ]
}

# ── gc "Returns 0 always" contract (audit F2) ─────────────────────────────────
# One unremovable entry (e.g. a root-owned file) must not abort gc — and
# therefore every `drydock run` — under set -e. gc warns and continues.

@test "gc_orphan_session_dirs: unremovable orphan dir — gc warns, returns 0, continues to next dir" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-unremovable-$$"
	mkdir -p "$fake_home"
	# Orphan dir aaaa holds a file inside a write-protected subdir → rm -rf fails.
	mkdir -p "$fake_home/.claude-container-aaaa/locked"
	touch "$fake_home/.claude-container-aaaa/locked/keep"
	chmod 555 "$fake_home/.claude-container-aaaa/locked"
	touch "$fake_home/.claude-container-aaaa.json"
	# Orphan dir bbbb is plainly removable — proves the loop continues past aaaa.
	mkdir -p "$fake_home/.claude-container-bbbb"
	touch "$fake_home/.claude-container-bbbb.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	run gc_orphan_session_dirs
	# Restore perms FIRST so BATS_TEST_TMPDIR cleanup works even on assert failure.
	chmod -R u+w "$fake_home/.claude-container-aaaa" 2>/dev/null || true
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not remove"* ]]
	# The removable orphan after the stuck one must still have been reaped.
	[ ! -d "$fake_home/.claude-container-bbbb" ]
	[ ! -f "$fake_home/.claude-container-bbbb.json" ]
}

@test "seed_session_config_dir: SENTINEL — creates .launching marker in new session dir" {
	local fake_home="$BATS_TEST_TMPDIR/seed-home-sentinel-$$"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	seed_session_config_dir "dddd"
	# .launching must exist immediately after seed.
	[ -f "$fake_home/.claude-container-dddd/.launching" ]
}

@test "export_compose_env: DIR-CHECK — disc with existing session dir treated as taken; uses next free disc" {
	local fake_home="$BATS_TEST_TMPDIR/wire-home-dircheck-$$"
	_setup_wiring_home "$fake_home"
	export HOME="$fake_home"
	# Pre-create the session dir for disc "eeee" WITH a fresh .launching marker so
	# the GRACE check protects it through the gc pass (gc runs first in export_compose_env).
	mkdir -p "$fake_home/.claude-container-eeee"
	: >"$fake_home/.claude-container-eeee/.launching"
	# Discriminator fn: first call returns "eeee" (dir exists → taken), second "ffff" (free).
	local call_count_file="$BATS_TEST_TMPDIR/disc-dircheck-count-$$"
	printf '0' >"$call_count_file"
	_seq_disc_dircheck() {
		local n
		n="$(cat "$call_count_file")"
		printf '%s' "$((n + 1))" >"$call_count_file"
		case "$n" in
			0) printf 'eeee' ;;
			*) printf 'ffff' ;;
		esac
	}
	export DRYDOCK_DISCRIMINATOR_FN=_seq_disc_dircheck
	# Docker stub: always empty (no running containers — dir-existence is the only "taken" signal).
	# gc pre-check (call 0): "" — no orphans (eeee has fresh marker, protected).
	# collision check "eeee" (call 1): "" — no container, BUT dir exists → taken by DIR-CHECK.
	# collision check "ffff" (call 2): "" — no container, no dir → free, break.
	local counter_file="$BATS_TEST_TMPDIR/docker-ps-counter-dircheck-$$"
	printf '0' >"$counter_file"
	local stub
	stub="$(_make_docker_ps_seq_stub "$counter_file" "" "" "")"
	export DOCKER="$stub"
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls-dircheck-$$.log"
	touch "$DOCKER_CALL_LOG"
	export_compose_env "$TEST_PROJECT_DIR"
	# Must have treated "eeee" as taken — final disc must be "ffff".
	[[ "$COMPOSE_PROJECT_NAME" == "drydock-myproject-ffff" ]]
}

# ── harvest_session_projects (issue #68 — conversation-history data loss) ─────
# The per-session ~/.claude-container-<disc>/ dir conflates ephemeral config
# with durable conversation history under projects/. Before the GC rm -rf's an
# orphan dir, that history must be unioned into the prototype so new sessions —
# seeded from the prototype — inherit it and `claude --resume` keeps working.

@test "harvest_session_projects: unions session projects/ into prototype" {
	local fake_home="$BATS_TEST_TMPDIR/harvest-union"
	mkdir -p "$fake_home/.claude-container/projects"
	mkdir -p "$fake_home/.claude-container-aa11/projects/-home-user-proj"
	echo '{"msg":"hi"}' >"$fake_home/.claude-container-aa11/projects/-home-user-proj/uuid-1.jsonl"
	HOME="$fake_home"
	harvest_session_projects "$fake_home/.claude-container-aa11"
	[ -f "$fake_home/.claude-container/projects/-home-user-proj/uuid-1.jsonl" ]
}

@test "harvest_session_projects: no-op when session dir has no projects/" {
	local fake_home="$BATS_TEST_TMPDIR/harvest-noprojects"
	mkdir -p "$fake_home/.claude-container/projects"
	mkdir -p "$fake_home/.claude-container-bb22"
	HOME="$fake_home"
	run harvest_session_projects "$fake_home/.claude-container-bb22"
	[ "$status" -eq 0 ]
}

@test "harvest_session_projects: no-op when prototype ~/.claude-container/ absent" {
	local fake_home="$BATS_TEST_TMPDIR/harvest-noproto"
	mkdir -p "$fake_home/.claude-container-cc33/projects/-home-user-proj"
	echo '{}' >"$fake_home/.claude-container-cc33/projects/-home-user-proj/uuid-1.jsonl"
	HOME="$fake_home"
	run harvest_session_projects "$fake_home/.claude-container-cc33"
	[ "$status" -eq 0 ]
	# Prototype must NOT be conjured into existence by the harvest.
	[ ! -d "$fake_home/.claude-container" ]
}

@test "harvest_session_projects: union does NOT delete pre-existing prototype files" {
	local fake_home="$BATS_TEST_TMPDIR/harvest-nodelete"
	mkdir -p "$fake_home/.claude-container/projects/-home-user-proj"
	echo '{"old":1}' >"$fake_home/.claude-container/projects/-home-user-proj/uuid-old.jsonl"
	mkdir -p "$fake_home/.claude-container-dd44/projects/-home-user-proj"
	echo '{"new":1}' >"$fake_home/.claude-container-dd44/projects/-home-user-proj/uuid-new.jsonl"
	HOME="$fake_home"
	harvest_session_projects "$fake_home/.claude-container-dd44"
	# Both the pre-existing prototype file and the harvested one survive.
	[ -f "$fake_home/.claude-container/projects/-home-user-proj/uuid-old.jsonl" ]
	[ -f "$fake_home/.claude-container/projects/-home-user-proj/uuid-new.jsonl" ]
}

@test "harvest_session_projects: larger session file replaces a smaller prototype copy" {
	local fake_home="$BATS_TEST_TMPDIR/harvest-larger-wins"
	mkdir -p "$fake_home/.claude-container/projects/-home-user-proj"
	local proto_file="$fake_home/.claude-container/projects/-home-user-proj/uuid-1.jsonl"
	printf 'line1\n' >"$proto_file"
	mkdir -p "$fake_home/.claude-container-ee55/projects/-home-user-proj"
	local sess_file="$fake_home/.claude-container-ee55/projects/-home-user-proj/uuid-1.jsonl"
	printf 'line1\nline2\nline3\n' >"$sess_file"
	HOME="$fake_home"
	harvest_session_projects "$fake_home/.claude-container-ee55"
	# Append-only logs: the longer copy is the more complete one and wins.
	[ "$(wc -l <"$proto_file")" -eq 3 ]
}

@test "harvest_session_projects: smaller session file does NOT overwrite a larger prototype copy" {
	local fake_home="$BATS_TEST_TMPDIR/harvest-smaller-noclobber"
	mkdir -p "$fake_home/.claude-container/projects/-home-user-proj"
	local proto_file="$fake_home/.claude-container/projects/-home-user-proj/uuid-1.jsonl"
	printf 'line1\nline2\nline3\nline4\n' >"$proto_file"
	mkdir -p "$fake_home/.claude-container-ff77/projects/-home-user-proj"
	local sess_file="$fake_home/.claude-container-ff77/projects/-home-user-proj/uuid-1.jsonl"
	printf 'line1\n' >"$sess_file"
	HOME="$fake_home"
	harvest_session_projects "$fake_home/.claude-container-ff77"
	# A stale, shorter session copy must never truncate the prototype's
	# more-complete history — the multi-orphan hazard caught in Judgment Day.
	[ "$(wc -l <"$proto_file")" -eq 4 ]
}

@test "harvest_session_projects: degenerate empty argument is a safe no-op" {
	run harvest_session_projects ""
	[ "$status" -eq 0 ]
}

@test "harvest_session_projects: tolerates a trailing slash in the dir argument" {
	local fake_home="$BATS_TEST_TMPDIR/harvest-trailingslash"
	mkdir -p "$fake_home/.claude-container/projects"
	mkdir -p "$fake_home/.claude-container-ff66/projects/-home-user-proj"
	echo '{}' >"$fake_home/.claude-container-ff66/projects/-home-user-proj/uuid-1.jsonl"
	HOME="$fake_home"
	harvest_session_projects "$fake_home/.claude-container-ff66/"
	[ -f "$fake_home/.claude-container/projects/-home-user-proj/uuid-1.jsonl" ]
}

@test "gc_orphan_session_dirs: harvests projects/ history into prototype before pruning orphan dir" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-harvest"
	mkdir -p "$fake_home/.claude-container/projects"
	# Orphan session dir with durable conversation history under projects/.
	mkdir -p "$fake_home/.claude-container-a7a7/projects/-home-user-proj"
	echo '{"role":"user"}' \
		>"$fake_home/.claude-container-a7a7/projects/-home-user-proj/7a21fbd0.jsonl"
	touch "$fake_home/.claude-container-a7a7.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Docker stub: ps -a returns empty → the dir is an orphan and gets pruned.
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	# Orphan dir is gone …
	[ ! -d "$fake_home/.claude-container-a7a7" ]
	# … but the conversation history was harvested into the prototype first.
	[ -f "$fake_home/.claude-container/projects/-home-user-proj/7a21fbd0.jsonl" ]
}

@test "harvest_session_projects: harvests multiple files across nested slug dirs in one call" {
	local fake_home="$BATS_TEST_TMPDIR/harvest-multifile"
	mkdir -p "$fake_home/.claude-container/projects"
	mkdir -p "$fake_home/.claude-container-1a2b/projects/-home-user-projA"
	mkdir -p "$fake_home/.claude-container-1a2b/projects/-home-user-projB"
	echo '{}' >"$fake_home/.claude-container-1a2b/projects/-home-user-projA/uuid-1.jsonl"
	echo '{}' >"$fake_home/.claude-container-1a2b/projects/-home-user-projB/uuid-2.jsonl"
	HOME="$fake_home"
	harvest_session_projects "$fake_home/.claude-container-1a2b"
	# The find loop walks every file and recreates each slug subdir.
	[ -f "$fake_home/.claude-container/projects/-home-user-projA/uuid-1.jsonl" ]
	[ -f "$fake_home/.claude-container/projects/-home-user-projB/uuid-2.jsonl" ]
}

@test "harvest_session_projects: a copy failure is non-fatal and emits a note" {
	local fake_home="$BATS_TEST_TMPDIR/harvest-cpfail"
	mkdir -p "$fake_home/.claude-container/projects"
	mkdir -p "$fake_home/.claude-container-3c4d/projects/-home-user-proj"
	echo '{}' >"$fake_home/.claude-container-3c4d/projects/-home-user-proj/uuid-1.jsonl"
	# Read-only prototype projects/ tree → the per-file mkdir/cp fails.
	chmod 500 "$fake_home/.claude-container/projects"
	HOME="$fake_home"
	run harvest_session_projects "$fake_home/.claude-container-3c4d"
	# Restore perms so bats can clean up BATS_TEST_TMPDIR.
	chmod 700 "$fake_home/.claude-container/projects"
	# Best-effort contract: never fatal, and the failure is surfaced.
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not harvest"* ]]
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

# ── export_compose_env wiring tests (concurrent-sessions, PR 2 Wire-in) ───────
# Tests for tasks 2.1–2.3: discriminator exports, collision retry/exhaustion,
# GC-first ordering. All tests use DRYDOCK_DISCRIMINATOR_FN stub + fake HOME.

# Helper: write a stateful docker stub that returns different ps output each call.
# Args: counter_file response_1 response_2 ... (responses are space-separated names)
# Each call to the stub increments the counter; returns response_N for call N.
_make_docker_ps_seq_stub() {
	local counter_file="$1"
	shift
	local stub_file="$BATS_TEST_TMPDIR/docker-seq-stub-$$"
	# Encode responses as embedded shell array in the stub script.
	local resp_code=""
	local i=0
	for r in "$@"; do
		resp_code+="responses[$i]='$r'
"
		i=$((i + 1))
	done
	local total_responses=$i
	cat >"$stub_file" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "\${DOCKER_CALL_LOG:-/dev/null}"
if [ "\${1:-}" = "ps" ]; then
	declare -a responses
	${resp_code}total=${total_responses}
	count=0
	[ -f "${counter_file}" ] && count="\$(cat "${counter_file}")"
	idx="\$count"
	[ "\$idx" -ge "\$total" ] && idx="\$((total - 1))"
	new_count="\$((count + 1))"
	printf '%s\n' "\$new_count" > "${counter_file}"
	printf '%s\n' "\${responses[\$idx]}"
fi
exit 0
STUB
	chmod +x "$stub_file"
	printf '%s' "$stub_file"
}

# Helper: setup a fake home with prototype for wiring tests.
_setup_wiring_home() {
	local fake_home="$1"
	mkdir -p "$fake_home/.claude-container"
	touch "$fake_home/.claude-container.json"
}

@test "export_compose_env: exports DRYDOCK_DISCRIMINATOR to the pinned value" {
	local fake_home="$BATS_TEST_TMPDIR/wire-home-disc-$$"
	_setup_wiring_home "$fake_home"
	export HOME="$fake_home"
	_fixed_disc() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc
	export DOCKER="$(_make_docker_ps_stub "")"
	export_compose_env "$TEST_PROJECT_DIR"
	[ "$DRYDOCK_DISCRIMINATOR" = "test" ]
}

@test "export_compose_env: exports DRYDOCK_SESSION_CLAUDE_DIR as HOME/.claude-container-<disc>" {
	local fake_home="$BATS_TEST_TMPDIR/wire-home-dir-$$"
	_setup_wiring_home "$fake_home"
	export HOME="$fake_home"
	_fixed_disc() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc
	export DOCKER="$(_make_docker_ps_stub "")"
	export_compose_env "$TEST_PROJECT_DIR"
	[ "$DRYDOCK_SESSION_CLAUDE_DIR" = "$fake_home/.claude-container-test" ]
}

@test "export_compose_env: exports DRYDOCK_SESSION_CLAUDE_JSON as HOME/.claude-container-<disc>.json" {
	local fake_home="$BATS_TEST_TMPDIR/wire-home-json-$$"
	_setup_wiring_home "$fake_home"
	export HOME="$fake_home"
	_fixed_disc() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc
	export DOCKER="$(_make_docker_ps_stub "")"
	export_compose_env "$TEST_PROJECT_DIR"
	[ "$DRYDOCK_SESSION_CLAUDE_JSON" = "$fake_home/.claude-container-test.json" ]
}

@test "export_compose_env: exports DRYDOCK_SESSION_NAME as drydock-<project>-<disc>" {
	local fake_home="$BATS_TEST_TMPDIR/wire-home-name-$$"
	_setup_wiring_home "$fake_home"
	export HOME="$fake_home"
	_fixed_disc() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc
	export DOCKER="$(_make_docker_ps_stub "")"
	export_compose_env "$TEST_PROJECT_DIR"
	[ "$DRYDOCK_SESSION_NAME" = "drydock-myproject-test" ]
}

@test "export_compose_env: collision retry uses next disc when first two collide" {
	local fake_home="$BATS_TEST_TMPDIR/wire-home-retry-$$"
	_setup_wiring_home "$fake_home"
	export HOME="$fake_home"
	# Discriminator fn emits "aaaa" twice (both collide), then "bbbb" (free).
	local call_count_file="$BATS_TEST_TMPDIR/disc-call-count-$$"
	printf '0' >"$call_count_file"
	_seq_disc() {
		local n
		n="$(cat "$call_count_file")"
		printf '%s' "$((n + 1))" >"$call_count_file"
		case "$n" in
			0) printf 'aaaa' ;;
			1) printf 'aaaa' ;;
			*) printf 'bbbb' ;;
		esac
	}
	export DRYDOCK_DISCRIMINATOR_FN=_seq_disc
	# Stateful stub sequence: gc_orphan_session_dirs calls docker ps -a once at
	# entry (even with no orphan dirs to process); the collision loop then makes
	# additional ps calls. Responses in order:
	#   call 0 (gc pre-check):           "" — no orphans, gc does nothing
	#   call 1 (collision check: "aaaa"): "drydock-myproject-aaaa" — collision!
	#   call 2 (collision check: "aaaa"): "drydock-myproject-aaaa" — still collides
	#   call 3 (collision check: "bbbb"): "" — bbbb is free, break
	local counter_file="$BATS_TEST_TMPDIR/docker-ps-counter-retry-$$"
	printf '0' >"$counter_file"
	local stub
	stub="$(_make_docker_ps_seq_stub "$counter_file" "" "drydock-myproject-aaaa" "drydock-myproject-aaaa" "")"
	export DOCKER="$stub"
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls-retry-$$.log"
	touch "$DOCKER_CALL_LOG"
	export_compose_env "$TEST_PROJECT_DIR"
	# Final COMPOSE_PROJECT_NAME should use the non-colliding disc "bbbb".
	[[ "$COMPOSE_PROJECT_NAME" == "drydock-myproject-bbbb" ]]
}

@test "export_compose_env: collision exhaustion exits non-zero after 5 retries" {
	local fake_home="$BATS_TEST_TMPDIR/wire-home-exhaust-$$"
	_setup_wiring_home "$fake_home"
	export HOME="$fake_home"
	# Always return the same disc (always collides).
	_always_same_disc() { printf 'ffff'; }
	export DRYDOCK_DISCRIMINATOR_FN=_always_same_disc
	# Docker stub always returns the container as live.
	export DOCKER="$(_make_docker_ps_stub "drydock-myproject-ffff")"
	run export_compose_env "$TEST_PROJECT_DIR"
	[ "$status" -ne 0 ]
}

@test "export_compose_env: gc_orphan_session_dirs is called before discriminator generation" {
	local fake_home="$BATS_TEST_TMPDIR/wire-home-gc-order-$$"
	_setup_wiring_home "$fake_home"
	# Create an orphan session dir that GC should prune.
	mkdir -p "$fake_home/.claude-container-dead"
	touch "$fake_home/.claude-container-dead.json"
	export HOME="$fake_home"
	_fixed_disc() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc
	export DOCKER="$(_make_docker_ps_stub "")"
	export_compose_env "$TEST_PROJECT_DIR"
	# GC should have pruned the orphan dir before the disc was assigned.
	[ ! -d "$fake_home/.claude-container-dead" ]
}

# ── Concurrent-sessions PR 2 Slice 2 fixes ────────────────────────────────────

# RED — fix #1 (CRITICAL): a live *-shell container with disc X forces collision
# retry; the collision loop was asymmetric and only matched run containers.
@test "export_compose_env: collision retry when live shell container holds disc" {
	local fake_home="$BATS_TEST_TMPDIR/wire-home-shell-retry-$$"
	_setup_wiring_home "$fake_home"
	export HOME="$fake_home"
	# Discriminator fn emits "a1b2" (collides with shell container), then "c3d4" (free).
	local call_count_file="$BATS_TEST_TMPDIR/disc-shell-count-$$"
	printf '0' >"$call_count_file"
	_seq_disc_shell() {
		local n
		n="$(cat "$call_count_file")"
		printf '%s' "$((n + 1))" >"$call_count_file"
		case "$n" in
			0) printf 'a1b2' ;;
			*) printf 'c3d4' ;;
		esac
	}
	export DRYDOCK_DISCRIMINATOR_FN=_seq_disc_shell
	# Stateful stub: gc pre-check (empty), then collision check sees -shell, then free.
	#   call 0 (gc):             "" — no orphans
	#   call 1 (check "a1b2"):   "drydock-myproject-a1b2-shell" — collision!
	#   call 2 (check "c3d4"):   "" — c3d4 is free, break
	local counter_file="$BATS_TEST_TMPDIR/docker-ps-counter-shell-$$"
	printf '0' >"$counter_file"
	local stub
	stub="$(_make_docker_ps_seq_stub "$counter_file" "" "drydock-myproject-a1b2-shell" "")"
	export DOCKER="$stub"
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls-shell-$$.log"
	touch "$DOCKER_CALL_LOG"
	export_compose_env "$TEST_PROJECT_DIR"
	# Must have retried — final disc is c3d4, not a1b2.
	[[ "$COMPOSE_PROJECT_NAME" == "drydock-myproject-c3d4" ]]
}

# ── generate_links_overlay ────────────────────────────────────────────────────

@test "generate_links_overlay: empty/absent list → overlay file NOT written" {
	local fake_home="$BATS_TEST_TMPDIR/glo-home-empty"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-empty.yml"

	generate_links_overlay "$TEST_PROJECT_DIR"

	[ ! -f "$LINKS_OVERLAY" ]
}

@test "generate_links_overlay: two entries → overlay has 2 :ro volume lines; no environment: block" {
	local fake_home="$BATS_TEST_TMPDIR/glo-home-two"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	# Create the list file for myproject
	local list_dir="$fake_home/.config/drydock/links"
	mkdir -p "$list_dir"
	printf '/host/path/repo-a|/workspace-siblings/repo-a/|\n' > "$list_dir/myproject.list"
	printf '/host/path/repo-b|/custom/target|\n' >> "$list_dir/myproject.list"

	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-two.yml"

	generate_links_overlay "$TEST_PROJECT_DIR"

	[ -f "$LINKS_OVERLAY" ]
	grep -q '^services:' "$LINKS_OVERLAY"
	grep -q '^  drydock:' "$LINKS_OVERLAY"
	grep -q '^    volumes:' "$LINKS_OVERLAY"
	grep -qF '"/host/path/repo-a:/workspace-siblings/repo-a/:ro"' "$LINKS_OVERLAY"
	grep -qF '"/host/path/repo-b:/custom/target:ro"' "$LINKS_OVERLAY"
	# NO environment: block (simpler than submounts — D4)
	! grep -q 'environment:' "$LINKS_OVERLAY"
}

@test "generate_links_overlay: custom container target honored in volume line" {
	local fake_home="$BATS_TEST_TMPDIR/glo-home-custom"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local list_dir="$fake_home/.config/drydock/links"
	mkdir -p "$list_dir"
	printf '/host/path/mylib|/opt/mylib|\n' > "$list_dir/myproject.list"

	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-custom.yml"

	generate_links_overlay "$TEST_PROJECT_DIR"

	[ -f "$LINKS_OVERLAY" ]
	grep -qF '"/host/path/mylib:/opt/mylib:ro"' "$LINKS_OVERLAY"
}

# ── FIX #7/#8: skip malformed lines with empty target ─────────────────────────

@test "generate_links_overlay: FIX-8 line with empty target is skipped — no broken volume spec" {
	local fake_home="$BATS_TEST_TMPDIR/glo-home-badtarget"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local list_dir="$fake_home/.config/drydock/links"
	mkdir -p "$list_dir"
	# First line: empty target field (malformed); second: valid
	printf '/host/path/broken||\n' > "$list_dir/myproject.list"
	printf '/host/path/good|/workspace-siblings/good/|\n' >> "$list_dir/myproject.list"

	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-badtarget.yml"

	generate_links_overlay "$TEST_PROJECT_DIR"

	[ -f "$LINKS_OVERLAY" ]
	# Broken line must NOT appear in the overlay.
	# Use `run` + status check (not bare `!`) because bare `! grep -q` silently
	# passes in bats due to bash's ERR-trap suppression on `! command` forms.
	run grep -F '/host/path/broken' "$LINKS_OVERLAY"
	[ "$status" -ne 0 ]
	# Valid line MUST appear
	grep -qF '/host/path/good' "$LINKS_OVERLAY"
}

# ── T7-RED: generate_links_overlay reads field 3 (flags) ─────────────────────

@test "RW-OVL-1: generate_links_overlay emits :rw for entry with flags=rw" {
	local fake_home="$BATS_TEST_TMPDIR/glo-home-rw"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local list_dir="$fake_home/.config/drydock/links"
	mkdir -p "$list_dir"
	printf '/host/path/mylib|/workspace-siblings/mylib|rw\n' >"$list_dir/myproject.list"

	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-rw.yml"

	generate_links_overlay "$TEST_PROJECT_DIR"

	[ -f "$LINKS_OVERLAY" ]
	grep -qF '"/host/path/mylib:/workspace-siblings/mylib:rw"' "$LINKS_OVERLAY"
}

@test "RW-OVL-2: generate_links_overlay emits :ro for entry with empty flags (backward-compat)" {
	local fake_home="$BATS_TEST_TMPDIR/glo-home-ro"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local list_dir="$fake_home/.config/drydock/links"
	mkdir -p "$list_dir"
	printf '/host/path/mylib|/workspace-siblings/mylib|\n' >"$list_dir/myproject.list"

	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-ro.yml"

	generate_links_overlay "$TEST_PROJECT_DIR"

	[ -f "$LINKS_OVERLAY" ]
	grep -qF '"/host/path/mylib:/workspace-siblings/mylib:ro"' "$LINKS_OVERLAY"
}

@test "RW-OVL-3: generate_links_overlay falls back to :ro for unknown/corrupt flags value" {
	local fake_home="$BATS_TEST_TMPDIR/glo-home-corrupt"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local list_dir="$fake_home/.config/drydock/links"
	mkdir -p "$list_dir"
	printf '/host/path/mylib|/workspace-siblings/mylib|corrupt-flag\n' >"$list_dir/myproject.list"

	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-corrupt.yml"

	generate_links_overlay "$TEST_PROJECT_DIR"

	[ -f "$LINKS_OVERLAY" ]
	# Must fall back to :ro for safety — never :corrupt-flag
	grep -qF '"/host/path/mylib:/workspace-siblings/mylib:ro"' "$LINKS_OVERLAY"
	run grep -F ':corrupt-flag' "$LINKS_OVERLAY"
	[ "$status" -ne 0 ]
}

@test "RW-OVL: mixed RO and RW entries — each emits correct mode" {
	local fake_home="$BATS_TEST_TMPDIR/glo-home-mixed"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local list_dir="$fake_home/.config/drydock/links"
	mkdir -p "$list_dir"
	printf '/host/path/ro-lib|/workspace-siblings/ro-lib|\n' >"$list_dir/myproject.list"
	printf '/host/path/rw-lib|/workspace-siblings/rw-lib|rw\n' >>"$list_dir/myproject.list"

	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-mixed.yml"

	generate_links_overlay "$TEST_PROJECT_DIR"

	[ -f "$LINKS_OVERLAY" ]
	grep -qF '"/host/path/ro-lib:/workspace-siblings/ro-lib:ro"' "$LINKS_OVERLAY"
	grep -qF '"/host/path/rw-lib:/workspace-siblings/rw-lib:rw"' "$LINKS_OVERLAY"
}

# ── T12-RED: compose_files wiring ─────────────────────────────────────────────

@test "compose_files: LINKS_OVERLAY present and non-empty → included after base AND after hardening (audit F4 order)" {
	local fake_home="$BATS_TEST_TMPDIR/cf-home-links"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local list_dir="$fake_home/.config/drydock/links"
	mkdir -p "$list_dir"
	printf '/host/repo-a|/workspace-siblings/repo-a/|\n' > "$list_dir/myproject.list"

	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/submount-links-test.yml"
	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-test.yml"
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-no-submounts.txt"

	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]

	# Must include LINKS_OVERLAY
	[[ "$output" == *"$LINKS_OVERLAY"* ]]

	# Audit F4: MANDATORY overlays (mode, hardening) are emitted FIRST, before
	# fallible feature generators — a mid-stream generator failure can then only
	# truncate features, never the security posture. LINKS_OVERLAY therefore
	# appears after base AND after the hardening overlay.
	local base_pos links_pos hardening_pos
	base_pos=$(printf '%s\n' "$output" | grep -n "docker-compose.yml" | head -1 | cut -d: -f1)
	links_pos=$(printf '%s\n' "$output" | grep -n "links-test.yml" | head -1 | cut -d: -f1)
	hardening_pos=$(printf '%s\n' "$output" | grep -n "hardening" | head -1 | cut -d: -f1)
	[ "$base_pos" -lt "$hardening_pos" ]
	[ "$hardening_pos" -lt "$links_pos" ]
}

# ── Audit F4: mandatory-first emission + fail-loud consumption ────────────────
# Process-substitution consumers (`while read < <(compose_files ...)`) discard
# the producer's exit status: a generator dying mid-stream left a TRUNCATED -f
# list — on dev that could mean a "contained" session with no mode overlay and
# no hardening. Two layers: (1) mandatory overlays are emitted before any
# fallible generator; (2) compose_files_into replaces the consumer idiom and
# aborts hard when assembly fails.

@test "compose_files: mode overlay precedes fallible generators (audit F4 order)" {
	local fake_home="$BATS_TEST_TMPDIR/cf-home-order-$$"
	mkdir -p "$fake_home/.config/drydock/links"
	export HOME="$fake_home"
	printf '/host/repo-a|/workspace-siblings/repo-a/|\n' >"$fake_home/.config/drydock/links/myproject.list"
	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/sub-order-$$.yml"
	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-order-$$.yml"
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-no-submounts.txt"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN

	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	local mode_pos links_pos
	mode_pos=$(printf '%s\n' "$output" | grep -n "docker-compose.contain.yml" | head -1 | cut -d: -f1)
	links_pos=$(printf '%s\n' "$output" | grep -n "links-order" | head -1 | cut -d: -f1)
	[ -n "$mode_pos" ]
	[ -n "$links_pos" ]
	[ "$mode_pos" -lt "$links_pos" ]
}

@test "compose_files: generator failure → non-zero exit, mandatory overlays already emitted" {
	# Sub-mounts detected (fixture) but the overlay path is unwritable → the
	# generator's redirect fails mid-assembly.
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-drvfs-c.txt"
	local ro_dir="$BATS_TEST_TMPDIR/ro-overlay-dir-$$"
	mkdir -p "$ro_dir"
	chmod 555 "$ro_dir"
	export SUBMOUNT_OVERLAY="$ro_dir/submount.yml"
	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-genfail-$$.yml"

	run compose_files "/home/you/projects/myproject"
	chmod u+w "$ro_dir"
	[ "$status" -ne 0 ]
	# The mandatory hardening overlay was emitted BEFORE the failing generator.
	[[ "$output" == *"docker-compose.hardening.yml"* ]]
}

@test "compose_files_into: populates the named array in caller scope" {
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-no-submounts.txt"
	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/sub-cfi-$$.yml"
	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-cfi-$$.yml"
	local compose_args=()
	compose_files_into compose_args "$TEST_PROJECT_DIR"
	[ "${#compose_args[@]}" -ge 2 ]
	[ "${compose_args[0]}" = "-f" ]
	[[ "${compose_args[1]}" == *"docker-compose.yml" ]]
}

@test "compose_files_into: producer failure → hard abort with message, no truncated launch" {
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-drvfs-c.txt"
	local ro_dir="$BATS_TEST_TMPDIR/ro-cfi-dir-$$"
	mkdir -p "$ro_dir"
	chmod 555 "$ro_dir"
	export SUBMOUNT_OVERLAY="$ro_dir/submount.yml"
	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-cfi-fail-$$.yml"

	local compose_args=()
	run compose_files_into compose_args "/home/you/projects/myproject"
	chmod u+w "$ro_dir"
	[ "$status" -ne 0 ]
	[[ "$output" == *"compose file assembly failed"* ]]
}

@test "compose_files: absent links list → LINKS_OVERLAY NOT included" {
	local fake_home="$BATS_TEST_TMPDIR/cf-home-nolinks"
	mkdir -p "$fake_home"
	export HOME="$fake_home"
	# No list file created

	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/submount-nolinks-test.yml"
	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/links-nolinks-test.yml"
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-no-submounts.txt"

	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]

	[[ "$output" != *"links-nolinks-test.yml"* ]]
}

# ── RED — fix #2 (WARNING): GC must NOT prune dirs whose discriminator suffix does
# not match the generator's shape ^[0-9a-f]{4}$  (e.g. "backup").
@test "gc_orphan_session_dirs: does NOT prune dir with non-hex discriminator suffix" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-backup"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-backup"
	touch "$fake_home/.claude-container-backup.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	# Must still exist — "backup" is not a valid drydock discriminator.
	[ -d "$fake_home/.claude-container-backup" ]
}

# ── T8-RED: SSH-CFG-1 — _regenerate_managed_ssh_config atomic + chmod 600 ─────

@test "SSH-CFG-1: _regenerate_managed_ssh_config — atomic write (tmp→mv) and chmod 600" {
	local fake_home="$BATS_TEST_TMPDIR/ssh-cfg1-home"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local primary="testproject"
	local list_file="$fake_home/.config/drydock/links/testproject.list"
	mkdir -p "$(dirname "$list_file")"
	# Empty list — only primary fallback block
	printf '' >"$list_file"

	# Create a primary key
	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/testproject_deploy"

	run _regenerate_managed_ssh_config "$primary" "$list_file"
	[ "$status" -eq 0 ]

	local config_path="$fake_home/.config/drydock/ssh-config-testproject"
	[ -f "$config_path" ]

	local perms
	perms="$(stat -c '%a' "$config_path")"
	[ "$perms" = "600" ]

	# Must contain the primary fallback block
	grep -q "Host github.com" "$config_path"
	grep -q "IdentityFile" "$config_path"
}

@test "SSH-CFG-1: _regenerate_managed_ssh_config — no tmp files left on disk after success" {
	local fake_home="$BATS_TEST_TMPDIR/ssh-cfg1-notmp"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local primary="testproject"
	local list_file="$fake_home/.config/drydock/links/testproject.list"
	mkdir -p "$(dirname "$list_file")"
	printf '' >"$list_file"

	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/testproject_deploy"

	_regenerate_managed_ssh_config "$primary" "$list_file"

	# No .XXXXXX tmp files should remain. mktemp produces a 6-character
	# suffix from the [A-Za-z0-9] alphabet (GNU coreutils + util-linux);
	# the prior "ssh-config-*.tmp*" pattern matched zero files always,
	# making the assertion vacuous. The character class below matches
	# only the actual mktemp output shape.
	#
	# The 6-char [a-zA-Z0-9] pattern matches mktemp's actual suffix shape;
	# it must stay in sync with the X-count in the mktemp template call at
	# lib/compose.sh _regenerate_managed_ssh_config (currently "${config_path}.XXXXXX"
	# → 6 X's → 6-char suffix). If that template ever changes, this find
	# pattern must adapt or the assertion goes vacuous again (the exact bug
	# this commit fixed).
	local tmp_count
	tmp_count=$(find "$fake_home/.config/drydock" \
		-name 'ssh-config-*.[a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9]' \
		2>/dev/null | wc -l)
	[ "$tmp_count" -eq 0 ]
}

@test "SSH-CFG-1: _regenerate_managed_ssh_config — RW sibling with .git/ gets Host alias block" {
	local fake_home="$BATS_TEST_TMPDIR/ssh-cfg1-alias"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local primary="testproject"

	# Create a fake sibling directory with .git/
	local sibling_dir="$BATS_TEST_TMPDIR/mysibling"
	mkdir -p "$sibling_dir/.git"

	local list_file="$fake_home/.config/drydock/links/testproject.list"
	mkdir -p "$(dirname "$list_file")"
	printf '%s|/workspace-siblings/mysibling|rw\n' "$sibling_dir" >"$list_file"

	# Create sibling deploy key
	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/mysibling_deploy"
	chmod 600 "$fake_home/.config/drydock/keys/mysibling_deploy"

	# No primary key
	_regenerate_managed_ssh_config "$primary" "$list_file"

	local config_path="$fake_home/.config/drydock/ssh-config-testproject"
	[ -f "$config_path" ]

	grep -q "Host github.com-mysibling" "$config_path"
	grep -q "HostName github.com" "$config_path"
	grep -q "IdentitiesOnly yes" "$config_path"
	grep -q "User git" "$config_path"
}

@test "SSH-CFG-1: _regenerate_managed_ssh_config — RO-only sibling excluded from alias blocks" {
	local fake_home="$BATS_TEST_TMPDIR/ssh-cfg1-ro"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	local primary="testproject"

	local sibling_dir="$BATS_TEST_TMPDIR/ro-sibling"
	mkdir -p "$sibling_dir/.git"

	local list_file="$fake_home/.config/drydock/links/testproject.list"
	mkdir -p "$(dirname "$list_file")"
	# RO entry — no flags
	printf '%s|/workspace-siblings/ro-sibling|\n' "$sibling_dir" >"$list_file"

	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/testproject_deploy"

	_regenerate_managed_ssh_config "$primary" "$list_file"

	local config_path="$fake_home/.config/drydock/ssh-config-testproject"
	# No alias block for the RO sibling
	run grep "Host github.com-ro-sibling" "$config_path"
	[ "$status" -ne 0 ]
}

# ── T10-RED: SSH-ACT-1 [CRITICAL] — primary-only activation regression ────────

@test "SSH-ACT-1 [CRITICAL]: _maybe_export_ssh_config — primary key only — exports DRYDOCK_SSH_CONFIG" {
	local fake_home="$BATS_TEST_TMPDIR/ssh-act1-home"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	# Primary key exists
	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/myproject_deploy"
	chmod 600 "$fake_home/.config/drydock/keys/myproject_deploy"

	# Empty list (no siblings)
	local list_file="$fake_home/.config/drydock/links/myproject.list"
	mkdir -p "$(dirname "$list_file")"
	printf '' >"$list_file"

	# Call _maybe_export_ssh_config
	unset DRYDOCK_SSH_CONFIG
	_maybe_export_ssh_config "myproject"

	# DRYDOCK_SSH_CONFIG must be exported and point at the config file
	[ -n "${DRYDOCK_SSH_CONFIG:-}" ]
	[ -f "$DRYDOCK_SSH_CONFIG" ]

	# Config must not contain any alias blocks (only the fallback block)
	run grep "Host github.com-" "$DRYDOCK_SSH_CONFIG"
	[ "$status" -ne 0 ]

	local fallback_count
	fallback_count=$(grep -c "^Host github.com$" "$DRYDOCK_SSH_CONFIG")
	[ "$fallback_count" -eq 1 ]

	# File must be chmod 600
	local perms
	perms="$(stat -c '%a' "$DRYDOCK_SSH_CONFIG")"
	[ "$perms" = "600" ]
}

@test "SSH-ACT-1: _maybe_export_ssh_config — no key, no RW siblings — DRYDOCK_SSH_CONFIG NOT set" {
	local fake_home="$BATS_TEST_TMPDIR/ssh-act1-nokey"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	# No primary key, no list file
	unset DRYDOCK_SSH_CONFIG

	_maybe_export_ssh_config "myproject"

	[ -z "${DRYDOCK_SSH_CONFIG:-}" ]
}

@test "SSH-ACT-1: _maybe_export_ssh_config — RW sibling only, no primary key — exports DRYDOCK_SSH_CONFIG" {
	local fake_home="$BATS_TEST_TMPDIR/ssh-act1-rwonly"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	# No primary key
	# But list has one RW entry with .git/
	local sibling_dir="$BATS_TEST_TMPDIR/rw-sibling-act1"
	mkdir -p "$sibling_dir/.git"

	local list_file="$fake_home/.config/drydock/links/myproject.list"
	mkdir -p "$(dirname "$list_file")"
	printf '%s|/workspace-siblings/rw-sibling-act1|rw\n' "$sibling_dir" >"$list_file"

	# Create sibling deploy key
	local sanitized
	sanitized="$(sanitize_project_name "$(basename "$sibling_dir")")"
	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/${sanitized}_deploy"
	chmod 600 "$fake_home/.config/drydock/keys/${sanitized}_deploy"

	unset DRYDOCK_SSH_CONFIG
	_maybe_export_ssh_config "myproject"

	# Must be exported (RW sibling triggers activation)
	[ -n "${DRYDOCK_SSH_CONFIG:-}" ]
	[ -f "$DRYDOCK_SSH_CONFIG" ]
}

@test "compose_files: DRYDOCK_SSH_CONFIG set — docker-compose.ssh.yml included" {
	local fake_home="$BATS_TEST_TMPDIR/cf-ssh-config-home"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/cf-ssh-submount.yml"
	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/cf-ssh-links.yml"
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-no-submounts.txt"
	export DRYDOCK_SSH_CONFIG="$fake_home/.config/drydock/ssh-config-test"
	mkdir -p "$(dirname "$DRYDOCK_SSH_CONFIG")"
	touch "$DRYDOCK_SSH_CONFIG"

	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.ssh.yml"* ]]
}

@test "compose_files: DRYDOCK_SSH_DEPLOY_KEY only (no DRYDOCK_SSH_CONFIG) — ssh.yml NOT included" {
	local fake_home="$BATS_TEST_TMPDIR/cf-deploy-key-only"
	mkdir -p "$fake_home"
	export HOME="$fake_home"

	export SUBMOUNT_OVERLAY="$BATS_TEST_TMPDIR/cf-dk-submount.yml"
	export LINKS_OVERLAY="$BATS_TEST_TMPDIR/cf-dk-links.yml"
	export MOUNTINFO_FILE="$DRYDOCK_HOME/test/fixtures/mountinfo-no-submounts.txt"
	export DRYDOCK_SSH_DEPLOY_KEY="$fake_home/.config/drydock/keys/test_deploy"
	unset DRYDOCK_SSH_CONFIG

	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	# After the activation gate change, DRYDOCK_SSH_DEPLOY_KEY alone is no longer
	# the gate — DRYDOCK_SSH_CONFIG is. So ssh.yml should NOT be included here.
	run grep "docker-compose.ssh.yml" <(printf '%s\n' "$output")
	[ "$status" -ne 0 ]
}

# ── SR-9 structural: docker-compose.yml projects/ sub-mount ──────────────────
# Structural text assertions: prove the compose file has the correct sub-mount
# line and does NOT use the host ~/.claude/ path as a mount source.

@test "SR-9: docker-compose.yml contains the shared projects/ sub-mount line" {
	# The sub-mount must bind the container-specific shared store, not host ~/.claude/.
	grep -qF '${HOME}/.claude-container/projects:${HOME}/.claude/projects:rw' \
		"$DRYDOCK_HOME/docker-compose.yml"
}

@test "SR-9: no compose file uses host ~/.claude/projects as a mount SOURCE" {
	# The left-hand side of the projects mount must be ~/.claude-container/projects,
	# NEVER the host ~/.claude/projects.
	# Assert that no volume line has ${HOME}/.claude/projects as the source (LHS).
	! grep -E '"\$\{HOME\}/\.claude/projects:' "$DRYDOCK_HOME/docker-compose.yml"
}

# ── #71 structural: hooks RO overlay source is the per-session dir ───────────
# The agent-cannot-write-its-own-hooks guarantee (INV-3) holds regardless of
# source path because the mount flag is :ro. Issue #71 moves the SOURCE from
# the host's ~/.claude/hooks/ to the per-session container-state dir's hooks/
# subpath so the container never reads directly from host ~/.claude/ (the lone
# INV-2 exception is eliminated). Both invariants are checked here.

@test "#71: docker-compose.yml hooks :ro overlay sources from the per-session dir" {
	# The RO overlay must source from ${DRYDOCK_SESSION_CLAUDE_DIR}/hooks (the
	# per-session seeded dir), NOT from ${HOME}/.claude/hooks (host-direct).
	# Accepts both the bare form and the :? guard form (consistent with line 66).
	grep -qE '\$\{DRYDOCK_SESSION_CLAUDE_DIR(:\?[^}]*)?\}/hooks:\$\{HOME\}/\.claude/hooks:ro' \
		"$DRYDOCK_HOME/docker-compose.yml"
}

@test "#71: no compose file uses host ~/.claude/hooks as a mount SOURCE" {
	# The left-hand side of the hooks mount must be the per-session dir, NEVER
	# the host ~/.claude/hooks. This eliminates the last container-reads-host
	# exception in INV-2. Glob covers docker-compose.yml and all overlays so a
	# future docker-compose.hooks.yml is automatically checked.
	! grep -E '"\$\{HOME\}/\.claude/hooks:' "$DRYDOCK_HOME"/docker-compose*.yml
}

@test "#71: hooks mount overlay preserves the :ro flag (INV-3)" {
	# Whatever the source, the hooks subpath MUST be mounted :ro on top of the
	# per-session .claude mount. Without :ro the agent could rewrite its own
	# hooks and disable its own guardrails — the INV-3 core guarantee.
	grep -qE '/hooks:\$\{HOME\}/\.claude/hooks:ro' \
		"$DRYDOCK_HOME/docker-compose.yml"
}

@test "#71: seed_session_config_dir copies hooks/ content from prototype into per-session dir" {
	# Guards against a future regression where someone excludes hooks/ from the
	# seed loop (the way projects/ is already excluded). The hooks RO overlay
	# sources from the per-session dir — if seed_session_config_dir doesn't copy
	# hooks/ content there, the overlay mounts an empty dir and guardrails are
	# silently dropped.
	local fake_home="$BATS_TEST_TMPDIR/seed-hooks-$$"
	mkdir -p "$fake_home"
	_make_prototype_with_projects "$fake_home"
	# Add a hook file to the prototype
	mkdir -p "$fake_home/.claude-container/hooks"
	printf 'hook-content' >"$fake_home/.claude-container/hooks/myhook.sh"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	seed_session_config_dir "ee55"
	[ -f "$fake_home/.claude-container-ee55/hooks/myhook.sh" ]
	[ "$(cat "$fake_home/.claude-container-ee55/hooks/myhook.sh")" = "hook-content" ]
}

# ── Phase 2: seed_session_config_dir — Bats Tests (SR-6, SR-11, SR-7, design-risk-6) ──

# Helper: populate prototype with projects/ content and sibling dirs in a fake HOME.
_make_prototype_with_projects() {
	local fake_home="$1"
	# Base prototype files (same as _make_prototype)
	mkdir -p "$fake_home/.claude-container/skills"
	printf 'proto-settings' >"$fake_home/.claude-container/settings.json"
	printf 'proto-marker' >"$fake_home/.claude-container/.drydock-last-sync"
	printf 'proto-json' >"$fake_home/.claude-container.json"
	# Dotfile in prototype (design risk #6: must be copied by new find loop)
	printf 'sync-marker' >"$fake_home/.claude-container/.drydock-last-sync"
	# projects/ subtree in prototype — must NOT be copied to per-session dir
	mkdir -p "$fake_home/.claude-container/projects/my-project"
	printf 'history line\n' >"$fake_home/.claude-container/projects/my-project/uuid-A.jsonl"
	# Sibling dirs that MUST survive into per-session dir (SR-11)
	mkdir -p "$fake_home/.claude-container/todos"
	printf 'todo-item' >"$fake_home/.claude-container/todos/item.txt"
	mkdir -p "$fake_home/.claude-container/statsig"
	printf 'statsig-data' >"$fake_home/.claude-container/statsig/data.json"
	mkdir -p "$fake_home/.claude-container/shell-snapshots"
	printf 'snap' >"$fake_home/.claude-container/shell-snapshots/snap.txt"
}

@test "SR-6: seed_session_config_dir does NOT copy projects/ content into per-session dir" {
	# Prototype has projects/my-project/uuid-A.jsonl — must NOT appear in session dir.
	local fake_home="$BATS_TEST_TMPDIR/seed-no-projects-$$"
	mkdir -p "$fake_home"
	_make_prototype_with_projects "$fake_home"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	seed_session_config_dir "aa11"
	# projects/ subdir may exist as an empty mount-point placeholder, but must have no .jsonl
	[ ! -f "$fake_home/.claude-container-aa11/projects/my-project/uuid-A.jsonl" ]
}

@test "SR-11: seed_session_config_dir copies todos/ statsig/ shell-snapshots/ into per-session dir" {
	# These sibling dirs are per-session state and must survive the new find loop.
	local fake_home="$BATS_TEST_TMPDIR/seed-siblings-$$"
	mkdir -p "$fake_home"
	_make_prototype_with_projects "$fake_home"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	seed_session_config_dir "bb22"
	[ -f "$fake_home/.claude-container-bb22/todos/item.txt" ]
	[ -f "$fake_home/.claude-container-bb22/statsig/data.json" ]
	[ -f "$fake_home/.claude-container-bb22/shell-snapshots/snap.txt" ]
}

@test "SR-7-seed: seed_session_config_dir returns 0 with no error when prototype absent" {
	# No prototype dir at all — must return 0 cleanly.
	local fake_home="$BATS_TEST_TMPDIR/seed-no-proto-$$"
	mkdir -p "$fake_home"
	# Do NOT create ~/.claude-container
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	run seed_session_config_dir "cc33"
	[ "$status" -eq 0 ]
	# No new dirs should have been created
	[ ! -d "$fake_home/.claude-container-cc33" ]
}

@test "design-risk-6: seed_session_config_dir copies dotfiles from prototype into per-session dir" {
	# find -mindepth 1 -maxdepth 1 must catch dotfiles; a bare glob would miss them.
	# We add a dotfile distinct from .drydock-last-sync (which is intentionally removed).
	local fake_home="$BATS_TEST_TMPDIR/seed-dotfile-$$"
	mkdir -p "$fake_home"
	_make_prototype "$fake_home"
	# Add an extra dotfile that is NOT .drydock-last-sync
	printf 'dot-content' >"$fake_home/.claude-container/.some-dotfile"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	seed_session_config_dir "dd44"
	# The dotfile must be present in the session dir
	[ -f "$fake_home/.claude-container-dd44/.some-dotfile" ]
}

# ── Phase 4: migrate_projects_to_shared_store — Bats Tests ───────────────────

@test "SR-1a: migrate selects larger copy on UUID collision" {
	# Two per-session dirs with same UUID, different sizes; larger wins.
	local fake_home="$BATS_TEST_TMPDIR/migrate-sr1a-$$"
	mkdir -p "$fake_home/.claude-container/projects"  # shared store (destination)
	mkdir -p "$fake_home/.claude-container-abc1/projects/proj"
	printf '%100s' '' >"$fake_home/.claude-container-abc1/projects/proj/uuid-A.jsonl"  # 100 bytes
	mkdir -p "$fake_home/.claude-container-def2/projects/proj"
	printf '%200s' '' >"$fake_home/.claude-container-def2/projects/proj/uuid-A.jsonl"  # 200 bytes
	mkdir -p "$fake_home/.config/drydock"
	HOME="$fake_home"
	migrate_projects_to_shared_store
	# Larger copy (200 bytes) must be in shared store
	local sz
	sz=$(wc -c <"$fake_home/.claude-container/projects/proj/uuid-A.jsonl" 2>/dev/null)
	[ "${sz:-0}" -eq 200 ]
	# No per-session file should be deleted by migration
	[ -f "$fake_home/.claude-container-abc1/projects/proj/uuid-A.jsonl" ]
	[ -f "$fake_home/.claude-container-def2/projects/proj/uuid-A.jsonl" ]
}

@test "SR-1b: migrate preserves both UUIDs from different per-session dirs" {
	# Two per-session dirs with distinct UUIDs — both land in shared store.
	local fake_home="$BATS_TEST_TMPDIR/migrate-sr1b-$$"
	mkdir -p "$fake_home/.claude-container/projects"
	mkdir -p "$fake_home/.claude-container-abc1/projects/proj"
	printf 'history-A\n' >"$fake_home/.claude-container-abc1/projects/proj/uuid-A.jsonl"
	mkdir -p "$fake_home/.claude-container-def2/projects/proj"
	printf 'history-B\n' >"$fake_home/.claude-container-def2/projects/proj/uuid-B.jsonl"
	mkdir -p "$fake_home/.config/drydock"
	HOME="$fake_home"
	migrate_projects_to_shared_store
	[ -f "$fake_home/.claude-container/projects/proj/uuid-A.jsonl" ]
	[ -f "$fake_home/.claude-container/projects/proj/uuid-B.jsonl" ]
}

@test "SR-2: migrate is idempotent — second run leaves shared store unchanged" {
	local fake_home="$BATS_TEST_TMPDIR/migrate-sr2-$$"
	mkdir -p "$fake_home/.claude-container/projects/proj"
	printf '%200s' '' >"$fake_home/.claude-container/projects/proj/uuid-A.jsonl"
	mkdir -p "$fake_home/.claude-container-abc1/projects/proj"
	printf '%200s' '' >"$fake_home/.claude-container-abc1/projects/proj/uuid-A.jsonl"
	mkdir -p "$fake_home/.config/drydock"
	HOME="$fake_home"
	migrate_projects_to_shared_store
	# sentinel exists now — second run must be a no-op
	[ -f "$fake_home/.config/drydock/.projects-migrated" ]
	# Touch the shared store file to give it a newer mtime, then re-run — must not change size
	local before_sz
	before_sz=$(wc -c <"$fake_home/.claude-container/projects/proj/uuid-A.jsonl")
	run migrate_projects_to_shared_store
	[ "$status" -eq 0 ]
	local after_sz
	after_sz=$(wc -c <"$fake_home/.claude-container/projects/proj/uuid-A.jsonl")
	[ "$before_sz" -eq "$after_sz" ]
}

@test "SR-7-migrate-empty + SR-8a: migrate returns 0 with empty shared store and no session dirs" {
	local fake_home="$BATS_TEST_TMPDIR/migrate-empty-$$"
	mkdir -p "$fake_home/.claude-container/projects"  # empty shared store
	mkdir -p "$fake_home/.config/drydock"
	HOME="$fake_home"
	run migrate_projects_to_shared_store
	[ "$status" -eq 0 ]
	# Sentinel must be created
	[ -f "$fake_home/.config/drydock/.projects-migrated" ]
}

@test "SR-7-migrate-nomatch: migrate returns 0 when no per-session dirs exist" {
	# Glob matches nothing — guard against unmatched glob without nullglob.
	local fake_home="$BATS_TEST_TMPDIR/migrate-nomatch-$$"
	mkdir -p "$fake_home/.claude-container/projects"
	mkdir -p "$fake_home/.config/drydock"
	HOME="$fake_home"
	# No ~/.claude-container-?*/ dirs at all
	run migrate_projects_to_shared_store
	[ "$status" -eq 0 ]
}

@test "sentinel-timing: migrate without sentinel re-sweeps; with sentinel is fast-path no-op" {
	local fake_home="$BATS_TEST_TMPDIR/migrate-sentinel-$$"
	mkdir -p "$fake_home/.claude-container/projects"
	mkdir -p "$fake_home/.claude-container-abc1/projects/proj"
	printf 'line\n' >"$fake_home/.claude-container-abc1/projects/proj/uuid-X.jsonl"
	mkdir -p "$fake_home/.config/drydock"
	HOME="$fake_home"
	# First run: no sentinel → sweep runs
	migrate_projects_to_shared_store
	[ -f "$fake_home/.claude-container/projects/proj/uuid-X.jsonl" ]
	[ -f "$fake_home/.config/drydock/.projects-migrated" ]
	# Second run: sentinel present → fast-path; even if we add new content it won't be swept
	mkdir -p "$fake_home/.claude-container-def3/projects/proj"
	printf 'new-line\n' >"$fake_home/.claude-container-def3/projects/proj/uuid-Y.jsonl"
	migrate_projects_to_shared_store
	# uuid-Y must NOT be in shared store (sentinel blocked the sweep)
	[ ! -f "$fake_home/.claude-container/projects/proj/uuid-Y.jsonl" ]
}

@test "fresh-install: migrate creates sentinel even when .config/drydock/ does not pre-exist" {
	# On a brand-new install, ~/.config/drydock/ may not exist yet.
	local fake_home="$BATS_TEST_TMPDIR/migrate-fresh-install-$$"
	mkdir -p "$fake_home/.claude-container/projects"
	# Do NOT create .config/drydock/
	HOME="$fake_home"
	run migrate_projects_to_shared_store
	[ "$status" -eq 0 ]
	[ -f "$fake_home/.config/drydock/.projects-migrated" ]
}

# ── Phase 6: GC safety (SR-4, SR-5, SR-7) ────────────────────────────────────

@test "SR-5: gc_orphan_session_dirs removes orphan dir but leaves shared store intact" {
	local fake_home="$BATS_TEST_TMPDIR/gc-sr5-$$"
	mkdir -p "$fake_home"
	# Shared store with a file
	mkdir -p "$fake_home/.claude-container/projects/proj"
	printf 'durable history\n' >"$fake_home/.claude-container/projects/proj/uuid-X.jsonl"
	local expected_sz
	expected_sz=$(wc -c <"$fake_home/.claude-container/projects/proj/uuid-X.jsonl")
	# Orphan per-session dir with an EMPTY projects/ placeholder (post-upgrade shape)
	mkdir -p "$fake_home/.claude-container-abc1/projects"
	touch "$fake_home/.claude-container-abc1.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	# Orphan dir removed
	[ ! -d "$fake_home/.claude-container-abc1" ]
	# Shared store untouched
	[ -f "$fake_home/.claude-container/projects/proj/uuid-X.jsonl" ]
	local after_sz
	after_sz=$(wc -c <"$fake_home/.claude-container/projects/proj/uuid-X.jsonl")
	[ "$expected_sz" -eq "$after_sz" ]
}

@test "SR-7-gc-no-projects: gc_orphan_session_dirs removes orphan dir with no projects/ subtree" {
	local fake_home="$BATS_TEST_TMPDIR/gc-no-projects-$$"
	mkdir -p "$fake_home"
	# Orphan dir with NO projects/ subdirectory
	mkdir -p "$fake_home/.claude-container-ee55"
	touch "$fake_home/.claude-container-ee55/settings.json"
	touch "$fake_home/.claude-container-ee55.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	run gc_orphan_session_dirs
	[ "$status" -eq 0 ]
	[ ! -d "$fake_home/.claude-container-ee55" ]
}

@test "SR-4: harvest_session_projects preserves both UUIDs from two distinct sessions" {
	# Two sessions each with a distinct UUID — both survive in the shared store.
	local fake_home="$BATS_TEST_TMPDIR/gc-sr4-$$"
	mkdir -p "$fake_home/.claude-container/projects"
	mkdir -p "$fake_home/.claude-container-aa11/projects/proj"
	printf 'session-A history\n' >"$fake_home/.claude-container-aa11/projects/proj/uuid-A.jsonl"
	mkdir -p "$fake_home/.claude-container-bb22/projects/proj"
	printf 'session-B history\n' >"$fake_home/.claude-container-bb22/projects/proj/uuid-B.jsonl"
	HOME="$fake_home"
	harvest_session_projects "$fake_home/.claude-container-aa11"
	harvest_session_projects "$fake_home/.claude-container-bb22"
	[ -f "$fake_home/.claude-container/projects/proj/uuid-A.jsonl" ]
	[ -f "$fake_home/.claude-container/projects/proj/uuid-B.jsonl" ]
}

# ── Phase 9: SR-3 and SR-8b end-to-end behavioral ────────────────────────────

@test "SR-3: history survives migration + GC and is present for new session" {
	# Simulates the issue #68 acceptance scenario end-to-end (host-side).
	local fake_home="$BATS_TEST_TMPDIR/e2e-sr3-$$"
	mkdir -p "$fake_home"
	# Session 1 per-session dir with projects/ history
	mkdir -p "$fake_home/.claude-container-abc1/projects/proj"
	printf 'conversation turn\n' >"$fake_home/.claude-container-abc1/projects/proj/uuid-X.jsonl"
	touch "$fake_home/.claude-container-abc1.json"
	# Shared store destination
	mkdir -p "$fake_home/.claude-container/projects"
	mkdir -p "$fake_home/.config/drydock"
	# Step 1: run migration (consolidate pre-upgrade history)
	HOME="$fake_home"
	migrate_projects_to_shared_store
	[ -f "$fake_home/.claude-container/projects/proj/uuid-X.jsonl" ]
	# Step 2: run GC (orphan dir removed)
	export PROJECT_NAME="myproject"
	local stub
	stub="$(_make_docker_ps_stub "")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	[ ! -d "$fake_home/.claude-container-abc1" ]
	# Step 3: verify shared store still has the file
	[ -f "$fake_home/.claude-container/projects/proj/uuid-X.jsonl" ]
	# Step 4: seed new session — session dir has no projects/ content from prototype
	_make_prototype "$fake_home"
	seed_session_config_dir "def2"
	[ ! -f "$fake_home/.claude-container-def2/projects/proj/uuid-X.jsonl" ]
}

@test "SR-8b: first session can write history into a fresh shared store" {
	# Simulate a fresh write directly to the shared store (as the container would).
	local fake_home="$BATS_TEST_TMPDIR/e2e-sr8b-$$"
	mkdir -p "$fake_home/.claude-container/projects"
	HOME="$fake_home"
	# Write a file as if the container did it
	mkdir -p "$fake_home/.claude-container/projects/my-proj"
	printf 'first conversation\n' >"$fake_home/.claude-container/projects/my-proj/uuid-N.jsonl"
	# The file must persist
	[ -f "$fake_home/.claude-container/projects/my-proj/uuid-N.jsonl" ]
	content=$(cat "$fake_home/.claude-container/projects/my-proj/uuid-N.jsonl")
	[ "$content" = "first conversation" ]
}

# ── Phase 10: SR-10 doc grep assertions ──────────────────────────────────────

@test "SR-10: CLAUDE.md INV-2 section contains host-mount prohibition and append-only projects/ carve-out" {
	# Extract only the INV-2 section (from '### INV-2' up to but not including '### INV-3')
	# and assert BOTH anchors are present within that slice.  Greping the whole file would
	# pass even if INV-2's text were deleted (phrases appear in other invariants).
	local inv2_section
	inv2_section="$(awk '/^### INV-2:/,/^### INV-3:/{if (/^### INV-3:/) exit; print}' "$DRYDOCK_HOME/CLAUDE.md")"

	# Anchor 1: the prohibition on host paths as ANY container-mount source.
	# Strengthened in #71: covers writable AND read-only mounts (the hooks RO
	# overlay no longer carves out an exception).
	echo "$inv2_section" | grep -qE "MUST NEVER be the source of any container mount"

	# Anchor 2: the append-only projects/ carve-out
	echo "$inv2_section" | grep -q "append-only"
	echo "$inv2_section" | grep -q "projects/"
}

# ── INV-3 mount #2 — per-session drydock-hooks seeding (T19 structural) ──────

@test "export_compose_env: exports DRYDOCK_SESSION_HOOKS_DIR pointing at drydock-hooks subpath" {
	# T-1 (RED): verify that export_compose_env sets DRYDOCK_SESSION_HOOKS_DIR
	# to $HOME/.claude-container-<disc>/drydock-hooks. Will fail until the
	# export line is added to lib/compose.sh:export_compose_env().
	export_compose_env "$TEST_PROJECT_DIR"
	[ -n "${DRYDOCK_SESSION_HOOKS_DIR:-}" ]
	[ "$DRYDOCK_SESSION_HOOKS_DIR" = "$HOME/.claude-container-dflt/drydock-hooks" ]
}

@test "seed_session_config_dir: populates drydock-hooks/ from templates/hooks/ and live-container guard short-circuits it" {
	# T-2 (RED): verify that seed_session_config_dir seeds the drydock-hooks/
	# subpath from $DRYDOCK_HOME/templates/hooks/. Will fail until the seed
	# block is added to lib/compose.sh:seed_session_config_dir().

	local disc="t2seed"
	local session_dir="$HOME/.claude-container-${disc}"

	# Seed runs only when prototype exists (checked by seed_session_config_dir).
	mkdir -p "$HOME/.claude-container"
	touch "$HOME/.claude-container.json"

	# Default DOCKER stub returns empty for ps — live-container guard passes.
	seed_session_config_dir "$disc"

	# The drydock-hooks/ subpath must exist and contain the scripts.
	[ -d "$session_dir/drydock-hooks" ]
	[ -f "$session_dir/drydock-hooks/drydock-block-destructive.sh" ]
	[ -f "$session_dir/drydock-hooks/drydock-session-start.sh" ]

	# Live-container guard: when Docker ps reports a running container for this
	# disc, re-seeding is skipped (the subpath already populated above is untouched).
	# We verify skip by removing the dir and checking it is NOT re-created.
	rm -rf "$session_dir/drydock-hooks"
	local live_stub="$BATS_TEST_TMPDIR/docker-live-$$"
	cat >"$live_stub" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "ps" ]; then
    printf 'drydock-myproject-t2seed\n'
fi
exit 0
STUB
	chmod +x "$live_stub"
	export DOCKER="$live_stub"
	seed_session_config_dir "$disc"
	[ ! -d "$session_dir/drydock-hooks" ]
}

# ── #89 RED — host gitconfig isolation via url.insteadOf ──────────────────────
#
# Issue #89: `drydock link --rw` rewrote remote.origin.url in the sibling's
# .git/config, contaminating the host with an SSH alias that only resolves
# inside the container. Fix: never mutate the sibling; instead, generate a
# per-project gitconfig with [include] + url.insteadOf blocks and point
# GIT_CONFIG_GLOBAL at it inside the container.
#
# Helper: build a fake RW sibling with .git/ and a canonical github URL.
_make_rw_sibling_with_url() {
	local sibling_dir="$1"
	local owner_repo="$2"  # e.g. "owner/repo"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -q -b main >/dev/null 2>&1
	git -C "$sibling_dir" remote add origin "git@github.com:${owner_repo}.git"
}

@test "#89 RED: export_compose_env generates per-project gitconfig with [include] + url.insteadOf per RW sibling" {
	local fake_home="$BATS_TEST_TMPDIR/89-gen-home"
	mkdir -p "$fake_home/.claude-container"
	touch "$fake_home/.claude-container.json"
	export HOME="$fake_home"

	# One RW sibling with a canonical GitHub SSH URL
	local sib_a="$BATS_TEST_TMPDIR/89-gen-sib-a"
	_make_rw_sibling_with_url "$sib_a" "owner/repoA"
	local sanitized_a
	sanitized_a="$(sanitize_project_name "$(basename "$sib_a")")"

	# Activate SSH overlay: drop sibling deploy key + list entry
	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/${sanitized_a}_deploy"
	chmod 600 "$fake_home/.config/drydock/keys/${sanitized_a}_deploy"
	mkdir -p "$fake_home/.config/drydock/links"
	printf '%s|/workspace-siblings/%s|rw\n' "$sib_a" "$(basename "$sib_a")" \
		>"$fake_home/.config/drydock/links/myproject.list"

	export_compose_env "$TEST_PROJECT_DIR"

	# Per-project gitconfig was written at the expected path.
	local gconf="$fake_home/.config/drydock/gitconfig-myproject"
	[ -f "$gconf" ]

	# [include] block pulls in host ~/.gitconfig (identity passthrough).
	grep -q '^\[include\]' "$gconf"
	grep -qE 'path[[:space:]]*=[[:space:]]*~/.gitconfig' "$gconf"

	# url.insteadOf block rewrites the canonical URL → aliased URL inside the container.
	grep -qE "^\[url \"git@github\\.com-${sanitized_a}:owner/repoA\\.git\"\]" "$gconf"
	grep -qE "insteadOf[[:space:]]*=[[:space:]]*git@github\\.com:owner/repoA\\.git" "$gconf"

	# File mode is 600 (gitconfig under XDG_CONFIG, no group/world read).
	local perms
	perms="$(stat -c '%a' "$gconf")"
	[ "$perms" = "600" ]
}

@test "#89 RED: export_compose_env exports GIT_CONFIG_GLOBAL pointing at the per-project gitconfig" {
	local fake_home="$BATS_TEST_TMPDIR/89-env-home"
	mkdir -p "$fake_home/.claude-container"
	touch "$fake_home/.claude-container.json"
	export HOME="$fake_home"

	local sib="$BATS_TEST_TMPDIR/89-env-sib"
	_make_rw_sibling_with_url "$sib" "owner/repo"
	local sanitized
	sanitized="$(sanitize_project_name "$(basename "$sib")")"
	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/${sanitized}_deploy"
	chmod 600 "$fake_home/.config/drydock/keys/${sanitized}_deploy"
	mkdir -p "$fake_home/.config/drydock/links"
	printf '%s|/workspace-siblings/%s|rw\n' "$sib" "$(basename "$sib")" \
		>"$fake_home/.config/drydock/links/myproject.list"

	unset DRYDOCK_GITCONFIG
	export_compose_env "$TEST_PROJECT_DIR"

	# Compose interpolates this into docker-compose.ssh.yml as the
	# GIT_CONFIG_GLOBAL container env var.
	[ "${DRYDOCK_GITCONFIG:-}" = "$fake_home/.config/drydock/gitconfig-myproject" ]
}

@test "#89 RED: export_compose_env restores aliased URL to canonical on startup (migration from v0.2.1)" {
	local fake_home="$BATS_TEST_TMPDIR/89-migrate-home"
	mkdir -p "$fake_home/.claude-container"
	touch "$fake_home/.claude-container.json"
	export HOME="$fake_home"

	# Sibling has the v0.2.1-era aliased URL still in its .git/config.
	local sib="$BATS_TEST_TMPDIR/89-migrate-sib"
	mkdir -p "$sib"
	git -C "$sib" init -q -b main >/dev/null 2>&1
	local sanitized
	sanitized="$(sanitize_project_name "$(basename "$sib")")"
	git -C "$sib" remote add origin "git@github.com-${sanitized}:owner/repo.git"

	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/${sanitized}_deploy"
	chmod 600 "$fake_home/.config/drydock/keys/${sanitized}_deploy"
	mkdir -p "$fake_home/.config/drydock/links"
	printf '%s|/workspace-siblings/%s|rw\n' "$sib" "$(basename "$sib")" \
		>"$fake_home/.config/drydock/links/myproject.list"

	export_compose_env "$TEST_PROJECT_DIR"

	# After startup migration, sibling .git/config must hold the canonical URL.
	local restored
	restored="$(git -C "$sib" remote get-url origin)"
	[ "$restored" = "git@github.com:owner/repo.git" ]
}

@test "#89 RED: export_compose_env skips RW sibling with non-GitHub URL without erroring" {
	local fake_home="$BATS_TEST_TMPDIR/89-skip-home"
	mkdir -p "$fake_home/.claude-container"
	touch "$fake_home/.claude-container.json"
	export HOME="$fake_home"

	# Sibling with an HTTPS URL — cannot generate an insteadOf block.
	local sib="$BATS_TEST_TMPDIR/89-skip-sib"
	mkdir -p "$sib"
	git -C "$sib" init -q -b main >/dev/null 2>&1
	git -C "$sib" remote add origin "https://github.com/owner/repo.git"
	local sanitized
	sanitized="$(sanitize_project_name "$(basename "$sib")")"
	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/${sanitized}_deploy"
	chmod 600 "$fake_home/.config/drydock/keys/${sanitized}_deploy"
	mkdir -p "$fake_home/.config/drydock/links"
	printf '%s|/workspace-siblings/%s|rw\n' "$sib" "$(basename "$sib")" \
		>"$fake_home/.config/drydock/links/myproject.list"

	# Must NOT abort — non-canonical URLs are skipped silently or with warn.
	export_compose_env "$TEST_PROJECT_DIR" 2>/dev/null

	# Gitconfig was generated (still has [include] block) but has no url block
	# for the unparseable sibling.
	local gconf="$fake_home/.config/drydock/gitconfig-myproject"
	[ -f "$gconf" ]
	grep -q '^\[include\]' "$gconf"
	! grep -qE '^\[url ' "$gconf"
}

@test "#89 RED: export_compose_env writes minimal gitconfig ([include] only) when no RW sibling but SSH overlay active (primary key only)" {
	# Activation gate parity with SSH overlay: when primary-key-only triggers
	# the SSH overlay, GIT_CONFIG_GLOBAL is still set (overlay activation is
	# the single gate) and the file contains the [include] passthrough.
	local fake_home="$BATS_TEST_TMPDIR/89-minimal-home"
	mkdir -p "$fake_home/.claude-container"
	touch "$fake_home/.claude-container.json"
	export HOME="$fake_home"

	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/myproject_deploy"
	chmod 600 "$fake_home/.config/drydock/keys/myproject_deploy"

	unset DRYDOCK_GITCONFIG
	export_compose_env "$TEST_PROJECT_DIR"

	[ -n "${DRYDOCK_GITCONFIG:-}" ]
	[ -f "$DRYDOCK_GITCONFIG" ]
	grep -q '^\[include\]' "$DRYDOCK_GITCONFIG"
	# No url blocks (no RW siblings).
	! grep -qE '^\[url ' "$DRYDOCK_GITCONFIG"
}

@test "#89 RED: export_compose_env does NOT set DRYDOCK_GITCONFIG when SSH overlay inactive (no key, no RW)" {
	local fake_home="$BATS_TEST_TMPDIR/89-noconf-home"
	mkdir -p "$fake_home/.claude-container"
	touch "$fake_home/.claude-container.json"
	export HOME="$fake_home"

	unset DRYDOCK_GITCONFIG
	export_compose_env "$TEST_PROJECT_DIR"

	[ -z "${DRYDOCK_GITCONFIG:-}" ]
}

# ── dual-mode network/socket gate (contained default, literal-"1" overrides) ──
# Design §7a + §7b. Factory default = contained. Only the exact literal "1"
# activates an env override (mirrors DRYDOCK_NO_HARDENING gate).
# Each test isolates HOME + unsets both env vars so ambient container env can't leak.

@test "compose_files: no sentinels, no env — contain overlay present, dood absent" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export HOME="$BATS_TEST_TMPDIR/dm-contain-$$"
	mkdir -p "$HOME/.claude-container" && touch "$HOME/.claude-container.json"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.contain.yml"* ]]
	[[ "$output" != *"docker-compose.dood.yml"* ]]
}

@test "compose_files: dood sentinel present — dood overlay present, contain absent" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export HOME="$BATS_TEST_TMPDIR/dm-dood-sent-$$"
	mkdir -p "$HOME/.claude-container" && touch "$HOME/.claude-container.json"
	mkdir -p "$HOME/.config/drydock/dood" && touch "$HOME/.config/drydock/dood/myproject"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.dood.yml"* ]]
	[[ "$output" != *"docker-compose.contain.yml"* ]]
}

@test "compose_files: contain sentinel present — contain overlay present, dood absent" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export HOME="$BATS_TEST_TMPDIR/dm-cont-sent-$$"
	mkdir -p "$HOME/.claude-container" && touch "$HOME/.claude-container.json"
	mkdir -p "$HOME/.config/drydock/contain" && touch "$HOME/.config/drydock/contain/myproject"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.contain.yml"* ]]
	[[ "$output" != *"docker-compose.dood.yml"* ]]
}

@test "compose_files: DRYDOCK_DOOD=1 — dood overlay present" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export HOME="$BATS_TEST_TMPDIR/dm-env-dood-$$"
	mkdir -p "$HOME/.claude-container" && touch "$HOME/.claude-container.json"
	unset DRYDOCK_CONTAIN
	export DRYDOCK_DOOD=1
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.dood.yml"* ]]
	[[ "$output" != *"docker-compose.contain.yml"* ]]
}

@test "compose_files: DRYDOCK_CONTAIN=1 — contain overlay present" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export HOME="$BATS_TEST_TMPDIR/dm-env-cont-$$"
	mkdir -p "$HOME/.claude-container" && touch "$HOME/.claude-container.json"
	unset DRYDOCK_DOOD
	export DRYDOCK_CONTAIN=1
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.contain.yml"* ]]
	[[ "$output" != *"docker-compose.dood.yml"* ]]
}

@test "compose_files: both DRYDOCK_DOOD=1 and DRYDOCK_CONTAIN=1 — contain overlay (fail-closed)" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export HOME="$BATS_TEST_TMPDIR/dm-both-env-$$"
	mkdir -p "$HOME/.claude-container" && touch "$HOME/.claude-container.json"
	export DRYDOCK_DOOD=1
	export DRYDOCK_CONTAIN=1
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.contain.yml"* ]]
	[[ "$output" != *"docker-compose.dood.yml"* ]]
}

@test "compose_files: both dood+contain sentinels — contain overlay (fail-closed)" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export HOME="$BATS_TEST_TMPDIR/dm-both-sent-$$"
	mkdir -p "$HOME/.claude-container" && touch "$HOME/.claude-container.json"
	mkdir -p "$HOME/.config/drydock/dood" && touch "$HOME/.config/drydock/dood/myproject"
	mkdir -p "$HOME/.config/drydock/contain" && touch "$HOME/.config/drydock/contain/myproject"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.contain.yml"* ]]
	[[ "$output" != *"docker-compose.dood.yml"* ]]
}

@test "compose_files: default-dood present, no project pin — dood overlay" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export HOME="$BATS_TEST_TMPDIR/dm-global-dood-$$"
	mkdir -p "$HOME/.claude-container" && touch "$HOME/.claude-container.json"
	mkdir -p "$HOME/.config/drydock" && touch "$HOME/.config/drydock/default-dood"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.dood.yml"* ]]
	[[ "$output" != *"docker-compose.contain.yml"* ]]
}

@test "compose_files: DRYDOCK_DOOD=true (non-\"1\") — contain overlay (env inactive)" {
	export MOUNTS_FILE="$MOUNTS_FILE_NO_DOCS"
	export HOME="$BATS_TEST_TMPDIR/dm-dood-true-$$"
	mkdir -p "$HOME/.claude-container" && touch "$HOME/.claude-container.json"
	unset DRYDOCK_CONTAIN
	export DRYDOCK_DOOD="true"
	run compose_files "$TEST_PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker-compose.contain.yml"* ]]
	[[ "$output" != *"docker-compose.dood.yml"* ]]
}

# ── resolve_run_mode precedence (direct unit tests) ───────────────────────────
# Design §7b. Tests call resolve_run_mode directly and inspect field-1 (mode)
# or field-2+ (reason). Each test isolates HOME and unsets env vars.

@test "resolve_run_mode: field-1 factory default → contained" {
	export HOME="$BATS_TEST_TMPDIR/rrm-factory-$$"
	mkdir -p "$HOME"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN
	result="$(resolve_run_mode "myproject")"
	mode="${result%% *}"
	[ "$mode" = "contained" ]
}

@test "resolve_run_mode: field-1 DRYDOCK_DOOD=1 → dood" {
	export HOME="$BATS_TEST_TMPDIR/rrm-dood-env-$$"
	mkdir -p "$HOME"
	unset DRYDOCK_CONTAIN
	export DRYDOCK_DOOD=1
	result="$(resolve_run_mode "myproject")"
	mode="${result%% *}"
	[ "$mode" = "dood" ]
}

@test "resolve_run_mode: field-1 DRYDOCK_CONTAIN=1 → contained" {
	export HOME="$BATS_TEST_TMPDIR/rrm-cont-env-$$"
	mkdir -p "$HOME"
	unset DRYDOCK_DOOD
	export DRYDOCK_CONTAIN=1
	result="$(resolve_run_mode "myproject")"
	mode="${result%% *}"
	[ "$mode" = "contained" ]
}

@test "resolve_run_mode: field-1 DRYDOCK_DOOD=true → contained (non-\"1\" inactive)" {
	export HOME="$BATS_TEST_TMPDIR/rrm-dood-true-$$"
	mkdir -p "$HOME"
	unset DRYDOCK_CONTAIN
	export DRYDOCK_DOOD="true"
	result="$(resolve_run_mode "myproject")"
	mode="${result%% *}"
	[ "$mode" = "contained" ]
}

@test "resolve_run_mode: field-1 both env vars → contained (fail-closed)" {
	export HOME="$BATS_TEST_TMPDIR/rrm-both-env-$$"
	mkdir -p "$HOME"
	export DRYDOCK_DOOD=1
	export DRYDOCK_CONTAIN=1
	result="$(resolve_run_mode "myproject")"
	mode="${result%% *}"
	[ "$mode" = "contained" ]
}

@test "resolve_run_mode: field-2 env override → reason contains 'env override'" {
	export HOME="$BATS_TEST_TMPDIR/rrm-reason-env-$$"
	mkdir -p "$HOME"
	unset DRYDOCK_CONTAIN
	export DRYDOCK_DOOD=1
	result="$(resolve_run_mode "myproject")"
	reason="${result#* }"
	[[ "$reason" == *"env override"* ]]
}

@test "resolve_run_mode: field-2 factory → reason contains 'factory default'" {
	export HOME="$BATS_TEST_TMPDIR/rrm-reason-factory-$$"
	mkdir -p "$HOME"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN
	result="$(resolve_run_mode "myproject")"
	reason="${result#* }"
	[[ "$reason" == *"factory default"* ]]
}

@test "resolve_run_mode: field-2 global default → reason contains 'global default'" {
	export HOME="$BATS_TEST_TMPDIR/rrm-reason-global-$$"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/default-dood"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN
	result="$(resolve_run_mode "myproject")"
	reason="${result#* }"
	[[ "$reason" == *"global default"* ]]
}

@test "resolve_run_mode: field-2 project pin → reason contains 'project pin'" {
	export HOME="$BATS_TEST_TMPDIR/rrm-reason-pin-$$"
	mkdir -p "$HOME/.config/drydock/dood"
	touch "$HOME/.config/drydock/dood/myproject"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN
	result="$(resolve_run_mode "myproject")"
	reason="${result#* }"
	[[ "$reason" == *"project pin"* ]]
}

@test "resolve_run_mode: env beats per-project pin (DRYDOCK_CONTAIN=1 with dood sentinel)" {
	export HOME="$BATS_TEST_TMPDIR/rrm-env-beats-pin-$$"
	mkdir -p "$HOME/.config/drydock/dood"
	touch "$HOME/.config/drydock/dood/myproject"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/default-dood"
	unset DRYDOCK_DOOD
	export DRYDOCK_CONTAIN=1
	result="$(resolve_run_mode "myproject")"
	mode="${result%% *}"
	[ "$mode" = "contained" ]
	reason="${result#* }"
	[[ "$reason" == *"env override"* ]]
}

@test "resolve_run_mode: project pin beats global default (contain pin with default-dood)" {
	export HOME="$BATS_TEST_TMPDIR/rrm-pin-beats-global-$$"
	mkdir -p "$HOME/.config/drydock/contain"
	touch "$HOME/.config/drydock/contain/myproject"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/default-dood"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN
	result="$(resolve_run_mode "myproject")"
	mode="${result%% *}"
	[ "$mode" = "contained" ]
}

# ── Phase 2 egress jail — filter generation (R9.14–R9.18) ───────────────────
# All five tests use synthetic HOME with prototype dirs, the _make_docker_ps_stub
# seam, and DRYDOCK_DOOD / DRYDOCK_CONTAIN env overrides. The egress baseline is
# the shipped templates/egress-baseline.conf (resolved from DRYDOCK_HOME).

# Helper: fresh HOME with the minimum structure export_compose_env expects.
_egress_fake_home() {
	local h="$BATS_TEST_TMPDIR/egress-home-$$-${RANDOM}"
	mkdir -p "$h/.claude-container"
	touch "$h/.claude-container.json"
	printf '%s' "$h"
}

@test "export_compose_env: contained — DRYDOCK_EGRESS_FILTER_FILE exported and file exists" {
	local fh
	fh="$(_egress_fake_home)"
	export HOME="$fh"
	export DOCKER="$(_make_docker_ps_stub "")"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN

	export_compose_env "$TEST_PROJECT_DIR"

	# The var must be exported and the file must exist on disk.
	[ -n "${DRYDOCK_EGRESS_FILTER_FILE:-}" ]
	[ -f "$DRYDOCK_EGRESS_FILTER_FILE" ]
}

@test "export_compose_env: contained — filter file contains api.anthropic.com" {
	local fh
	fh="$(_egress_fake_home)"
	export HOME="$fh"
	export DOCKER="$(_make_docker_ps_stub "")"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN

	export_compose_env "$TEST_PROJECT_DIR"

	# Filter file contains ERE host patterns; baseline uses ^api\.anthropic\.com$.
	# Fixed-string search for the literal escaped-dot form that tinyproxy uses.
	grep -qF 'api\.anthropic\.com' "$DRYDOCK_EGRESS_FILTER_FILE"
}

@test "export_compose_env: contained — filter file contains user global additions" {
	local fh
	fh="$(_egress_fake_home)"
	export HOME="$fh"
	export DOCKER="$(_make_docker_ps_stub "")"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN

	# Place a global user allowlist.
	mkdir -p "$fh/.config/drydock"
	printf 'example-custom.com\n' >"$fh/.config/drydock/egress-allowlist"

	export_compose_env "$TEST_PROJECT_DIR"

	grep -qF 'example-custom.com' "$DRYDOCK_EGRESS_FILTER_FILE"
}

@test "export_compose_env: contained — user file cannot remove baseline entries" {
	local fh
	fh="$(_egress_fake_home)"
	export HOME="$fh"
	export DOCKER="$(_make_docker_ps_stub "")"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN

	# User file omits api.anthropic.com entirely — baseline MUST still appear.
	mkdir -p "$fh/.config/drydock"
	printf 'other-domain.example\n' >"$fh/.config/drydock/egress-allowlist"

	export_compose_env "$TEST_PROJECT_DIR"

	grep -qF 'api\.anthropic\.com' "$DRYDOCK_EGRESS_FILTER_FILE"
}

@test "export_compose_env: dood — DRYDOCK_EGRESS_FILTER_FILE not set" {
	local fh
	fh="$(_egress_fake_home)"
	export HOME="$fh"
	export DOCKER="$(_make_docker_ps_stub "")"
	unset DRYDOCK_CONTAIN
	export DRYDOCK_DOOD=1
	# Seed a stale value from a hypothetical prior contained run. The dood branch
	# of export_compose_env MUST unset this — the assertion verifies the unset runs,
	# not just that the var happens to be absent from a clean-env start.
	export DRYDOCK_EGRESS_FILTER_FILE=/stale/leftover-from-prior-contained-run

	export_compose_env "$TEST_PROJECT_DIR"

	# The dood branch must clear the stale contained-mode var.
	[ -z "${DRYDOCK_EGRESS_FILTER_FILE:-}" ]
}

@test "export_compose_env: contained — empty baseline is safe (pipefail robustness)" {
	# Verifies _generate_egress_filter exits 0 and the run continues when the
	# effective filter (after stripping comments/blanks) is empty. This guards
	# against the grep-empty-output pipefail trap (set -euo pipefail).
	local fh
	fh="$(_egress_fake_home)"
	export HOME="$fh"
	export DOCKER="$(_make_docker_ps_stub "")"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN

	# Override EGRESS_BASELINE to an all-comment file.
	local fake_baseline="$BATS_TEST_TMPDIR/egress-empty-baseline-$$"
	printf '# comment only\n# another comment\n' >"$fake_baseline"
	EGRESS_BASELINE="$fake_baseline"

	# Must not abort under set -euo pipefail.
	export_compose_env "$TEST_PROJECT_DIR"

	# File must exist (even if empty).
	[ -f "$DRYDOCK_EGRESS_FILTER_FILE" ]
}

@test "export_compose_env: contained — unreadable allowlist source fails loud (FIX1)" {
	# This test only works as non-root; root bypasses file permissions.
	if [ "$(id -u)" -eq 0 ]; then
		skip "test requires non-root (root bypasses file permissions)"
	fi
	local fh
	fh="$(_egress_fake_home)"
	export HOME="$fh"
	export DOCKER="$(_make_docker_ps_stub "")"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN

	# Create a global user allowlist that exists but is unreadable.
	mkdir -p "$fh/.config/drydock"
	printf 'example-custom.com\n' >"$fh/.config/drydock/egress-allowlist"
	chmod 000 "$fh/.config/drydock/egress-allowlist"

	# err() calls exit; use run to capture the non-zero exit.
	run export_compose_env "$TEST_PROJECT_DIR"

	# Restore permissions so cleanup can proceed.
	chmod 644 "$fh/.config/drydock/egress-allowlist"

	[ "$status" -ne 0 ]
	[[ "$output" == *"unreadable"* ]]
}

@test "export_compose_env: contained — DRYDOCK_SIDECAR_NAME exported and ends with -egress (FIX2)" {
	local fh
	fh="$(_egress_fake_home)"
	export HOME="$fh"
	export DOCKER="$(_make_docker_ps_stub "")"
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN

	export_compose_env "$TEST_PROJECT_DIR"

	[ -n "${DRYDOCK_SIDECAR_NAME:-}" ]
	[[ "$DRYDOCK_SIDECAR_NAME" == *"-egress" ]]
}

@test "export_compose_env: dood — DRYDOCK_SIDECAR_NAME not set (FIX2)" {
	local fh
	fh="$(_egress_fake_home)"
	export HOME="$fh"
	export DOCKER="$(_make_docker_ps_stub "")"
	unset DRYDOCK_CONTAIN
	export DRYDOCK_DOOD=1
	# Seed a stale value from a hypothetical prior contained run.
	# The dood branch MUST unset this — verifying the unset actually runs.
	export DRYDOCK_SIDECAR_NAME=stale-sidecar-name

	export_compose_env "$TEST_PROJECT_DIR"

	[ -z "${DRYDOCK_SIDECAR_NAME:-}" ]
}

@test "#89 RED: export_compose_env does NOT mutate canonical sibling URL during startup migration" {
	local fake_home="$BATS_TEST_TMPDIR/89-noop-home"
	mkdir -p "$fake_home/.claude-container"
	touch "$fake_home/.claude-container.json"
	export HOME="$fake_home"

	local sib="$BATS_TEST_TMPDIR/89-noop-sib"
	_make_rw_sibling_with_url "$sib" "owner/repo"
	local before
	before="$(git -C "$sib" remote get-url origin)"

	local sanitized
	sanitized="$(sanitize_project_name "$(basename "$sib")")"
	mkdir -p "$fake_home/.config/drydock/keys"
	touch "$fake_home/.config/drydock/keys/${sanitized}_deploy"
	chmod 600 "$fake_home/.config/drydock/keys/${sanitized}_deploy"
	mkdir -p "$fake_home/.config/drydock/links"
	printf '%s|/workspace-siblings/%s|rw\n' "$sib" "$(basename "$sib")" \
		>"$fake_home/.config/drydock/links/myproject.list"

	export_compose_env "$TEST_PROJECT_DIR"

	local after
	after="$(git -C "$sib" remote get-url origin)"
	[ "$before" = "$after" ]
	[ "$after" = "git@github.com:owner/repo.git" ]
}

# ── Phase 2 egress jail — sidecar lifecycle (gc reap, collision, ensure_image) ─

@test "gc_orphan_session_dirs: reaps an orphaned -egress sidecar when the agent is gone (A2.T3)" {
	local fake_home="$BATS_TEST_TMPDIR/gc-home-egress-reap"
	mkdir -p "$fake_home"
	# Orphan dir for disc "dead" (4-char hex → passes the generator-shape guard).
	mkdir -p "$fake_home/.claude-container-dead"
	touch "$fake_home/.claude-container-dead.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# ps -a: the AGENT (drydock-myproject-dead) is gone, but its per-session sidecar
	# lingers. The sidecar name does NOT match the liveness regex (…-dead(-shell)?$),
	# so the dir is correctly seen as orphaned — and the sidecar must be reaped.
	local stub
	stub="$(_make_docker_ps_stub "drydock-myproject-dead-egress")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	# Dir reaped (proves the sidecar did NOT falsely protect the orphan dir, A6).
	[ ! -d "$fake_home/.claude-container-dead" ]
	# Orphaned sidecar rm -f'd.
	grep -q "rm -f drydock-myproject-dead-egress" "$DOCKER_CALL_LOG"
}

@test "gc_orphan_session_dirs: a live agent still protects its dir even with an -egress sidecar present" {
	# Belt-and-suspenders for A6: the liveness regex must NOT be widened to -egress.
	# When the AGENT is live, the dir is protected; the (also-present) sidecar is NOT
	# reaped (it belongs to a live session).
	local fake_home="$BATS_TEST_TMPDIR/gc-home-egress-live"
	mkdir -p "$fake_home"
	mkdir -p "$fake_home/.claude-container-beef"
	touch "$fake_home/.claude-container-beef.json"
	HOME="$fake_home"
	export PROJECT_NAME="myproject"
	# Both the live agent and its sidecar are present.
	local stub
	stub="$(_make_docker_ps_stub "drydock-myproject-beef
drydock-myproject-beef-egress")"
	export DOCKER="$stub"
	gc_orphan_session_dirs
	# Live agent → dir protected.
	[ -d "$fake_home/.claude-container-beef" ]
	# Sidecar of a LIVE session must NOT be reaped.
	! grep -q "rm -f drydock-myproject-beef-egress" "$DOCKER_CALL_LOG"
}

@test "export_compose_env: COLLISION — a disc whose -egress sidecar lingers is treated as taken (A6)" {
	local fake_home="$BATS_TEST_TMPDIR/wire-home-egresscoll-$$"
	_setup_wiring_home "$fake_home"
	export HOME="$fake_home"
	# disc fn: first "eeee" (its -egress sidecar lingers → must be rejected),
	# then "ffff" (free).
	local call_count_file="$BATS_TEST_TMPDIR/disc-egresscoll-count-$$"
	printf '0' >"$call_count_file"
	_seq_disc_egresscoll() {
		local n
		n="$(cat "$call_count_file")"
		printf '%s' "$((n + 1))" >"$call_count_file"
		case "$n" in
			0) printf 'eeee' ;;
			*) printf 'ffff' ;;
		esac
	}
	export DRYDOCK_DISCRIMINATOR_FN=_seq_disc_egresscoll
	# ps seq: call0 gc → "" (no orphan dirs); call1 collision "eeee" → a lingering
	# -egress sidecar; call2 collision "ffff" → free.
	local counter_file="$BATS_TEST_TMPDIR/docker-ps-counter-egresscoll-$$"
	printf '0' >"$counter_file"
	local stub
	stub="$(_make_docker_ps_seq_stub "$counter_file" "" "drydock-myproject-eeee-egress" "")"
	export DOCKER="$stub"
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls-egresscoll-$$.log"
	touch "$DOCKER_CALL_LOG"
	export_compose_env "$TEST_PROJECT_DIR"
	# Without the -egress arm in the collision regex, "eeee" would be picked.
	[[ "$COMPOSE_PROJECT_NAME" == "drydock-myproject-ffff" ]]
}

@test "ensure_image: contained mode + egress image missing → triggers cmd_build (A2.T4 forward)" {
	export HOME="$BATS_TEST_TMPDIR/ei-contained-$$"
	mkdir -p "$HOME"
	export PROJECT_NAME="myproject"
	# Agent image present; resolver → contained (clean HOME, no sentinels/env).
	image_exists() { return 0; }
	local marker="$BATS_TEST_TMPDIR/ei-build-marker-$$"
	cmd_build() { printf 'BUILT\n' >>"$marker"; }
	# docker stub: `image inspect <egress>` → missing (exit 1).
	local stub="$BATS_TEST_TMPDIR/ei-docker-$$"
	cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${DOCKER_CALL_LOG:?}"
[ "${1:-}" = "image" ] && exit 1
exit 0
STUB
	chmod +x "$stub"
	export DOCKER="$stub"
	ensure_image
	[ -f "$marker" ]
}

@test "ensure_image: dood mode + egress image missing → does NOT build it (dood unaffected, INV-9)" {
	export HOME="$BATS_TEST_TMPDIR/ei-dood-$$"
	mkdir -p "$HOME"
	export PROJECT_NAME="myproject"
	export DRYDOCK_DOOD=1
	image_exists() { return 0; }
	local marker="$BATS_TEST_TMPDIR/ei-dood-marker-$$"
	cmd_build() { printf 'BUILT\n' >>"$marker"; }
	local stub="$BATS_TEST_TMPDIR/ei-dood-docker-$$"
	cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${DOCKER_CALL_LOG:?}"
[ "${1:-}" = "image" ] && exit 1
exit 0
STUB
	chmod +x "$stub"
	export DOCKER="$stub"
	ensure_image
	[ ! -f "$marker" ]
	unset DRYDOCK_DOOD
}
