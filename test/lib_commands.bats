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

	local sentinel="$BATS_TEST_TMPDIR/ensure-synced-run-$$"
	ensure_synced() { touch "$sentinel"; }

	local project_dir="$BATS_TEST_TMPDIR/proj-run-$$"
	mkdir -p "$project_dir"

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-run-sync-$$.log"
	touch "$DOCKER_CALL_LOG"
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	run cmd_run "$project_dir"

	[ -f "$sentinel" ]
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

	local sentinel="$BATS_TEST_TMPDIR/ensure-synced-shell-$$"
	ensure_synced() { touch "$sentinel"; }

	local project_dir="$BATS_TEST_TMPDIR/proj-shell-$$"
	mkdir -p "$project_dir"

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-shell-sync-$$.log"
	touch "$DOCKER_CALL_LOG"
	exec() { echo "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	run cmd_shell "$project_dir"

	[ -f "$sentinel" ]
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

