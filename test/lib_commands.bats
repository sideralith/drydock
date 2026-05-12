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
	[[ "$output" == *"engram"* ]]
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
	[[ "$output" == *"macOS"* ]]
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
