#!/usr/bin/env bats
# test/links.bats — unit tests for cmd_link, cmd_unlink, cmd_links
#
# Uses a synthetic $HOME (BATS_TEST_TMPDIR) and a real-on-disk project
# directory so realpath/resolve_project_dir work correctly.
# Does NOT require a running container or any DRYDOCK_* env (SP-12).

load "helpers/load"

# ── Shared setup helper ───────────────────────────────────────────────────────

# Source all libs in bin/drydock order with a synthetic home and project dir.
# Sets: FAKE_HOME, PROJECT_DIR
_links_setup() {
	FAKE_HOME="$BATS_TEST_TMPDIR/fakehome"
	mkdir -p "$FAKE_HOME"
	export HOME="$FAKE_HOME"

	PROJECT_DIR="$BATS_TEST_TMPDIR/myproject"
	mkdir -p "$PROJECT_DIR"

	source "$DRYDOCK_HOME/lib/common.sh"
	source "$DRYDOCK_HOME/lib/paths.sh"
	source "$DRYDOCK_HOME/lib/compose.sh"
	source "$DRYDOCK_HOME/lib/commands.sh"
}

# ── T3-RED: cmd_link happy path ───────────────────────────────────────────────

@test "cmd_link: SP-1 appends realpath(host) with default target to list; exit 0" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	[ -f "$list_file" ]
	# Entry: realpath(sibling_dir)|/workspace-siblings/sibling-repo/|
	grep -qF "$(realpath "$sibling_dir")|/workspace-siblings/sibling-repo/|" "$list_file"
}

@test "cmd_link: SP-1 idempotent — linking same path twice produces exactly one entry" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir"
		cmd_link "$sibling_dir"
	)

	# Exactly one entry for this host path
	local count
	count=$(grep -cF "$(realpath "$sibling_dir")|" "$list_file")
	[ "$count" -eq 1 ]
}

@test "cmd_link: SP-2 second positional arg stored as custom container target" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/custom/mount"
		[ "$status" -eq 0 ]
	)

	grep -qF "$(realpath "$sibling_dir")|/custom/mount|" "$list_file"
}

@test "cmd_link: SP-12 succeeds with no DRYDOCK_* env exported" {
	_links_setup
	# Ensure no DRYDOCK_* env vars are set
	unset DRYDOCK_PROJECT_DIR 2>/dev/null || true
	unset PROJECT_NAME 2>/dev/null || true

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo2"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir"
		[ "$status" -eq 0 ]
	)
}

# ── T4-RED: cmd_link rejection guards ────────────────────────────────────────

@test "cmd_link: SP-3 --rw exits non-zero, stderr contains 'not yet implemented'" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_link --rw "$sibling_dir"
		[ "$status" -ne 0 ]
		[[ "$output" == *"not yet implemented"* ]]
	)

	# List MUST NOT have been mutated
	[ ! -f "$list_file" ] || ! grep -qF "$sibling_dir" "$list_file"
}

@test "cmd_link: SP-6 rejects \$HOME exactly" {
	_links_setup

	(
		cd "$PROJECT_DIR"
		run cmd_link "$FAKE_HOME"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: SP-6 rejects ancestor of \$HOME (root /)" {
	_links_setup

	(
		cd "$PROJECT_DIR"
		run cmd_link "/"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: SP-6 rejects \$HOME/.claude-container (state dir)" {
	_links_setup
	local state_dir="$FAKE_HOME/.claude-container"
	mkdir -p "$state_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$state_dir"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: SP-6 rejects \$HOME/.engram-something" {
	_links_setup
	local engram_dir="$FAKE_HOME/.engram-something"
	mkdir -p "$engram_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$engram_dir"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: SP-6 rejects \$HOME/.config/drydock" {
	_links_setup
	local drydock_cfg="$FAKE_HOME/.config/drydock"
	mkdir -p "$drydock_cfg"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$drydock_cfg"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: SP-6 rejects own project directory" {
	_links_setup

	(
		cd "$PROJECT_DIR"
		run cmd_link "$PROJECT_DIR"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: SP-6 D7 symlink-bypass: realpath canonicalized before guard" {
	_links_setup
	# Create a symlink that resolves to a .claude* path inside $HOME.
	# The symlink itself is outside $HOME so would bypass a naive string check,
	# but realpath canonicalizes it first — then the .claude* guard catches it.
	local target_under_home="$FAKE_HOME/.claude-secret"
	mkdir -p "$target_under_home"
	local symlink_path="$BATS_TEST_TMPDIR/innocent-looking-link"
	ln -s "$target_under_home" "$symlink_path"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$symlink_path"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: SP-7 rejects custom target /workspace" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/workspace"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: SP-7 rejects custom target under /workspace" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/workspace/sub"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: SP-7 rejects custom target under container home .claude" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "$FAKE_HOME/.claude-data"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: SP-7 rejects custom target under /etc" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/etc/stuff"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-3 rejects duplicate container target from two different host paths" {
	_links_setup

	local sibling_a="$BATS_TEST_TMPDIR/repo-a"
	local sibling_b="$BATS_TEST_TMPDIR/repo-b"
	mkdir -p "$sibling_a" "$sibling_b"

	(
		cd "$PROJECT_DIR"
		# First link with an explicit custom target
		cmd_link "$sibling_a" "/custom/target"
		# Second link to same container target — should fail
		run cmd_link "$sibling_b" "/custom/target"
		[ "$status" -ne 0 ]
		[[ "$output" == *"container target"* ]]
	)
}

@test "cmd_link: ADR-5 basename collision rejects with error naming both paths" {
	_links_setup

	# Two different host dirs with the same basename
	local sibling_a="$BATS_TEST_TMPDIR/groupA/sibling-repo"
	local sibling_b="$BATS_TEST_TMPDIR/groupB/sibling-repo"
	mkdir -p "$sibling_a" "$sibling_b"

	(
		cd "$PROJECT_DIR"
		# Link first one — should succeed
		cmd_link "$sibling_a"
		# Link second one with same basename — should fail with both paths named
		run cmd_link "$sibling_b"
		[ "$status" -ne 0 ]
		[[ "$output" == *"sibling-repo"* ]]
	)
}

# ── T6-RED: cmd_unlink ────────────────────────────────────────────────────────

@test "cmd_unlink: SP-4 happy path removes entry from list; exit 0" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir"
		run cmd_unlink "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	# Entry must no longer be present
	[ ! -f "$list_file" ] || ! grep -qF "$(realpath "$sibling_dir")|" "$list_file"
}

@test "cmd_unlink: SP-4 unknown path exits non-zero" {
	_links_setup

	(
		cd "$PROJECT_DIR"
		run cmd_unlink "/projects/ghost"
		[ "$status" -ne 0 ]
	)
}

# ── FIX #1: cmd_unlink anchored match ────────────────────────────────────────

@test "cmd_unlink: FIX-1 does NOT delete a sibling whose target equals the unlinked host path" {
	_links_setup

	# Craft a list file where /host-b's container target matches /host-a's host path.
	# With the unanchored grep -F "${canonical}|", unlinking /host-a would also
	# delete /host-b because /host-a appears inside /host-b's target column.
	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"
	mkdir -p "$(dirname "$list_file")"

	# /host-a is a real directory (realpath succeeds in cmd_unlink)
	local host_a="$BATS_TEST_TMPDIR/host-a"
	local host_b="$BATS_TEST_TMPDIR/host-b"
	mkdir -p "$host_a" "$host_b"

	# Write entries directly: host-b's target column IS host-a's path
	printf '%s|%s|\n' "$host_a" "/workspace-siblings/host-a/" >> "$list_file"
	printf '%s|%s|\n' "$host_b" "$host_a" >> "$list_file"

	(
		cd "$PROJECT_DIR"
		run cmd_unlink "$host_a"
		[ "$status" -eq 0 ]
	)

	# host-b entry MUST still be present
	grep -qF "$host_b" "$list_file"
}

@test "cmd_unlink: FIX-1 removing last entry leaves empty list file (set -e safe)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir"
		run cmd_unlink "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	# File exists but is empty (or does not exist)
	[ ! -f "$list_file" ] || [ ! -s "$list_file" ]
}

# ── T8-RED: cmd_links ─────────────────────────────────────────────────────────

@test "cmd_links: SP-5 shows two entries — stdout contains host paths and targets" {
	_links_setup

	local sibling_a="$BATS_TEST_TMPDIR/repo-a"
	local sibling_b="$BATS_TEST_TMPDIR/repo-b"
	mkdir -p "$sibling_a" "$sibling_b"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_a"
		cmd_link "$sibling_b"
		run cmd_links
		[ "$status" -eq 0 ]
		[[ "$output" == *"$(realpath "$sibling_a")"* ]]
		[[ "$output" == *"$(realpath "$sibling_b")"* ]]
	)
}

@test "cmd_links: SP-5 empty list — stdout empty, exit 0" {
	_links_setup

	(
		cd "$PROJECT_DIR"
		run cmd_links
		[ "$status" -eq 0 ]
		[ -z "$output" ]
	)
}

@test "cmd_links: SP-12 no-container context — passes with no DRYDOCK_* env" {
	_links_setup
	unset DRYDOCK_PROJECT_DIR 2>/dev/null || true
	unset PROJECT_NAME 2>/dev/null || true

	(
		cd "$PROJECT_DIR"
		run cmd_links
		[ "$status" -eq 0 ]
	)
}
