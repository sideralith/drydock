#!/usr/bin/env bats
# test/lib_commands.bats — unit tests for lib/commands.sh
#
# Sources all lib/*.sh files (mirroring bin/drydock source order). Uses
# synthetic $HOME, DOCKER seam, and OS-detection seams (UNAME, OSRELEASE_FILE)
# to test cmd_setup, cmd_sync, cmd_status, and ensure_runtime_dirs without
# spawning real containers or requiring engram to be installed.

load "helpers/load"

# ── Shared helpers ────────────────────────────────────────────────────────────

# Build a fake $HOME with the minimum structure cmd_setup expects.
setup_fake_home() {
	local fakehome="$BATS_TEST_TMPDIR/fakehome"
	mkdir -p "$fakehome/.claude"
	printf '{"mcpServers":{"engram":{"type":"stdio","command":"engram","args":["mcp"]},"github":{"type":"stdio","command":"gh","args":["mcp"]}},"projects":{"/p1":{"mcpServers":{"engram":{"type":"stdio","command":"engram"},"other":{"type":"stdio","command":"other"}}},"/p2":{"mcpServers":{"other":{"type":"stdio","command":"other"}}},"/p3":{}}}\n' \
		>"$fakehome/.claude.json"
	echo "$fakehome"
}

# Stub a plain-Linux OSRELEASE_FILE (no microsoft).
setup_plain_linux_seams() {
	local fixture="$BATS_TEST_TMPDIR/osrelease-plain-$$"
	printf '6.5.0-45-generic\n' >"$fixture"
	export OSRELEASE_FILE="$fixture"
	local stub_dir="$BATS_TEST_TMPDIR/uname-linux-$$"
	mkdir -p "$stub_dir"
	printf '#!/usr/bin/env bash\necho "Linux"\n' >"$stub_dir/uname"
	chmod +x "$stub_dir/uname"
	export UNAME="$stub_dir/uname"
}

# Stub macOS seams.
setup_macos_seams() {
	export OSRELEASE_FILE="$BATS_TEST_TMPDIR/no-such-osrelease-$$"
	local stub_dir="$BATS_TEST_TMPDIR/uname-darwin-$$"
	mkdir -p "$stub_dir"
	printf '#!/usr/bin/env bash\necho "Darwin"\n' >"$stub_dir/uname"
	chmod +x "$stub_dir/uname"
	export UNAME="$stub_dir/uname"
}

# Put a fake engram binary on PATH.
setup_engram_on_path() {
	local fake_bin="$BATS_TEST_TMPDIR/fake-bin-engram-$$"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\n' >"$fake_bin/engram"
	chmod +x "$fake_bin/engram"
	export PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

# Remove engram from PATH (keep system binaries).
setup_no_engram_on_path() {
	local empty_bin="$BATS_TEST_TMPDIR/empty-bin-$$"
	mkdir -p "$empty_bin"
	export PATH="$empty_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

setup() {
	# Source order mirrors bin/drydock: common → paths → compose → commands.
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/commands.sh"

	# Stub side-effectful functions so tests don't touch Docker.
	ensure_prereqs() { :; }
	ensure_image() { :; }

	# DOCKER seam: log calls to a file; exit 0.
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	# Default: plain Linux seams.
	setup_plain_linux_seams
}

# ── ensure_runtime_dirs: engram not usable ────────────────────────────────────
# Regression guard: a missing $CONTAINER_ENGRAM must NOT trigger cmd_setup when
# engram is not usable in the container.

@test "ensure_runtime_dirs: engram not usable + missing CONTAINER_ENGRAM — does NOT trigger cmd_setup" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	# Reload path constants for the new HOME.
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	# Ensure CONTAINER_ENGRAM does not exist (it lives under fakehome).
	rm -rf "$CONTAINER_ENGRAM"

	# But CONTAINER_CLAUDE and CONTAINER_CLAUDE_JSON must exist so ensure_runtime_dirs
	# doesn't trigger setup for those reasons.
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	local sentinel="$BATS_TEST_TMPDIR/cmd_setup_called"
	cmd_setup() { touch "$sentinel"; }

	ensure_runtime_dirs

	[ ! -f "$sentinel" ]
}

# ── ensure_runtime_dirs: engram usable + isolated + missing dir ───────────────
# Positive regression guard: engram usable + isolated + $CONTAINER_ENGRAM missing
# DOES trigger cmd_setup.

@test "ensure_runtime_dirs: engram usable + isolated + missing CONTAINER_ENGRAM — DOES trigger cmd_setup" {
	setup_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	# No engram-shared sentinel → isolated mode.
	rm -f "$HOME/.config/drydock/engram-shared"
	rm -rf "$CONTAINER_ENGRAM"

	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	local sentinel="$BATS_TEST_TMPDIR/cmd_setup_called_positive"
	cmd_setup() { touch "$sentinel"; }

	ensure_runtime_dirs

	[ -f "$sentinel" ]
}

# ── cmd_setup: engram not usable ─────────────────────────────────────────────

@test "cmd_setup: engram not usable (Linux, absent) — CONTAINER_ENGRAM not created, note printed" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	rm -rf "$CONTAINER_ENGRAM"

	run cmd_setup
	[ ! -d "$CONTAINER_ENGRAM" ]
	[[ "$output" == *"engram not on PATH"* ]]
}

@test "cmd_setup: engram not usable (macOS) — CONTAINER_ENGRAM not created, macOS note printed" {
	setup_no_engram_on_path
	setup_macos_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	rm -rf "$CONTAINER_ENGRAM"

	run cmd_setup
	[ ! -d "$CONTAINER_ENGRAM" ]
	[[ "$output" == *"macOS binary can't run inside the Linux container"* ]]
}

# ── cmd_setup: engram usable + isolated ──────────────────────────────────────

@test "cmd_setup: engram usable + isolated + no HOST_ENGRAM — CONTAINER_ENGRAM created empty" {
	setup_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	rm -rf "$CONTAINER_ENGRAM"
	rm -rf "$HOME/.engram"

	run cmd_setup
	[ -d "$CONTAINER_ENGRAM" ]
}

@test "cmd_setup: engram usable + isolated + HOST_ENGRAM present — CONTAINER_ENGRAM seeded from host" {
	setup_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	rm -rf "$CONTAINER_ENGRAM"
	mkdir -p "$HOST_ENGRAM"
	printf 'seed-data\n' >"$HOST_ENGRAM/engram.db"

	run cmd_setup
	[ -d "$CONTAINER_ENGRAM" ]
	[ -f "$CONTAINER_ENGRAM/engram.db" ]
}

# ── cmd_status: 2-state engram reporting ─────────────────────────────────────

@test "cmd_status: engram not usable — output contains 'not detected (opt-in)'" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	# image_exists is used by cmd_status.
	image_exists() { return 1; }

	run cmd_status
	[[ "$output" == *"not detected (opt-in)"* ]]
}

@test "cmd_status: engram usable + isolated — output contains 'isolated (~/.engram-container)'" {
	setup_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	mkdir -p "$CONTAINER_ENGRAM"
	image_exists() { return 1; }

	run cmd_status
	[[ "$output" == *"isolated (~/.engram-container)"* ]]
}

# ── MCP filter: cmd_setup × ~/.claude-container.json ─────────────────────────

@test "cmd_setup: engram not usable — mcpServers.engram absent in container JSON" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	run cmd_setup
	# mcpServers.engram must be filtered out of the container copy
	[ -f "$CONTAINER_CLAUDE_JSON" ]
	local engram_entry
	engram_entry="$(jq '.mcpServers.engram' "$CONTAINER_CLAUDE_JSON")"
	[ "$engram_entry" = "null" ]
}

@test "cmd_setup: engram not usable — per-project mcpServers.engram absent in container JSON" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	run cmd_setup
	[ -f "$CONTAINER_CLAUDE_JSON" ]
	# Per-project engram entry must also be filtered
	local p1_engram
	p1_engram="$(jq '.projects["/p1"].mcpServers.engram' "$CONTAINER_CLAUDE_JSON")"
	[ "$p1_engram" = "null" ]
	# Other server entries must survive
	local p1_other
	p1_other="$(jq '.projects["/p1"].mcpServers.other' "$CONTAINER_CLAUDE_JSON")"
	[ "$p1_other" != "null" ]
}

@test "cmd_setup: engram not usable — github server survives in container JSON" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	run cmd_setup
	[ -f "$CONTAINER_CLAUDE_JSON" ]
	local github_entry
	github_entry="$(jq '.mcpServers.github' "$CONTAINER_CLAUDE_JSON")"
	[ "$github_entry" != "null" ]
}

@test "cmd_setup: engram usable — mcpServers.engram survives in container JSON" {
	setup_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	run cmd_setup
	[ -f "$CONTAINER_CLAUDE_JSON" ]
	local engram_entry
	engram_entry="$(jq '.mcpServers.engram' "$CONTAINER_CLAUDE_JSON")"
	[ "$engram_entry" != "null" ]
}

# ── MCP filter: cmd_setup × mcp/engram.json ──────────────────────────────────

@test "cmd_setup: engram not usable — mcp/engram.json absent after setup" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	# Plant an mcp/engram.json in the source ~/.claude/
	mkdir -p "$fakehome/.claude/mcp"
	printf '{"type":"stdio","command":"engram","args":["mcp"]}\n' \
		>"$fakehome/.claude/mcp/engram.json"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	run cmd_setup
	[ ! -f "$CONTAINER_CLAUDE/mcp/engram.json" ]
}

@test "cmd_setup: engram not usable — no error when mcp/engram.json absent from source" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	# mcp/ dir intentionally absent from source

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	run cmd_setup
	[ "$status" -eq 0 ]
}

# ── MCP filter: cmd_sync × ~/.claude-container.json ──────────────────────────

@test "cmd_sync: engram not usable — mcpServers.engram absent in refreshed container JSON" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
	ensure_image() { :; }

	# Pre-create the container dirs so cmd_sync doesn't fail on missing paths.
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	run cmd_sync
	[ -f "$CONTAINER_CLAUDE_JSON" ]
	local engram_entry
	engram_entry="$(jq '.mcpServers.engram' "$CONTAINER_CLAUDE_JSON")"
	[ "$engram_entry" = "null" ]
	# cmd_sync must also emit the Linux-absent note (engram not on PATH)
	[[ "$output" == *"engram not on PATH"* ]]
}

@test "cmd_sync: engram usable — mcpServers.engram survives in refreshed container JSON" {
	setup_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
	ensure_image() { :; }

	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	run cmd_sync
	[ -f "$CONTAINER_CLAUDE_JSON" ]
	local engram_entry
	engram_entry="$(jq '.mcpServers.engram' "$CONTAINER_CLAUDE_JSON")"
	[ "$engram_entry" != "null" ]
}

# ── MCP filter: cmd_sync × rsync --exclude='mcp/engram.json' ─────────────────

@test "cmd_sync: engram not usable — rsync args include --exclude='mcp/engram.json'" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
	ensure_image() { :; }

	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/sync-docker-calls.log"
	touch "$DOCKER_CALL_LOG"

	run cmd_sync
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"--exclude=mcp/engram.json"* ]]
}

@test "cmd_sync: engram usable — rsync args do NOT include --exclude='mcp/engram.json'" {
	setup_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
	ensure_image() { :; }

	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/sync-docker-calls-usable.log"
	touch "$DOCKER_CALL_LOG"

	run cmd_sync
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" != *"--exclude=mcp/engram.json"* ]]
}

@test "cmd_sync: does NOT inject hooks.SessionStart into container settings.json" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
	ensure_image() { :; }

	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"
	# Start with settings.json that has no hooks block.
	printf '{"permissions":{"deny":[]}}\n' >"$CONTAINER_CLAUDE/settings.json"

	run cmd_sync
	[ "$status" -eq 0 ]
	# After sync, hooks.SessionStart MUST still be absent — it is now the
	# managed layer's responsibility, not cmd_sync's.
	local result
	result="$(jq '.hooks.SessionStart' "$CONTAINER_CLAUDE/settings.json")"
	[ "$result" = "null" ]
}

# ── ensure_runtime_dirs: shared mode ─────────────────────────────────────────

@test "ensure_runtime_dirs: shared mode (sentinel present + usable) — missing CONTAINER_ENGRAM does NOT trigger cmd_setup" {
	setup_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/engram-shared"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	rm -rf "$CONTAINER_ENGRAM"
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	local sentinel="$BATS_TEST_TMPDIR/cmd_setup_called_shared"
	cmd_setup() { touch "$sentinel"; }

	ensure_runtime_dirs

	[ ! -f "$sentinel" ]
}

# ── cmd_setup: shared mode ────────────────────────────────────────────────────

@test "cmd_setup: shared mode (sentinel present) — CONTAINER_ENGRAM not created, shared note printed" {
	setup_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/engram-shared"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	rm -rf "$CONTAINER_ENGRAM"

	run cmd_setup
	[ ! -d "$CONTAINER_ENGRAM" ]
	[[ "$output" == *"shared mode — host ~/.engram used directly"* ]]
}

# ── cmd_status: 4-state (including shared and downgraded) ────────────────────

@test "cmd_status: shared mode — output contains 'shared (~/.engram)'" {
	setup_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/engram-shared"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	image_exists() { return 1; }

	run cmd_status
	[[ "$output" == *"shared (~/.engram)"* ]]
}

@test "cmd_status: sentinel + WSL2 + no force — output contains downgrade string" {
	setup_engram_on_path

	# WSL2 seams
	local wsl2_fixture="$BATS_TEST_TMPDIR/osrelease-wsl2-status-$$"
	printf '6.6.87.2-microsoft-standard-WSL2\n' >"$wsl2_fixture"
	export OSRELEASE_FILE="$wsl2_fixture"
	local stub_dir="$BATS_TEST_TMPDIR/uname-linux-status-$$"
	mkdir -p "$stub_dir"
	printf '#!/usr/bin/env bash\necho "Linux"\n' >"$stub_dir/uname"
	chmod +x "$stub_dir/uname"
	export UNAME="$stub_dir/uname"

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/engram-shared"
	unset DRYDOCK_ENGRAM_SHARED

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	image_exists() { return 1; }

	run cmd_status
	[[ "$output" == *"shared requested → forced isolated"* ]]
}

@test "cmd_status: sentinel + WSL2 + DRYDOCK_ENGRAM_SHARED=force — output contains 'shared (~/.engram)'" {
	setup_engram_on_path

	local wsl2_fixture="$BATS_TEST_TMPDIR/osrelease-wsl2-force-status-$$"
	printf '6.6.87.2-microsoft-standard-WSL2\n' >"$wsl2_fixture"
	export OSRELEASE_FILE="$wsl2_fixture"
	local stub_dir="$BATS_TEST_TMPDIR/uname-linux-force-status-$$"
	mkdir -p "$stub_dir"
	printf '#!/usr/bin/env bash\necho "Linux"\n' >"$stub_dir/uname"
	chmod +x "$stub_dir/uname"
	export UNAME="$stub_dir/uname"

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	mkdir -p "$HOME/.config/drydock"
	touch "$HOME/.config/drydock/engram-shared"
	export DRYDOCK_ENGRAM_SHARED=force

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	image_exists() { return 1; }

	run cmd_status
	[[ "$output" == *"shared (~/.engram)"* ]]
	unset DRYDOCK_ENGRAM_SHARED
}

# ── PROJECT_NAME consumer propagation via cmd_run/cmd_shell (REQ-3, S3.3–S3.4) ─
# These tests live in lib_commands.bats because cmd_run/cmd_shell require
# commands.sh to be sourced. (S3.1–S3.2 live in lib_compose.bats.)

@test "cmd_run: S3.3 — dotted project dir → container name is drydock-sideralith-com" {
	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	setup_no_engram_on_path
	setup_plain_linux_seams

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	ensure_prereqs() { :; }
	ensure_runtime_dirs() { :; }
	ensure_image() { :; }
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	# Create a project dir whose basename is exactly "sideralith.com"
	local parent_dir="$BATS_TEST_TMPDIR/s33-parent"
	local project_dir="$parent_dir/sideralith.com"
	mkdir -p "$project_dir"

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls-s33.log"
	touch "$DOCKER_CALL_LOG"

	# cmd_run does exec so use a no-op replacement for docker compose run
	# We capture the rm call and the compose call without actually exec-ing
	# Override exec via a helper that records and returns instead of replacing process
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	run cmd_run "$project_dir"

	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"--name drydock-sideralith-com"* ]]
}

@test "cmd_shell: S3.4 — dotted project dir → container name is drydock-sideralith-com-shell" {
	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	setup_no_engram_on_path
	setup_plain_linux_seams

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	ensure_prereqs() { :; }
	ensure_runtime_dirs() { :; }
	ensure_image() { :; }
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	local parent_dir="$BATS_TEST_TMPDIR/s34-parent"
	local project_dir="$parent_dir/sideralith.com"
	mkdir -p "$project_dir"

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls-s34.log"
	touch "$DOCKER_CALL_LOG"

	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	run cmd_shell "$project_dir"

	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"--name drydock-sideralith-com-shell"* ]]
}

# ── is_container_running unit tests (REQ-5, S5.1–S5.4) ───────────────────────

# Shared helper: setup sources and DOCKER seam for is_container_running tests.
_setup_icr() {
	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	setup_no_engram_on_path
	setup_plain_linux_seams
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-icr-$$.log"
	touch "$DOCKER_CALL_LOG"
}

@test "is_container_running: S5.1 — inspect returns 'true' → exits 0" {
	_setup_icr
	export MOCK_DOCKER_INSPECT_OUTPUT=true
	export MOCK_DOCKER_EXIT=0
	run is_container_running "drydock-foo"
	[ "$status" -eq 0 ]
}

@test "is_container_running: S5.2 — inspect returns 'false' (stopped) → exits non-zero" {
	_setup_icr
	export MOCK_DOCKER_INSPECT_OUTPUT=false
	export MOCK_DOCKER_EXIT=0
	run is_container_running "drydock-foo"
	[ "$status" -ne 0 ]
}

@test "is_container_running: S5.3 — inspect exits non-zero (absent) → exits non-zero" {
	_setup_icr
	unset MOCK_DOCKER_INSPECT_OUTPUT
	export MOCK_DOCKER_EXIT=1
	run is_container_running "drydock-foo"
	[ "$status" -ne 0 ]
}

@test "is_container_running: S5.4 — exact name forwarded to docker inspect, false output → exits non-zero" {
	_setup_icr
	# Verifies is_container_running passes the exact name argument through to docker inspect.
	export MOCK_DOCKER_INSPECT_OUTPUT=false
	export MOCK_DOCKER_EXIT=0
	run is_container_running "drydock-foo-shell"
	[ "$status" -ne 0 ]
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"drydock-foo-shell"* ]]
}

# ── mock-docker helper extension (REQ-10, S10.1–S10.2) ───────────────────────
# These tests invoke mock-docker directly (not via is_container_running) to
# prove the per-subcommand stdout extension is correct in isolation.

@test "mock-docker: S10.1 — MOCK_DOCKER_INSPECT_OUTPUT unset → logs to DOCKER_CALL_LOG, no stdout, exits MOCK_DOCKER_EXIT" {
	local log="$BATS_TEST_TMPDIR/mock-s101-$$.log"
	touch "$log"
	unset MOCK_DOCKER_INSPECT_OUTPUT
	DOCKER_CALL_LOG="$log" MOCK_DOCKER_EXIT=0 \
		run "$DRYDOCK_HOME/test/helpers/mock-docker" inspect --format '{{.State.Running}}' drydock-foo
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	grep -q "inspect --format" "$log"
}

@test "mock-docker: S10.2 — MOCK_DOCKER_INSPECT_OUTPUT=true → prints 'true' on stdout" {
	local log="$BATS_TEST_TMPDIR/mock-s102-$$.log"
	touch "$log"
	DOCKER_CALL_LOG="$log" MOCK_DOCKER_EXIT=0 MOCK_DOCKER_INSPECT_OUTPUT=true \
		run "$DRYDOCK_HOME/test/helpers/mock-docker" inspect --format '{{.State.Running}}' drydock-foo
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

# ── cmd_run running-container pre-check (REQ-6, S6.1–S6.2) ──────────────────

_setup_cmd_conflict() {
	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	setup_no_engram_on_path
	setup_plain_linux_seams
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
	ensure_runtime_dirs() { :; }
	ensure_image() { :; }
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-conflict-$$.log"
	touch "$DOCKER_CALL_LOG"
	# Stub exec so we can run cmd_run/cmd_shell without replacing the process.
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }
}

@test "cmd_run: S6.1 — running container → diagnostic on stderr, no compose run, exits non-zero" {
	_setup_cmd_conflict
	export MOCK_DOCKER_INSPECT_OUTPUT=true
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/s61/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[ "$status" -ne 0 ]
	[[ "$output" == *"running"* ]]
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" != *"compose"* ]] || [[ "$log" != *"run --rm"* ]]
}

@test "cmd_run: S6.2 — no running container → no diagnostic, compose run proceeds" {
	_setup_cmd_conflict
	export MOCK_DOCKER_INSPECT_OUTPUT=false
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/s62/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[[ "$output" != *"already running"* ]]
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"run --rm --name drydock-foo"* ]]
}

# ── cmd_shell running-container pre-check (REQ-7, S7.1–S7.2) ─────────────────

@test "cmd_shell: S7.1 — running shell container → diagnostic on stderr, exits non-zero" {
	_setup_cmd_conflict
	export MOCK_DOCKER_INSPECT_OUTPUT=true
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/s71/foo"
	mkdir -p "$project_dir"
	run cmd_shell "$project_dir"
	[ "$status" -ne 0 ]
	[[ "$output" == *"running"* ]]
}

@test "cmd_shell: S7.2 — drydock-foo running but drydock-foo-shell absent → NO diagnostic, shell proceeds" {
	_setup_cmd_conflict
	# Set inspect to return 'false' (stopped/absent) — this simulates the shell container absent.
	# The main container's running state is irrelevant since cmd_shell checks drydock-foo-shell.
	export MOCK_DOCKER_INSPECT_OUTPUT=false
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/s72/foo"
	mkdir -p "$project_dir"
	run cmd_shell "$project_dir"
	[ "$status" -eq 0 ]
	[[ "$output" != *"already running"* ]]
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"--name drydock-foo-shell"* ]]
}

# ── diagnostic content (REQ-8, S8.1–S8.5) ────────────────────────────────────

@test "cmd_run: S8.1 — conflict diagnostic contains literal container name" {
	_setup_cmd_conflict
	export MOCK_DOCKER_INSPECT_OUTPUT=true
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/s81/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[[ "$output" == *"drydock-foo"* ]]
}

@test "cmd_run: S8.2 — conflict diagnostic contains word 'running'" {
	_setup_cmd_conflict
	export MOCK_DOCKER_INSPECT_OUTPUT=true
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/s82/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[[ "$output" == *"running"* ]]
}

@test "cmd_run: S8.3 — conflict diagnostic contains exec command" {
	_setup_cmd_conflict
	export MOCK_DOCKER_INSPECT_OUTPUT=true
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/s83/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[[ "$output" == *"docker exec -it drydock-foo bash"* ]]
}

@test "cmd_run: S8.4 — conflict diagnostic contains stop command" {
	_setup_cmd_conflict
	export MOCK_DOCKER_INSPECT_OUTPUT=true
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/s84/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[[ "$output" == *"docker stop drydock-foo"* ]]
}

@test "cmd_run: S8.5 — conflict diagnostic contains collision-rename hint" {
	_setup_cmd_conflict
	export MOCK_DOCKER_INSPECT_OUTPUT=true
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/s85/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[[ "$output" == *"rename"* ]]
}

# ── regression guard: stopped containers still pre-cleaned (REQ-9, S9.1–S9.2) ─

@test "cmd_run: S9.1 — stopped container → rm issued, compose run proceeds, no diagnostic" {
	_setup_cmd_conflict
	# stopped: inspect returns 'false', exit 0 → is_container_running returns non-zero
	export MOCK_DOCKER_INSPECT_OUTPUT=false
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/s91/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[ "$status" -eq 0 ]
	[[ "$output" != *"already running"* ]]
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"rm drydock-foo"* ]]
	[[ "$log" == *"run --rm --name drydock-foo"* ]]
}

@test "cmd_run: S9.2 — no container at all → proceeds normally, no diagnostic" {
	_setup_cmd_conflict
	unset MOCK_DOCKER_INSPECT_OUTPUT
	export MOCK_DOCKER_EXIT=1
	local project_dir="$BATS_TEST_TMPDIR/s92/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[ "$status" -eq 0 ]
	[[ "$output" != *"already running"* ]]
}

# ── cmd_doctor: managed-settings policy line ─────────────────────────────────
# G-1: doctor output must report the drydock managed-settings policy deny count.
# G-2: the project settings.json line must NOT present its deny count as the
#      security indicator — it is project customization, not the protection.

@test "cmd_doctor: reports managed-settings policy deny count from templates/managed-settings.d/" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
	ensure_image() { :; }
	image_exists() { return 1; }

	# Run doctor from a tmpdir with no .claude/ so we get the "missing" branch.
	local tmpdir
	tmpdir="$(mktemp -d)"
	cd "$tmpdir"

	run cmd_doctor
	[ "$status" -eq 0 ]

	# G-1: output must mention the managed-settings layer and a non-zero policy count.
	[[ "$output" == *"managed-settings"* ]]
	[[ "$output" =~ [1-9][0-9]*[[:space:]]*deny ]] || [[ "$output" =~ deny[[:space:]]*rule ]]

	cd - >/dev/null
	rm -rf "$tmpdir"
}

