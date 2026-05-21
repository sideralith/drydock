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
	[[ "$output" == *"not detected"* ]]
	[[ "$output" == *"opt-in"* ]]
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
	# New layout puts "isolated" and "~/.engram-container" in separate columns.
	[[ "$output" == *"isolated"* ]]
	[[ "$output" == *"~/.engram-container"* ]]
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

# ── cmd_sync: purge .credentials.json from container on every sync ───────────

@test "cmd_sync: purges .credentials.json from container even when pre-existing" {
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

	# Pre-create container dir with a stale credentials file (simulates a user
	# who synced before the --exclude was added, leaving a token behind).
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"
	touch "$CONTAINER_CLAUDE/.credentials.json"

	run cmd_sync
	[ "$status" -eq 0 ]
	[ ! -f "$CONTAINER_CLAUDE/.credentials.json" ]
}

# ── cmd_setup: purge .credentials.json on the upgrade (else) path ────────────

@test "cmd_setup: purges .credentials.json when CONTAINER_CLAUDE already exists (upgrade path)" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	# Pre-create CONTAINER_CLAUDE so the else branch runs (upgrade path),
	# and plant a stale credentials file inside it.
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE/.credentials.json"

	run cmd_setup
	[ "$status" -eq 0 ]
	[ ! -f "$CONTAINER_CLAUDE/.credentials.json" ]
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

@test "cmd_run: S3.3 — dotted project dir → container name is drydock-sideralith-com-<disc>" {
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
	ensure_synced() { :; }
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	# Pin discriminator so container name is deterministic.
	_fixed_disc_s33() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc_s33

	# Create a project dir whose basename is exactly "sideralith.com"
	local parent_dir="$BATS_TEST_TMPDIR/s33-parent"
	local project_dir="$parent_dir/sideralith.com"
	mkdir -p "$project_dir"

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls-s33.log"
	touch "$DOCKER_CALL_LOG"

	# cmd_run does exec so use a no-op replacement for docker compose run.
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	run cmd_run "$project_dir"

	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"--name drydock-sideralith-com-test"* ]]
}

@test "cmd_shell: S3.4 — dotted project dir → container name is drydock-sideralith-com-<disc>-shell" {
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
	ensure_synced() { :; }
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	_fixed_disc_s34() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc_s34

	local parent_dir="$BATS_TEST_TMPDIR/s34-parent"
	local project_dir="$parent_dir/sideralith.com"
	mkdir -p "$project_dir"

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls-s34.log"
	touch "$DOCKER_CALL_LOG"

	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	run cmd_shell "$project_dir"

	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"--name drydock-sideralith-com-test-shell"* ]]
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

# ── cmd_run / cmd_shell: concurrent-session contract (v0.2.0 Wire-in) ─────────
# R4 (no-kill): drydock run and shell NEVER stop, kill, or reuse a running
# container. Concurrent invocations each get a unique discriminator-suffixed
# name from export_compose_env's collision retry. These tests verify the v0.2.0
# behavior. S6.x–S9.x (v0.1.x "already running" guard) are retired because the
# guard is replaced by the discriminator: every invocation gets its own name.

_setup_cmd_concurrent() {
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
	ensure_synced() { :; }
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"
	_fixed_disc_cc() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc_cc
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-concurrent-$$.log"
	touch "$DOCKER_CALL_LOG"
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }
}

@test "cmd_run: concurrent invocation always proceeds — no 'already running' error" {
	_setup_cmd_concurrent
	# Even with MOCK_DOCKER_INSPECT_OUTPUT=true (container exists), cmd_run
	# should NOT error — the discriminator ensures a unique name is used.
	export MOCK_DOCKER_INSPECT_OUTPUT=true
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/cc-run/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[ "$status" -eq 0 ]
	[[ "$output" != *"already running"* ]]
}

@test "cmd_shell: concurrent invocation always proceeds — no 'already running' error" {
	_setup_cmd_concurrent
	export MOCK_DOCKER_INSPECT_OUTPUT=true
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/cc-shell/foo"
	mkdir -p "$project_dir"
	run cmd_shell "$project_dir"
	[ "$status" -eq 0 ]
	[[ "$output" != *"already running"* ]]
}

@test "cmd_run: compose run receives correct discriminator-suffixed --name" {
	_setup_cmd_concurrent
	export MOCK_DOCKER_EXIT=0
	local project_dir="$BATS_TEST_TMPDIR/cc-name/foo"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"--name drydock-foo-test"* ]]
}

# ── auto-sync: Phase 6 — parity guard: prune list == rsync exclude list ───────
# Structural test: every path-based entry in ensure_synced's find prune set
# must appear as a matching --exclude entry in cmd_sync, and vice versa.
# This prevents silent drift between the two lists (a pruned-but-not-excluded
# path causes unnecessary Docker cold-starts on the happy path).
#
# Approach: grep the source file for the two lists, normalize to a canonical
# form, and compare. The engram conditional entry is verified structurally in
# the next test ("parity: engram conditional entry matches between cmd_sync and ensure_synced").

@test "parity: ensure_synced prune paths match cmd_sync rsync excludes" {
	local src="$DRYDOCK_HOME/lib/commands.sh"

	# Scope each extraction to its own function body to prevent unrelated
	# rsync/find calls elsewhere in the file from masking real drift.
	local cmd_sync_body ensure_synced_body
	cmd_sync_body=$(sed -n '/^cmd_sync()/,/^}/p' "$src")
	ensure_synced_body=$(sed -n '/^ensure_synced()/,/^}/p' "$src")

	# Strip comment lines from both bodies BEFORE applying the extraction regexes.
	# A doc comment that contains an example -path '*/sessions' or --exclude='foo/'
	# pattern would otherwise inject a phantom entry into the extracted list and
	# cause a spurious parity failure.  grep -v '^[[:space:]]*#' drops any line
	# whose first non-whitespace character is '#'.
	cmd_sync_body=$(echo "$cmd_sync_body" | grep -v '^[[:space:]]*#')
	ensure_synced_body=$(echo "$ensure_synced_body" | grep -v '^[[:space:]]*#')

	# Extract cmd_sync --exclude entries (drop engram conditional and *.bak.pre-dockerized/).
	# Normalise: strip trailing slash so dir-entries match prune entries.
	# bak.pre-dockerized/ is filtered because rsync needs TWO excludes for this case
	# (.bak.pre-dockerized without slash for files, .bak.pre-dockerized/ for dirs) but
	# find needs only ONE prune pattern (-name '*.bak.pre-dockerized').  The 1:2 asymmetry
	# is intentional; parity is verified by the name-only form matching the prune entry.
	local sync_excludes
	sync_excludes=$(echo "$cmd_sync_body" \
		| grep -oP "(?<=--exclude=')[^']+" \
		| grep -v "mcp/engram.json" \
		| grep -v "bak.pre-dockerized/" \
		| sed 's|/$||' \
		| sort)

	# Extract ensure_synced prune -path and -name entries (drop engram conditional).
	# -path '*/X' → X   -name 'Y' → Y  (no trailing slash in either case)
	local prune_entries
	prune_entries=$({ echo "$ensure_synced_body" \
		| grep -oP "(?<=-path '\*/)([^']+)(?=')" \
		| grep -v "mcp/engram.json"; \
		echo "$ensure_synced_body" \
		| grep -oP "(?<=-name ')([^']+)(?=')" \
		| grep -v "mcp/engram.json"; } | sort)

	# Both lists must be non-empty and identical.
	[ -n "$sync_excludes" ]
	[ -n "$prune_entries" ]
	[ "$sync_excludes" = "$prune_entries" ]

	# Parity guard: assert minimum entry count so a partial regex match can't
	# pass vacuously by returning a smaller-but-equal subset of both lists.
	# Hard-coded minimum reflects entries as of the time this guard was added;
	# adding new excludes/prune entries is fine — this only fails if entries
	# are silently lost (regex breakage, format change, etc.).
	local sync_count prune_count
	sync_count=$(echo "$sync_excludes" | wc -l)
	prune_count=$(echo "$prune_entries" | wc -l)
	[ "$sync_count" -ge 20 ]
	[ "$prune_count" -ge 20 ]
}

@test "parity: engram conditional entry matches between cmd_sync and ensure_synced" {
	local src="$DRYDOCK_HOME/lib/commands.sh"

	# Scope each extraction to its own function body, consistent with the
	# main parity test above.
	local cmd_sync_body ensure_synced_body
	cmd_sync_body=$(sed -n '/^cmd_sync()/,/^}/p' "$src")
	ensure_synced_body=$(sed -n '/^ensure_synced()/,/^}/p' "$src")

	# Extract the bare path from cmd_sync's _engram_exclude assignment.
	# Matches: _engram_exclude="--exclude=mcp/engram.json"
	local sync_engram_path
	sync_engram_path=$(echo "$cmd_sync_body" \
		| grep -oP '(?<=--exclude=)mcp/engram\.json' \
		| head -1)

	# Extract the bare path from ensure_synced's engram_prune construction.
	# Matches: engram_prune=(-o -path '*/mcp/engram.json')
	local prune_engram_path
	prune_engram_path=$(echo "$ensure_synced_body" \
		| grep -oP '(?<=-path \x27\*/)mcp/engram\.json(?=\x27)' \
		| head -1)

	# Both must resolve to the same bare path.
	[ -n "$sync_engram_path" ]
	[ -n "$prune_engram_path" ]
	[ "$sync_engram_path" = "$prune_engram_path" ]
}

# ── auto-sync: Phase 5 — call sites: cmd_run and cmd_shell ───────────────────

@test "cmd_run: calls ensure_synced before export_compose_env" {
	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	ensure_prereqs() { :; }
	ensure_runtime_dirs() { :; }
	ensure_image() { :; }
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	local seq_log="$BATS_TEST_TMPDIR/seq-run-$$"
	ensure_synced() { echo "ensure_synced" >>"$seq_log"; }
	export_compose_env() { echo "export_compose_env" >>"$seq_log"; }

	local project_dir="$BATS_TEST_TMPDIR/proj-run-$$"
	mkdir -p "$project_dir"

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-run-sync-$$.log"
	touch "$DOCKER_CALL_LOG"
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	run cmd_run "$project_dir"

	[ -f "$seq_log" ]
	[ "$(head -1 "$seq_log")" = "ensure_synced" ]
}

@test "cmd_shell: calls ensure_synced before export_compose_env" {
	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	ensure_prereqs() { :; }
	ensure_runtime_dirs() { :; }
	ensure_image() { :; }
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	local seq_log="$BATS_TEST_TMPDIR/seq-shell-$$"
	ensure_synced() { echo "ensure_synced" >>"$seq_log"; }
	export_compose_env() { echo "export_compose_env" >>"$seq_log"; }

	local project_dir="$BATS_TEST_TMPDIR/proj-shell-$$"
	mkdir -p "$project_dir"

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-shell-sync-$$.log"
	touch "$DOCKER_CALL_LOG"
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	run cmd_shell "$project_dir"

	[ -f "$seq_log" ]
	[ "$(head -1 "$seq_log")" = "ensure_synced" ]
}

# ── auto-sync: Phase 4 — ensure_synced helper ────────────────────────────────
# Helper: build fake-HOME tree suitable for ensure_synced mtime tests.
# Creates HOST_CLAUDE, HOST_CLAUDE_JSON, and a minimal CONTAINER_CLAUDE.
_setup_ensure_synced() {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-es-$$"
	mkdir -p "$fakehome/.claude"
	touch "$fakehome/.claude.json"
	export HOME="$fakehome"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
	ensure_image() { :; }
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"
}

@test "ensure_synced: DRYDOCK_SKIP_AUTOSYNC=1 — cmd_sync NOT called even with stale marker" {
	_setup_ensure_synced
	# Stub engram_usable to avoid executing uname from /tmp (noexec on WSL2 host).
	engram_usable() { return 1; }

	local sentinel="$BATS_TEST_TMPDIR/sync-called-skip-$$"
	cmd_sync() { touch "$sentinel"; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	# Create stale marker and a newer file in HOST_CLAUDE
	touch -d '@1000000000' "$marker"
	mkdir -p "$HOST_CLAUDE/hooks"
	touch -d '@2000000000' "$HOST_CLAUDE/hooks/test.sh"

	export DRYDOCK_SKIP_AUTOSYNC=1
	ensure_synced
	unset DRYDOCK_SKIP_AUTOSYNC

	[ ! -f "$sentinel" ]
}

@test "ensure_synced: absent marker — cmd_sync called" {
	_setup_ensure_synced
	engram_usable() { return 1; }

	local sentinel="$BATS_TEST_TMPDIR/sync-called-absent-$$"
	cmd_sync() { touch "$sentinel"; }

	# Ensure marker does not exist
	rm -f "$CONTAINER_CLAUDE/.drydock-last-sync"

	ensure_synced

	[ -f "$sentinel" ]
}

@test "ensure_synced: stale dir — newer file in HOST_CLAUDE triggers cmd_sync" {
	_setup_ensure_synced
	engram_usable() { return 1; }

	local sentinel="$BATS_TEST_TMPDIR/sync-called-stale-dir-$$"
	cmd_sync() { touch "$sentinel"; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	touch -d '@1000000000' "$marker"
	mkdir -p "$HOST_CLAUDE/hooks"
	touch -d '@2000000000' "$HOST_CLAUDE/hooks/test.sh"

	ensure_synced

	[ -f "$sentinel" ]
}

@test "ensure_synced: stale JSON — newer HOST_CLAUDE_JSON triggers cmd_sync" {
	_setup_ensure_synced
	engram_usable() { return 1; }

	local sentinel="$BATS_TEST_TMPDIR/sync-called-stale-json-$$"
	cmd_sync() { touch "$sentinel"; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	touch -d '@1000000000' "$marker"
	# HOST_CLAUDE has no newer files, but HOST_CLAUDE_JSON is newer
	touch -d '@2000000000' "$HOST_CLAUDE_JSON"

	ensure_synced

	[ -f "$sentinel" ]
}

@test "ensure_synced: fresh-pruned (sessions) — only sessions file newer, cmd_sync NOT called" {
	_setup_ensure_synced
	engram_usable() { return 1; }

	local sentinel="$BATS_TEST_TMPDIR/sync-called-sessions-$$"
	cmd_sync() { touch "$sentinel"; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	touch -d '@1000000000' "$marker"
	# Only a sessions file is newer — should be pruned (AS-2: state-directory exclusion)
	mkdir -p "$HOST_CLAUDE/sessions"
	touch -d '@2000000000' "$HOST_CLAUDE/sessions/some-session.jsonl"
	touch -d '@500000000' "$HOST_CLAUDE_JSON"

	ensure_synced

	[ ! -f "$sentinel" ]
}

@test "ensure_synced: fresh-pruned (cache) — only cache file newer, cmd_sync NOT called" {
	_setup_ensure_synced
	engram_usable() { return 1; }

	local sentinel="$BATS_TEST_TMPDIR/sync-called-fresh-$$"
	cmd_sync() { touch "$sentinel"; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	touch -d '@1000000000' "$marker"
	# Only a cache file is newer — should be pruned
	mkdir -p "$HOST_CLAUDE/cache"
	touch -d '@2000000000' "$HOST_CLAUDE/cache/x"
	# HOST_CLAUDE_JSON older than marker
	touch -d '@500000000' "$HOST_CLAUDE_JSON"

	ensure_synced

	[ ! -f "$sentinel" ]
}

@test "ensure_synced: fresh-pruned (mcp/engram.json) — engram_usable=false, engram.json newer, cmd_sync NOT called" {
	_setup_ensure_synced
	# Stub engram_usable to return false (no engram) → mcp/engram.json gets pruned.
	engram_usable() { return 1; }

	local sentinel="$BATS_TEST_TMPDIR/sync-called-engram-excl-$$"
	cmd_sync() { touch "$sentinel"; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	touch -d '@1000000000' "$marker"
	# mcp/engram.json is newer but should be pruned when engram not usable
	mkdir -p "$HOST_CLAUDE/mcp"
	touch -d '@2000000000' "$HOST_CLAUDE/mcp/engram.json"
	touch -d '@500000000' "$HOST_CLAUDE_JSON"

	ensure_synced

	[ ! -f "$sentinel" ]
}

@test "ensure_synced: stale (mcp/engram.json) — engram_usable=true, engram.json newer, cmd_sync IS called" {
	_setup_ensure_synced
	# Stub engram_usable to return true (engram active) → mcp/engram.json NOT pruned.
	engram_usable() { return 0; }

	local sentinel="$BATS_TEST_TMPDIR/sync-called-engram-incl-$$"
	cmd_sync() { touch "$sentinel"; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	touch -d '@1000000000' "$marker"
	# mcp/engram.json is newer; when engram is usable, it should NOT be pruned
	mkdir -p "$HOST_CLAUDE/mcp"
	touch -d '@2000000000' "$HOST_CLAUDE/mcp/engram.json"
	touch -d '@500000000' "$HOST_CLAUDE_JSON"

	ensure_synced

	[ -f "$sentinel" ]
}

# ── ensure_synced: non-fatal cmd_sync failure (FIX 3) ────────────────────────

@test "ensure_synced: cmd_sync fails — ensure_synced returns 0 (non-fatal)" {
	_setup_ensure_synced
	engram_usable() { return 1; }

	# cmd_sync always fails.
	cmd_sync() { return 1; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	touch -d '@1000000000' "$marker"
	mkdir -p "$HOST_CLAUDE/hooks"
	touch -d '@2000000000' "$HOST_CLAUDE/hooks/test.sh"

	run ensure_synced
	[ "$status" -eq 0 ]
}

@test "ensure_synced: absent marker + cmd_sync fails — ensure_synced returns 0 (non-fatal)" {
	_setup_ensure_synced
	engram_usable() { return 1; }

	# cmd_sync always fails.
	cmd_sync() { return 1; }

	rm -f "$CONTAINER_CLAUDE/.drydock-last-sync"

	run ensure_synced
	[ "$status" -eq 0 ]
}

# ── ensure_synced: absent HOST_CLAUDE_JSON (FIX 4) ───────────────────────────

@test "ensure_synced: HOST_CLAUDE_JSON absent — newer file in HOST_CLAUDE still triggers cmd_sync" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-es-fix4-$$"
	mkdir -p "$fakehome/.claude"
	# Intentionally NO .claude.json — HOST_CLAUDE_JSON will not exist.
	export HOME="$fakehome"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
	ensure_image() { :; }
	engram_usable() { return 1; }
	mkdir -p "$CONTAINER_CLAUDE"
	touch "$CONTAINER_CLAUDE_JSON"

	local sentinel="$BATS_TEST_TMPDIR/sync-called-no-json-$$"
	cmd_sync() { touch "$sentinel"; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	touch -d '@1000000000' "$marker"
	mkdir -p "$HOST_CLAUDE/hooks"
	touch -d '@2000000000' "$HOST_CLAUDE/hooks/test.sh"

	# HOST_CLAUDE_JSON does not exist — find must not fail, sync must still trigger.
	[ ! -f "$HOST_CLAUDE_JSON" ]

	# Call directly (not via `run`): ensure_synced is not expected to exit non-zero,
	# and we need the sentinel check to reflect the function's actual behavior rather
	# than an exit-code wrapper.  The probe_paths guard prevents find from being
	# called with a missing path at all, which is the cleanest defense regardless
	# of grep's exit-code masking behavior.
	ensure_synced

	[ -f "$sentinel" ]
}

# ── ensure_synced: find exits non-zero but prints a match (decoupling) ───────

@test "ensure_synced: find exits non-zero but prints a match — cmd_sync still called" {
	_setup_ensure_synced
	engram_usable() { return 1; }

	local sentinel="$BATS_TEST_TMPDIR/sync-called-find-nonzero-$$"
	cmd_sync() { touch "$sentinel"; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	touch -d '@1000000000' "$marker"

	# Stub find: print a path (simulating a real match) then exit 1
	# (simulating a permission error encountered after the match was printed).
	# The old | grep -q . pipeline under pipefail would propagate find's exit 1
	# and make the if-condition false, silently skipping the sync.
	# The new captured-output approach ignores find's exit code, so cmd_sync
	# must still be called whenever find printed anything.
	find() { printf '%s/hooks/test.sh\n' "$HOST_CLAUDE"; return 1; }

	ensure_synced

	[ -f "$sentinel" ]
}

@test "ensure_synced: find exits non-zero and prints nothing — cmd_sync NOT called, warn emitted" {
	_setup_ensure_synced
	engram_usable() { return 1; }

	local sentinel="$BATS_TEST_TMPDIR/sync-called-find-fail-noout-$$"
	cmd_sync() { touch "$sentinel"; }

	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	touch -d '@1000000000' "$marker"

	# Stub find: print nothing and exit non-zero (total probe failure —
	# e.g. HOST_CLAUDE itself is unreadable so traversal cannot even start).
	# cmd_sync must NOT be called (no match was found), but a warn must be
	# emitted so the skipped sync is visible to the user.
	find() { return 1; }

	run ensure_synced

	[ ! -f "$sentinel" ]
	[[ "$output" == *"staleness probe failed"* ]]
}

# ── cmd_setup: .credentials.json exclusion (FIX 1) ──────────────────────────

@test "cmd_setup: .credentials.json absent from container copy after setup" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	# Plant .credentials.json in source ~/.claude/ to verify it gets removed.
	printf '{"token":"secret-oauth-token"}\n' >"$fakehome/.claude/.credentials.json"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	# Ensure fresh setup (no pre-existing container dir).
	rm -rf "$CONTAINER_CLAUDE"
	rm -f "$CONTAINER_CLAUDE_JSON"

	run cmd_setup
	[ "$status" -eq 0 ]
	[ ! -f "$CONTAINER_CLAUDE/.credentials.json" ]
}

# ── auto-sync: Phase 3 — marker in cmd_setup ─────────────────────────────────

@test "cmd_setup: creates .drydock-last-sync marker after successful setup" {
	setup_no_engram_on_path
	setup_plain_linux_seams

	local fakehome
	fakehome="$(setup_fake_home)"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	# Ensure CONTAINER_CLAUDE does not exist so cmd_setup creates it.
	rm -rf "$CONTAINER_CLAUDE"
	rm -f "$CONTAINER_CLAUDE_JSON"

	run cmd_setup
	[ "$status" -eq 0 ]
	[ -f "$CONTAINER_CLAUDE/.drydock-last-sync" ]
}

# ── auto-sync: Phase 2 — rsync excludes + marker in cmd_sync ─────────────────

@test "cmd_sync: rsync args include --exclude='.credentials.json'" {
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
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/sync-excl-$$.log"
	touch "$DOCKER_CALL_LOG"

	run cmd_sync
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"--exclude=.credentials.json"* ]]
}

@test "cmd_sync: rsync args include --exclude=themes/" {
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
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/sync-excl-themes-$$.log"
	touch "$DOCKER_CALL_LOG"

	run cmd_sync
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"--exclude=themes/"* ]]
}

@test "cmd_sync: rsync args include --exclude=.drydock-last-sync" {
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
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/sync-excl-marker-$$.log"
	touch "$DOCKER_CALL_LOG"

	run cmd_sync
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" == *"--exclude=.drydock-last-sync"* ]]
}

@test "cmd_sync: marker .drydock-last-sync created after successful sync" {
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
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/sync-marker-ok-$$.log"
	touch "$DOCKER_CALL_LOG"

	run cmd_sync
	[ "$status" -eq 0 ]
	[ -f "$CONTAINER_CLAUDE/.drydock-last-sync" ]
}

@test "cmd_sync: marker .drydock-last-sync NOT created when rsync fails" {
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
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/sync-marker-fail-$$.log"
	touch "$DOCKER_CALL_LOG"
	export MOCK_DOCKER_EXIT=1

	run cmd_sync
	[ "$status" -ne 0 ]
	[ ! -f "$CONTAINER_CLAUDE/.drydock-last-sync" ]
	unset MOCK_DOCKER_EXIT
}

# ── auto-sync: Phase 1 — DRYDOCK_SKIP_AUTOSYNC seam (lib/paths.sh) ──────────

@test "paths.sh: DRYDOCK_SKIP_AUTOSYNC defaults to '0' when unset" {
	unset DRYDOCK_SKIP_AUTOSYNC
	source "$DRYDOCK_HOME/lib/paths.sh"
	[ "$DRYDOCK_SKIP_AUTOSYNC" = "0" ]
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

# ── cmd_doctor: linked-siblings section ──────────────────────────────────────
# G-3: doctor must surface linked siblings for the current project (the same
#      data `drydock links` prints). Two cases: empty/missing list → "(none
#      linked)" hint; populated list → one line per entry with mode suffix.

@test "usage: help output contains expected sections + version + key commands" {
	# Smoke test for the help styling. Doesn't pin exact ANSI codes — just
	# verifies the new section structure rendered correctly under non-TTY
	# (plain text), and that all command names that bin/drydock dispatches on
	# appear in the help.
	source "$DRYDOCK_HOME/lib/common.sh"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	run usage
	[ "$status" -eq 0 ]
	# Title line
	[[ "$output" == *"drydock $DRYDOCK_VERSION"* ]]
	[[ "$output" == *"containerized Claude Code sandbox"* ]]
	# Section headers
	[[ "$output" == *"USAGE"* ]]
	[[ "$output" == *"COMMANDS"* ]]
	[[ "$output" == *"EXAMPLES"* ]]
	[[ "$output" == *"ENV"* ]]
	# A sampling of command names — failures here mean a dispatch target was
	# accidentally dropped from help.
	for _cmd in "run" "shell" "build" "sync" "status" "doctor" "setup" \
		"link" "unlink" "links" "version" "help"; do
		[[ "$output" == *"$_cmd"* ]] || {
			echo "missing command '$_cmd' in help output" >&2
			false
		}
	done
}

@test "cmd_doctor: linked-siblings section shows '(none linked)' when no list file exists" {
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

	local tmpdir
	tmpdir="$(mktemp -d "$BATS_TEST_TMPDIR/proj-XXXX")"
	cd "$tmpdir"

	run cmd_doctor
	[ "$status" -eq 0 ]
	[[ "$output" == *"LINKED SIBLINGS"* ]]
	[[ "$output" == *"(none linked)"* ]]

	cd - >/dev/null
	rm -rf "$tmpdir"
}

@test "cmd_doctor: env-flags section shows '(none — defaults active)' with no DRYDOCK_* set" {
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

	# Defensive unset — these may leak in from the developer shell.
	unset DRYDOCK_NO_HARDENING DRYDOCK_TMPFS_SIZE DRYDOCK_ENGRAM_SHARED DRYDOCK_SKIP_AUTOSYNC

	local tmpdir
	tmpdir="$(mktemp -d "$BATS_TEST_TMPDIR/proj-XXXX")"
	cd "$tmpdir"

	run cmd_doctor
	[ "$status" -eq 0 ]
	[[ "$output" == *"ENV FLAGS"* ]]
	[[ "$output" == *"(none — defaults active)"* ]]

	cd - >/dev/null
	rm -rf "$tmpdir"
}

@test "cmd_doctor: env-flags section surfaces DRYDOCK_NO_HARDENING when set" {
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

	unset DRYDOCK_TMPFS_SIZE DRYDOCK_ENGRAM_SHARED DRYDOCK_SKIP_AUTOSYNC
	export DRYDOCK_NO_HARDENING=1

	local tmpdir
	tmpdir="$(mktemp -d "$BATS_TEST_TMPDIR/proj-XXXX")"
	cd "$tmpdir"

	run cmd_doctor
	[ "$status" -eq 0 ]
	[[ "$output" == *"DRYDOCK_NO_HARDENING"* ]]
	[[ "$output" == *"=1"* ]]
	# Hardening overlay must be reported as DISABLED, not active.
	[[ "$output" == *"DISABLED"* ]]
	[[ "$output" != *"(none — defaults active)"* ]]

	unset DRYDOCK_NO_HARDENING
	cd - >/dev/null
	rm -rf "$tmpdir"
}

@test "cmd_doctor: compose-overlays section lists base + hardening by default" {
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

	unset DRYDOCK_NO_HARDENING

	local tmpdir
	tmpdir="$(mktemp -d "$BATS_TEST_TMPDIR/proj-XXXX")"
	cd "$tmpdir"

	run cmd_doctor
	[ "$status" -eq 0 ]
	[[ "$output" == *"COMPOSE OVERLAYS"* ]]
	[[ "$output" == *"docker-compose.yml"* ]]
	[[ "$output" == *"base"* ]]
	[[ "$output" == *"docker-compose.hardening.yml"* ]]

	cd - >/dev/null
	rm -rf "$tmpdir"
}

@test "cmd_doctor: active-sessions section shows '(none running)' when no docker container matches" {
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

	# Stub DOCKER seam to emit no rows.
	local stub_dir="$BATS_TEST_TMPDIR/docker-stub-empty-$$"
	mkdir -p "$stub_dir"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$stub_dir/docker"
	chmod +x "$stub_dir/docker"
	export DOCKER="$stub_dir/docker"

	local tmpdir
	tmpdir="$(mktemp -d "$BATS_TEST_TMPDIR/proj-XXXX")"
	cd "$tmpdir"

	run cmd_doctor
	[ "$status" -eq 0 ]
	[[ "$output" == *"ACTIVE SESSIONS"* ]]
	[[ "$output" == *"(none running)"* ]]

	cd - >/dev/null
	rm -rf "$tmpdir"
}

@test "cmd_doctor: linked-siblings section lists entries from the project's list file" {
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

	# Seed a list file at the path cmd_doctor will resolve via
	# _links_list_file → _current_project_name → sanitize(basename(pwd)).
	local proj_dir="$BATS_TEST_TMPDIR/myproj"
	mkdir -p "$proj_dir"
	mkdir -p "$fakehome/.config/drydock/links"
	printf '%s|%s|\n' "/host/path/sibling-a" "/workspace-siblings/sibling-a" \
		>"$fakehome/.config/drydock/links/myproj.list"
	printf '%s|%s|rw\n' "/host/path/sibling-b" "/workspace-siblings/sibling-b" \
		>>"$fakehome/.config/drydock/links/myproj.list"

	cd "$proj_dir"

	run cmd_doctor
	[ "$status" -eq 0 ]
	[[ "$output" == *"LINKED SIBLINGS"* ]]
	[[ "$output" == *"/host/path/sibling-a"* ]]
	[[ "$output" == *"/workspace-siblings/sibling-a"* ]]
	# Mode appears as the dim metadata suffix ("· ro" / "· rw") in the new layout.
	[[ "$output" == *"ro"* ]]
	[[ "$output" == *"/host/path/sibling-b"* ]]
	[[ "$output" == *"rw"* ]]
	# Empty-state hint must NOT appear when entries exist.
	[[ "$output" != *"(none linked)"* ]]

	cd - >/dev/null
	rm -rf "$proj_dir"
}

# ── cmd_run / cmd_shell name tests (concurrent-sessions, PR 2 Wire-in) ────────
# Task 2.6: verify cmd_run uses DRYDOCK_SESSION_NAME for --name, and cmd_shell
# appends -shell suffix. No existing container is killed or stopped (R4).
#
# Helper: set up a hermetic env for cmd_run/cmd_shell tests with disc stub.
# Sets CMD_NAME_TEST_PROJECT_DIR (global) rather than using $() to avoid the
# "functions defined in subshell don't persist to parent" trap.
_setup_cmd_name_test() {
	local fakehome="$BATS_TEST_TMPDIR/cmd-name-home-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"
	setup_no_engram_on_path
	setup_plain_linux_seams

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	# Stub ensure_* to prevent side effects.
	ensure_prereqs() { :; }
	ensure_runtime_dirs() { :; }
	ensure_image() { :; }
	ensure_synced() { :; }

	# Pin the discriminator to "abcd" for predictable assertions.
	_fixed_disc_name() { printf 'abcd'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc_name

	# DOCKER: returns empty for ps (no containers = no collisions).
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-name-$$.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	# Set global var instead of returning via $() to preserve function defs.
	CMD_NAME_TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/cmd-name-proj-$$"
	mkdir -p "$CMD_NAME_TEST_PROJECT_DIR"
}

@test "cmd_run: container --name uses DRYDOCK_SESSION_NAME (drydock-<proj>-<disc>)" {
	_setup_cmd_name_test
	# Override exec to capture the compose run args instead of replacing process.
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }
	run cmd_run "$CMD_NAME_TEST_PROJECT_DIR"
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	# The --name arg must be drydock-<project>-abcd (discriminator suffix).
	[[ "$log" == *"--name drydock-cmd-name-proj-"*"-abcd"* ]]
}

@test "cmd_shell: container --name uses DRYDOCK_SESSION_NAME with -shell suffix" {
	_setup_cmd_name_test
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }
	run cmd_shell "$CMD_NAME_TEST_PROJECT_DIR"
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	# The --name arg must be drydock-<project>-abcd-shell.
	[[ "$log" == *"--name drydock-cmd-name-proj-"*"-abcd-shell"* ]]
}

@test "cmd_run: does NOT stop or kill an existing container (R4 no-kill)" {
	_setup_cmd_name_test
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }
	run cmd_run "$CMD_NAME_TEST_PROJECT_DIR"
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	# No "stop" or "kill" subcommand must appear in docker call log.
	[[ "$log" != *" stop "* ]]
	[[ "$log" != *" kill "* ]]
}

@test "cmd_shell: does NOT stop or kill an existing container (R4 no-kill)" {
	_setup_cmd_name_test
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }
	run cmd_shell "$CMD_NAME_TEST_PROJECT_DIR"
	local log
	log="$(cat "$DOCKER_CALL_LOG")"
	[[ "$log" != *" stop "* ]]
	[[ "$log" != *" kill "* ]]
}

# ── pre_flight_notice (concurrent-sessions, PR 3 UX — Task 3.1 RED) ──────────
# R5: print a non-blocking informational notice when ≥1 same-project containers
# are running. Zero containers → silent. Exit code always 0.
# Tests cover count detection, zero-silence, -shell exclusion, and that both
# cmd_run and cmd_shell invoke the notice (via a spy stub in the integration
# smoke test).

# Helper: build a fake HOME + seam environment for pre_flight_notice unit tests.
# Sets PFN_TEST_PROJECT_DIR (global) and exports PROJECT_NAME.
_setup_preflight_test() {
	local fakehome="$BATS_TEST_TMPDIR/pfn-home-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"
	setup_no_engram_on_path
	setup_plain_linux_seams

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	PFN_TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/pfn-proj-$$"
	mkdir -p "$PFN_TEST_PROJECT_DIR"
	export PROJECT_NAME="myproject"

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-pfn-$$.log"
	touch "$DOCKER_CALL_LOG"
}

# Helper: create a DOCKER stub that returns $1 on stdout for "ps" subcommand.
_make_pfn_docker_stub() {
	local ps_output="$1"
	local stub_file="$BATS_TEST_TMPDIR/docker-pfn-stub-$$"
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

@test "pre_flight_notice: one existing session — prints notice with count 1" {
	_setup_preflight_test
	export DOCKER="$(_make_pfn_docker_stub "drydock-myproject-a1b2")"
	run pre_flight_notice
	[ "$status" -eq 0 ]
	[[ "$output" == *"1"* ]]
	[[ "$output" == *"myproject"* ]]
}

@test "pre_flight_notice: two existing sessions — prints notice with count 2" {
	_setup_preflight_test
	# ps output has two container names (newline-separated); embed literal newline in stub.
	local stub_file="$BATS_TEST_TMPDIR/docker-pfn-two-stub-$$"
	cat >"$stub_file" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${DOCKER_CALL_LOG:?}"
if [ "${1:-}" = "ps" ]; then
	printf 'drydock-myproject-a1b2\ndrydock-myproject-c3d4\n'
fi
exit 0
STUB
	chmod +x "$stub_file"
	export DOCKER="$stub_file"
	run pre_flight_notice
	[ "$status" -eq 0 ]
	[[ "$output" == *"2"* ]]
}

@test "pre_flight_notice: zero existing sessions — prints nothing" {
	_setup_preflight_test
	export DOCKER="$(_make_pfn_docker_stub "")"
	run pre_flight_notice
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "pre_flight_notice: -shell containers are NOT counted" {
	_setup_preflight_test
	# Only a -shell container exists; anchored regex must exclude it.
	export DOCKER="$(_make_pfn_docker_stub "drydock-myproject-a1b2-shell")"
	run pre_flight_notice
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "pre_flight_notice: exit code is 0 even when sessions exist" {
	_setup_preflight_test
	export DOCKER="$(_make_pfn_docker_stub "drydock-myproject-a1b2")"
	run pre_flight_notice
	[ "$status" -eq 0 ]
}

@test "pre_flight_notice: called from cmd_run path (R5 — notice fires in cmd_run)" {
	# This test verifies that cmd_run actually calls pre_flight_notice. We use a
	# spy stub that writes a sentinel to a log, then assert the sentinel appears.
	# Testing the notice content is covered by the direct unit tests above.
	local fakehome="$BATS_TEST_TMPDIR/pfn-run-home-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"
	setup_no_engram_on_path
	setup_plain_linux_seams

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	ensure_prereqs() { :; }
	ensure_runtime_dirs() { :; }
	ensure_image() { :; }
	ensure_synced() { :; }

	_fixed_disc_pfn_run() { printf 'cafe'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc_pfn_run

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-pfn-run-log-$$.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	# Override pre_flight_notice with a spy that outputs a sentinel.
	pre_flight_notice() { printf 'preflight-called\n'; }

	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	local project_dir="$BATS_TEST_TMPDIR/pfn-run-proj-$$"
	mkdir -p "$project_dir"
	run cmd_run "$project_dir"
	[ "$status" -eq 0 ]
	[[ "$output" == *"preflight-called"* ]]
}

@test "pre_flight_notice: called from cmd_shell path (R5 — notice fires in cmd_shell)" {
	# Same spy approach as above but for cmd_shell.
	local fakehome="$BATS_TEST_TMPDIR/pfn-shell-home-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"
	setup_no_engram_on_path
	setup_plain_linux_seams

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	ensure_prereqs() { :; }
	ensure_runtime_dirs() { :; }
	ensure_image() { :; }
	ensure_synced() { :; }

	_fixed_disc_pfn_shell() { printf 'babe'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc_pfn_shell

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-pfn-shell-log-$$.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	# Override pre_flight_notice with a spy that outputs a sentinel.
	pre_flight_notice() { printf 'preflight-called\n'; }

	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	local project_dir="$BATS_TEST_TMPDIR/pfn-shell-proj-$$"
	mkdir -p "$project_dir"
	run cmd_shell "$project_dir"
	[ "$status" -eq 0 ]
	[[ "$output" == *"preflight-called"* ]]
}

# ── integration smoke test (concurrent-sessions, PR 2 Wire-in — Task 2.8) ─────
# Asserts end-to-end call order for cmd_run with all seams stubbed:
# ensure_synced (skipped) → gc_orphan_session_dirs → discriminator → seed → pre_flight_notice → compose run
# Also asserts --name argument and no stop/kill.

@test "integration: cmd_run call order — gc → disc → seed → pre_flight_notice → compose run --name disc" {
	local fakehome="$BATS_TEST_TMPDIR/integ-home-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"
	setup_no_engram_on_path
	setup_plain_linux_seams

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	ensure_prereqs() { :; }
	ensure_runtime_dirs() { :; }
	ensure_image() { :; }
	# DRYDOCK_SKIP_AUTOSYNC=1 skips the actual sync; or stub ensure_synced directly.
	ensure_synced() { :; }

	# Call-order log for tracking function invocations.
	local call_order_log="$BATS_TEST_TMPDIR/call-order-$$.log"
	touch "$call_order_log"

	# Pin discriminator to "abcd" and track its call.
	_fixed_disc_integ() {
		printf 'gc-done disc-called seed-done\n' >> "$call_order_log"
		printf 'abcd'
	}
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc_integ

	# Wrap gc_orphan_session_dirs to log its call.
	gc_orphan_session_dirs() {
		printf 'gc-called\n' >> "$call_order_log"
	}

	# Wrap seed_session_config_dir to log its call.
	seed_session_config_dir() {
		printf 'seed-called\n' >> "$call_order_log"
	}

	# Wrap pre_flight_notice to log its call.
	pre_flight_notice() {
		printf 'preflight-called\n' >> "$call_order_log"
	}

	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-integ-$$.log"
	touch "$DOCKER_CALL_LOG"

	local project_dir="$BATS_TEST_TMPDIR/integ-proj-$$"
	mkdir -p "$project_dir"

	# Capture exec call instead of replacing process.
	exec() {
		printf 'compose-run-called\n' >> "$call_order_log"
		echo "$*" >> "$DOCKER_CALL_LOG"
		return 0
	}

	run cmd_run "$project_dir"
	[ "$status" -eq 0 ]

	local order
	order="$(cat "$call_order_log")"
	local compose_log
	compose_log="$(cat "$DOCKER_CALL_LOG")"

	# Verify gc was called before disc/seed.
	[[ "$order" == *"gc-called"* ]]
	[[ "$order" == *"seed-called"* ]]
	[[ "$order" == *"preflight-called"* ]]
	[[ "$order" == *"compose-run-called"* ]]

	# gc must appear before disc/seed in the log.
	local gc_pos disc_pos seed_pos compose_pos
	gc_pos=$(printf '%s' "$order" | grep -n "gc-called" | head -1 | cut -d: -f1)
	disc_pos=$(printf '%s' "$order" | grep -n "gc-done disc-called" | head -1 | cut -d: -f1)
	seed_pos=$(printf '%s' "$order" | grep -n "seed-called" | head -1 | cut -d: -f1)
	compose_pos=$(printf '%s' "$order" | grep -n "compose-run-called" | head -1 | cut -d: -f1)
	[ "$gc_pos" -lt "$disc_pos" ]
	[ "$disc_pos" -lt "$seed_pos" ]
	[ "$seed_pos" -lt "$compose_pos" ]

	# compose run must receive --name with discriminator suffix.
	[[ "$compose_log" == *"--name drydock-integ-proj-"*"-abcd"* ]]

	# No stop or kill in docker calls.
	[[ "$compose_log" != *" stop "* ]]
	[[ "$compose_log" != *" kill "* ]]
}

# ── _current_project_name ─────────────────────────────────────────────────────

@test "_current_project_name: returns sanitized basename of cwd" {
	local proj_dir="$BATS_TEST_TMPDIR/my-test Project"
	mkdir -p "$proj_dir"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	# Change into synthetic project dir for the pure-string transform
	(
		cd "$proj_dir"
		run _current_project_name
		[ "$status" -eq 0 ]
		[ "$output" = "my-test-project" ]
	)
}

@test "_current_project_name: does not require DRYDOCK_* env or running container" {
	local proj_dir="$BATS_TEST_TMPDIR/simple-proj"
	mkdir -p "$proj_dir"

	# Source without any DRYDOCK_ env or docker available
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	(
		cd "$proj_dir"
		run _current_project_name
		[ "$status" -eq 0 ]
		[ "$output" = "simple-proj" ]
	)
}

# ── _links_list_file ──────────────────────────────────────────────────────────

@test "_links_list_file: returns path under ~/.config/drydock/links/<project>.list" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-lf"
	mkdir -p "$fakehome"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	local proj_dir="$BATS_TEST_TMPDIR/my-project"
	mkdir -p "$proj_dir"

	(
		cd "$proj_dir"
		run _links_list_file
		[ "$status" -eq 0 ]
		[ "$output" = "$fakehome/.config/drydock/links/my-project.list" ]
	)
}

@test "_links_list_file: sanitizes special chars in project name" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-lf2"
	mkdir -p "$fakehome"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	# Use uppercase + underscores: sanitize lowercases but preserves underscores.
	local proj_dir="$BATS_TEST_TMPDIR/My_Cool_Project"
	mkdir -p "$proj_dir"

	(
		cd "$proj_dir"
		run _links_list_file
		[ "$status" -eq 0 ]
		# sanitize_project_name: uppercase → lowercase, underscores preserved
		[ "$output" = "$fakehome/.config/drydock/links/my_cool_project.list" ]
	)
}

# ── T1-RED: _sibling_deploy_key_path and _managed_ssh_config_path ─────────────

@test "_sibling_deploy_key_path: returns ~/.config/drydock/keys/<name>_deploy" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-sdkp"
	mkdir -p "$fakehome"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	run _sibling_deploy_key_path "mysibling"
	[ "$status" -eq 0 ]
	[ "$output" = "$fakehome/.config/drydock/keys/mysibling_deploy" ]
}

@test "_managed_ssh_config_path: returns ~/.config/drydock/ssh-config-<primary>" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-mscp"
	mkdir -p "$fakehome"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	run _managed_ssh_config_path "myprimary"
	[ "$status" -eq 0 ]
	[ "$output" = "$fakehome/.config/drydock/ssh-config-myprimary" ]
}

@test "_sibling_deploy_key_path: sanitized name with dashes preserved" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-sdkp2"
	mkdir -p "$fakehome"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"

	run _sibling_deploy_key_path "my-lib"
	[ "$status" -eq 0 ]
	[ "$output" = "$fakehome/.config/drydock/keys/my-lib_deploy" ]
}

# ── cmd_setup_token ───────────────────────────────────────────────────────────

# Helper: set up a fake HOME with the minimum structure and a fake claude binary.
# The fake-claude script exits 0 (simulates a successful interactive flow).
# The token is now supplied via stdin to drydock's paste prompt, not via stub stdout.
_setup_token_env() {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-token-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"

	# Fake claude binary: exits 0 (interactive flow succeeded); prints nothing to
	# stdout — the token arrives via drydock's IFS read paste prompt instead.
	local fake_bin="$BATS_TEST_TMPDIR/fake-claude-bin-$$"
	mkdir -p "$fake_bin"
	cat >"$fake_bin/fake-claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "$fake_bin/fake-claude"
	export CLAUDE_BIN="$fake_bin/fake-claude"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
}

@test "cmd_setup_token: happy path — file written at correct path, mode 0600, content equals token" {
	_setup_token_env
	# Token is supplied via stdin to drydock's paste prompt (Fix 1: paste-based flow).
	run cmd_setup_token <<< "sk-ant-oat-v1-A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8S9T0U1V2W3X4Y5Z6"
	[ "$status" -eq 0 ]
	local token_file="$HOME/.config/drydock/claude-oauth-token"
	[ -f "$token_file" ]
	local perms
	perms="$(stat -c '%a' "$token_file")"
	[ "$perms" = "600" ]
	local content
	content="$(cat "$token_file")"
	[ "$content" = "sk-ant-oat-v1-A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8S9T0U1V2W3X4Y5Z6" ]
}

@test "cmd_setup_token: refuse overwrite without --force — non-zero exit, existing file untouched" {
	_setup_token_env
	local token_file="$HOME/.config/drydock/claude-oauth-token"
	mkdir -p "$(dirname "$token_file")"
	printf 'existing-token-content\n' >"$token_file"
	chmod 600 "$token_file"
	run cmd_setup_token
	[ "$status" -ne 0 ]
	# Existing file must be untouched.
	local content
	content="$(cat "$token_file")"
	[ "$content" = "existing-token-content" ]
}

@test "cmd_setup_token: refuse overwrite includes age-in-days (SR-5a)" {
	_setup_token_env
	local token_file="$HOME/.config/drydock/claude-oauth-token"
	mkdir -p "$(dirname "$token_file")"
	printf 'existing-token-content\n' >"$token_file"
	chmod 600 "$token_file"
	# Back-date the file by 10 days so age is deterministic and non-zero.
	touch -d "10 days ago" "$token_file"
	run cmd_setup_token
	[ "$status" -ne 0 ]
	# Error output must include "day" (age-in-days wording).
	[[ "$output" == *"day"* ]]
}

@test "cmd_setup_token: --force overwrite — overwrites with new token, exit 0" {
	_setup_token_env
	local token_file="$HOME/.config/drydock/claude-oauth-token"
	mkdir -p "$(dirname "$token_file")"
	printf 'old-token-content\n' >"$token_file"
	chmod 600 "$token_file"
	run cmd_setup_token --force <<< "sk-ant-oat-v1-A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8S9T0U1V2W3X4Y5Z6"
	[ "$status" -eq 0 ]
	local content
	content="$(cat "$token_file")"
	[ "$content" = "sk-ant-oat-v1-A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8S9T0U1V2W3X4Y5Z6" ]
}

@test "cmd_setup_token: --force with no pre-existing file — succeeds as first-time setup" {
	_setup_token_env
	local token_file="$HOME/.config/drydock/claude-oauth-token"
	rm -f "$token_file"
	run cmd_setup_token --force <<< "sk-ant-oat-v1-A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8S9T0U1V2W3X4Y5Z6"
	[ "$status" -eq 0 ]
	[ -f "$token_file" ]
}

@test "cmd_setup_token: paste failure (user pastes garbage) — non-zero exit, no file written" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-token-fail-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"

	# Stub exits 0 (flow succeeded); user pastes garbage that fails validation.
	local fake_bin="$BATS_TEST_TMPDIR/fake-claude-garbage-$$"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/fake-claude"
	chmod +x "$fake_bin/fake-claude"
	export CLAUDE_BIN="$fake_bin/fake-claude"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	run cmd_setup_token <<< "this is not a token"
	[ "$status" -ne 0 ]
	[ ! -f "$HOME/.config/drydock/claude-oauth-token" ]
}

@test "cmd_setup_token: claude absent from PATH (empty CLAUDE_BIN) — non-zero exit, no file written" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-token-nobin-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"
	export CLAUDE_BIN="$BATS_TEST_TMPDIR/nonexistent-claude-$$"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	run cmd_setup_token
	[ "$status" -ne 0 ]
	[ ! -f "$HOME/.config/drydock/claude-oauth-token" ]
	# SR-1: error output must instruct the user to install Claude Code CLI (W1).
	[[ "$output" == *"install"* ]]
}

@test "cmd_setup_token: whitespace token rejected — non-zero exit, no file written (SR-2c)" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-token-ws-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"

	# Stub exits 0; user pastes a token-shaped string long enough to pass any
	# length floor but containing an internal space — strict sk-ant- regex rejects it.
	local fake_bin="$BATS_TEST_TMPDIR/fake-claude-ws-$$"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/fake-claude"
	chmod +x "$fake_bin/fake-claude"
	export CLAUDE_BIN="$fake_bin/fake-claude"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	# The internal space makes this fail the strict ^sk-ant-[A-Za-z0-9_-]{20,}$ check.
	run cmd_setup_token <<< "sk-ant-this-is-long-enough-to-be-a-token but has spaces"
	[ "$status" -ne 0 ]
	[ ! -f "$HOME/.config/drydock/claude-oauth-token" ]
}

@test "cmd_setup_token: write failure — non-zero exit, no success message (Fix2.4 false-success regression)" {
	_setup_token_env
	# Override mv as a shell function that always fails, simulating a rename failure
	# after token validation passes. Token arrives via stdin (paste prompt, Fix 1).
	# With the old ( subshell ) && mv pattern, set -e does not fire in a conditional
	# context — the function exits 0 and prints "OAuth token saved" (false success).
	# With the new sequential mv on its own line, set -e aborts before the success message.
	mv() { return 1; }
	export -f mv
	run cmd_setup_token <<< "sk-ant-oat-v1-A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8S9T0U1V2W3X4Y5Z6"
	[ "$status" -ne 0 ]
	[[ "$output" != *"OAuth token saved"* ]]
}

@test "cmd_setup_token: user abort (claude exits non-zero) — non-zero exit, error mentions failure, no paste prompt, no file (Fix5)" {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-token-abort-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"

	# Fake claude that exits non-zero, simulating user aborting the browser flow.
	local fake_bin="$BATS_TEST_TMPDIR/fake-claude-abort-$$"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"$fake_bin/fake-claude"
	chmod +x "$fake_bin/fake-claude"
	export CLAUDE_BIN="$fake_bin/fake-claude"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }

	run cmd_setup_token
	[ "$status" -ne 0 ]
	# Error output must mention the failure (status or "exited").
	[[ "$output" == *"exited"* ]] || [[ "$output" == *"status"* ]]
	# No token file must have been written.
	[ ! -f "$HOME/.config/drydock/claude-oauth-token" ]
}

# ── cmd_revoke_token ──────────────────────────────────────────────────────────

_setup_revoke_env() {
	local fakehome="$BATS_TEST_TMPDIR/fakehome-revoke-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"

	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
	ensure_prereqs() { :; }
}

@test "cmd_revoke_token: file present — removes it, exit 0" {
	_setup_revoke_env
	local token_file="$HOME/.config/drydock/claude-oauth-token"
	mkdir -p "$(dirname "$token_file")"
	printf 'some-token\n' >"$token_file"
	run cmd_revoke_token
	[ "$status" -eq 0 ]
	[ ! -f "$token_file" ]
}

@test "cmd_revoke_token: file absent — exit 0 (idempotent)" {
	_setup_revoke_env
	local token_file="$HOME/.config/drydock/claude-oauth-token"
	rm -f "$token_file"
	run cmd_revoke_token
	[ "$status" -eq 0 ]
}

@test "cmd_revoke_token: second run on absent file — exit 0 (idempotent, run twice)" {
	_setup_revoke_env
	local token_file="$HOME/.config/drydock/claude-oauth-token"
	rm -f "$token_file"
	run cmd_revoke_token
	[ "$status" -eq 0 ]
	run cmd_revoke_token
	[ "$status" -eq 0 ]
}

@test "cmd_revoke_token: output contains server-side revocation notice" {
	_setup_revoke_env
	run cmd_revoke_token
	[[ "$output" == *"claude.ai"* ]]
}
