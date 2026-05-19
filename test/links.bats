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

# ── FIX #6: credential subdir host-source guard ──────────────────────────────

@test "cmd_link: FIX-6 rejects \$HOME/.ssh (INV-1 credential guard)" {
	_links_setup
	local ssh_dir="$FAKE_HOME/.ssh"
	mkdir -p "$ssh_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$ssh_dir"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-6 rejects \$HOME/.aws (INV-1 credential guard)" {
	_links_setup
	local aws_dir="$FAKE_HOME/.aws"
	mkdir -p "$aws_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$aws_dir"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-6 rejects \$HOME/.gnupg (INV-1 credential guard)" {
	_links_setup
	local gnupg_dir="$FAKE_HOME/.gnupg"
	mkdir -p "$gnupg_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$gnupg_dir"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-6 rejects \$HOME/.kube (INV-1 credential guard)" {
	_links_setup
	local kube_dir="$FAKE_HOME/.kube"
	mkdir -p "$kube_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$kube_dir"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-6 rejects \$HOME/.docker (INV-1 credential guard)" {
	_links_setup
	local docker_cfg="$FAKE_HOME/.docker"
	mkdir -p "$docker_cfg"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$docker_cfg"
		[ "$status" -ne 0 ]
	)
}

# ── SP-6 ancestor check triangulation (from sdd-verify gap) ──────────────────

@test "cmd_link: SP-6 rejects intermediate ancestor of \$HOME (e.g. /home or parent dir)" {
	_links_setup

	# dirname of FAKE_HOME = BATS_TEST_TMPDIR which is an ancestor of FAKE_HOME
	local ancestor_dir
	ancestor_dir="$(dirname "$FAKE_HOME")"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$ancestor_dir"
		[ "$status" -ne 0 ]
	)
}

# ── R2-FIX-6: $HOME-as-symlink bypasses host-source guard ────────────────────

@test "cmd_link: R2-FIX-6 rejects path under symlinked \$HOME (credential guard not bypassed)" {
	_links_setup

	# Create a real home directory and a symlink pointing to it.
	# Export HOME as the symlink. A path like $HOME_SYMLINK/.claude-secret
	# resolves via realpath to $REAL_HOME/.claude-secret — the guard must
	# catch it even though $HOME is a symlink.
	local real_home="$BATS_TEST_TMPDIR/real-home"
	local link_home="$BATS_TEST_TMPDIR/link-home"
	mkdir -p "$real_home"
	ln -s "$real_home" "$link_home"
	export HOME="$link_home"

	# Create the protected dir under the real path
	local secret_dir="$real_home/.claude-secret"
	mkdir -p "$secret_dir"

	# Create a sibling dir to link (must exist for realpath to succeed)
	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		# Link path under $HOME (via the symlink) — realpath resolves to real_home,
		# so the .claude* prefix guard must fire even though the raw path uses link_home
		run cmd_link "$link_home/.claude-secret"
		[ "$status" -ne 0 ]
	)
}

# ── FIX #5: metacharacter validation ─────────────────────────────────────────

@test "cmd_link: FIX-5 rejects host path containing pipe character" {
	_links_setup

	# Simulate a path that would contain | — create actual dir with that name
	local bad_dir
	bad_dir="$(mktemp -d "$BATS_TEST_TMPDIR/bad|dir.XXXXXX" 2>/dev/null)" || {
		# If mktemp fails (filesystem doesn't support |), skip gracefully
		skip "filesystem does not allow | in filenames"
	}

	(
		cd "$PROJECT_DIR"
		run cmd_link "$bad_dir"
		[ "$status" -ne 0 ]
		[[ "$output" == *"|"* ]] || [[ "$output" == *"invalid"* ]] || [[ "$output" == *"character"* ]]
	)
}

@test "cmd_link: FIX-5 rejects custom target containing colon" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/mnt/path:with:colons"
		[ "$status" -ne 0 ]
		[[ "$output" == *"invalid"* ]] || [[ "$output" == *"character"* ]] || [[ "$output" == *":"* ]]
	)
}

@test "cmd_link: FIX-5 rejects custom target containing double-quote" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" '/mnt/"path"'
		[ "$status" -ne 0 ]
		[[ "$output" == *"invalid"* ]] || [[ "$output" == *"character"* ]] || [[ "$output" == *'"'* ]]
	)
}

@test "cmd_link: R2-FIX-5 rejects custom target containing backslash" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		# Pass a target with a literal backslash in it
		run cmd_link "$sibling_dir" '/mnt/path\with\backslash'
		[ "$status" -ne 0 ]
		[[ "$output" == *"backslash"* ]] || [[ "$output" == *"character"* ]] || [[ "$output" == *'\'* ]]
	)
}

# ── FIX #2: custom target robust validation ───────────────────────────────────

@test "cmd_link: FIX-2 rejects relative custom target (not absolute path)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "relative/path"
		[ "$status" -ne 0 ]
		[[ "$output" == *"absolute"* ]]
	)
}

@test "cmd_link: FIX-2 rejects custom target / (root)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-2 rejects custom target under /proc" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/proc/self"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-2 rejects custom target under /sys" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/sys/class"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-2 rejects custom target under /dev" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/dev/null"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-2 rejects custom target under /run" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/run/lock"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-2 rejects custom target under /var" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/var/tmp"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-2 rejects custom target under /opt/drydock/hooks (INV-3 bypass)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/opt/drydock/hooks"
		[ "$status" -ne 0 ]
		[[ "$output" == *"INV-3"* ]]
	)
}

@test "cmd_link: FIX-2 rejects custom target \$HOME/.engram-container (missing guard)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "$FAKE_HOME/.engram-container"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: FIX-2 rejects custom target \$HOME/.config/drydock (missing guard)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "$FAKE_HOME/.config/drydock"
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

# ── R2-FIX-1: custom target $HOME and $HOME ancestors rejected ───────────────

@test "cmd_link: R2-FIX-1 rejects custom target equal to \$HOME" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "$FAKE_HOME"
		[ "$status" -ne 0 ]
		[[ "$output" == *"shadows"* ]] || [[ "$output" == *"HOME"* ]] || [[ "$output" == *"ancestor"* ]]
	)
}

@test "cmd_link: R2-FIX-1 rejects custom target that is an ancestor of \$HOME" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	# Parent of FAKE_HOME is an ancestor of $HOME
	local ancestor
	ancestor="$(dirname "$FAKE_HOME")"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "$ancestor"
		[ "$status" -ne 0 ]
		[[ "$output" == *"shadows"* ]] || [[ "$output" == *"HOME"* ]] || [[ "$output" == *"ancestor"* ]]
	)
}

@test "cmd_link: R2-FIX-1/2 accepts host-path-mirror custom target under \$HOME (maintainer use case)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	# A target UNDER $HOME (e.g. /home/<user>/git/sibling) must be accepted —
	# this is the host-path-mirror use case the maintainer explicitly requires.
	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "$FAKE_HOME/git/sibling"
		[ "$status" -eq 0 ]
	)
}

# ── R2-FIX-2: /tmp missing from system-dir denylist ──────────────────────────

@test "cmd_link: R2-FIX-2 rejects custom target /tmp (covers container tmpfs)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/tmp/something"
		[ "$status" -ne 0 ]
		[[ "$output" == *"system"* ]] || [[ "$output" == *"/tmp"* ]]
	)
}

# ── R2-FIX-3: /workspace-siblings root rejected as custom target ──────────────

@test "cmd_link: R2-FIX-3 rejects custom target /workspace-siblings (bare parent)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/workspace-siblings"
		[ "$status" -ne 0 ]
		[[ "$output" == *"workspace-siblings"* ]]
	)
}

@test "cmd_link: R2-FIX-3 rejects custom target /workspace-siblings/ (bare parent with trailing slash)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/workspace-siblings/"
		[ "$status" -ne 0 ]
		[[ "$output" == *"workspace-siblings"* ]]
	)
}

@test "cmd_link: R2-FIX-3 accepts custom target under /workspace-siblings/foo" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	# A target UNDER /workspace-siblings (e.g. /workspace-siblings/foo) must be
	# accepted — it is functionally equivalent to a default target.
	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/workspace-siblings/foo"
		[ "$status" -eq 0 ]
	)
}

@test "cmd_link: FIX-8 link succeeds when list has a malformed line with empty target" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"
	mkdir -p "$(dirname "$list_file")"
	# Inject a malformed line with empty target — should not cause false collision or crash
	printf '/some/other/path||\n' >> "$list_file"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir"
		[ "$status" -eq 0 ]
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

# ── R2-FIX-7: cmd_unlink leaves no stale .tmp file after successful unlink ────

@test "cmd_unlink: R2-FIX-7 no stale .tmp file left after successful unlink" {
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

	# No .tmp* file must exist alongside the list file
	local tmp_count
	tmp_count="$(ls "$FAKE_HOME/.config/drydock/links/"*.tmp* 2>/dev/null | wc -l || echo 0)"
	[ "$tmp_count" -eq 0 ]
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
