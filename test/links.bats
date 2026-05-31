#!/usr/bin/env bats
# test/links.bats — unit tests for cmd_link, cmd_unlink, cmd_links
#
# Uses a synthetic $HOME (BATS_TEST_TMPDIR) and a real-on-disk project
# directory so realpath/resolve_project_dir work correctly.
# Does NOT require a running container or any DRYDOCK_* env (SP-12).

load "helpers/load"

# The negated-run assertions ('run !') below require bats >= 1.5.0.
bats_require_minimum_version 1.5.0

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
	source "$DRYDOCK_HOME/lib/sibling_ssh.sh"
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
	# R3-FIX-3: default target is stored WITHOUT trailing slash.
	# Entry: realpath(sibling_dir)|/workspace-siblings/sibling-repo|
	grep -qF "$(realpath "$sibling_dir")|/workspace-siblings/sibling-repo|" "$list_file"
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

@test "cmd_link: SP-1 (supersedes SP-3) --rw executes without 'not yet implemented' error" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-sp1"
	mkdir -p "$sibling_dir"
	# Plain directory (no .git) — exercises the no-.git/ RW path

	(
		cd "$PROJECT_DIR"
		run cmd_link --rw "$sibling_dir"
		[ "$status" -eq 0 ]
		[[ "$output" != *"not yet implemented"* ]]
	)
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

	# Same dependency as the R2-FIX-1/2 host-path-mirror test (see commit b89633a):
	# when HOME's first path component is in the system-dir denylist (block c fires
	# BEFORE block f), the rejection message names "system directory" instead of
	# "shadows/HOME/ancestor". On CI runners (where BATS_TEST_TMPDIR is under /tmp)
	# this is the path. Skip cleanly so the test reports the situation accurately.
	local _home_first="${HOME#/}"
	_home_first="${_home_first%%/*}"
	case "$_home_first" in
	etc | bin | sbin | usr | lib | lib32 | lib64 | boot | root | opt | proc | sys | dev | run | var | tmp)
		skip "HOME first-component '/$_home_first' is system-denylisted; block (c) fires first — run via scripts/test.sh on a host where /tmp is noexec"
		;;
	esac

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

	# Same dependency as the R2-FIX-1/2 host-path-mirror test (see commit b89633a).
	local _home_first="${HOME#/}"
	_home_first="${_home_first%%/*}"
	case "$_home_first" in
	etc | bin | sbin | usr | lib | lib32 | lib64 | boot | root | opt | proc | sys | dev | run | var | tmp)
		skip "HOME first-component '/$_home_first' is system-denylisted; block (c) fires first — run via scripts/test.sh on a host where /tmp is noexec"
		;;
	esac

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

	# This test exercises R2-FIX-1's "target under $HOME is accepted" guard.
	# _links_setup sets HOME=$BATS_TEST_TMPDIR/fakehome, so HOME's first path
	# component follows TMPDIR. scripts/test.sh redirects TMPDIR to a /home-
	# rooted path (first component `home`, NOT in the system-dir denylist);
	# running `bats test/` directly leaves TMPDIR under /tmp (first component
	# `tmp`, denylisted), which makes block (c) reject any target under HOME
	# BEFORE block (f) can exercise the under-HOME exception we want to test.
	# Skip cleanly in that case so direct-bats runs don't produce a misleading
	# false negative.
	local _home_first="${HOME#/}"
	_home_first="${_home_first%%/*}"
	case "$_home_first" in
	etc | bin | sbin | usr | lib | lib32 | lib64 | boot | root | opt | proc | sys | dev | run | var | tmp)
		skip "HOME first-component '/$_home_first' is system-denylisted; run via scripts/test.sh"
		;;
	esac

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	# A target UNDER $HOME (e.g. /home/<user>/projects/sibling) must be accepted —
	# this is the host-path-mirror use case the maintainer explicitly requires.
	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "$FAKE_HOME/projects/sibling"
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

# ── R3-FIX-1: RETURN trap broken — replace with explicit cleanup ──────────────

@test "cmd_unlink: R3-FIX-1 no stale .tmp file left when mv fails" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir"
	)

	# Simulate mv failure by overriding mv as a function in the subprocess.
	# SC2329 info: shellcheck cannot see the call inside cmd_unlink which is
	# sourced — mv() is looked up via Bash name resolution at call time.
	(
		cd "$PROJECT_DIR"
		# shellcheck disable=SC2329
		mv() { return 1; }
		export -f mv
		# cmd_unlink must exit non-zero (mv failed → err or return 1)
		run cmd_unlink "$sibling_dir"
		[ "$status" -ne 0 ]
	)

	# No .tmp* file must remain regardless of how unlink failed
	local tmp_count
	tmp_count="$(find "$FAKE_HOME/.config/drydock/links/" -name "*.tmp*" 2>/dev/null | wc -l || echo 0)"
	[ "$tmp_count" -eq 0 ]
}

# ── R3-FIX-7: stale .tmp files opportunistically cleaned at top of cmd_unlink ─


# ── R3-FIX-2: resolve_project_dir returns logical pwd; normalize to realpath ──

@test "cmd_link: R3-FIX-2 symlinked CWD does not bypass own-project guard" {
	_links_setup

	# Create a real project dir and a symlink pointing to it
	local real_proj="$BATS_TEST_TMPDIR/real-project"
	local link_proj="$BATS_TEST_TMPDIR/link-project"
	mkdir -p "$real_proj"
	ln -s "$real_proj" "$link_proj"

	# cd into the symlink path — resolve_project_dir returns the symlink path (pwd)
	# cmd_link should still detect that canonical == realpath(project_dir) and reject
	(
		cd "$link_proj"
		# Link the real path (canonical = real_proj); project_dir via pwd = link_proj
		# but realpath(link_proj) = real_proj, so the guard must fire
		run cmd_link "$real_proj"
		[ "$status" -ne 0 ]
		[[ "$output" == *"current project"* ]]
	)
}

@test "cmd_unlink: R3-FIX-7 pre-existing stale .tmp file is cleaned up on next successful unlink" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"
	mkdir -p "$(dirname "$list_file")"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir"
	)

	# Plant a stale .tmp file (simulating a previous SIGKILL'd unlink)
	touch "${list_file}.tmp12345"

	(
		cd "$PROJECT_DIR"
		run cmd_unlink "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	# Stale .tmp file must be gone after the successful unlink
	local tmp_count
	tmp_count="$(find "$FAKE_HOME/.config/drydock/links/" -name "*.tmp*" 2>/dev/null | wc -l || echo 0)"
	[ "$tmp_count" -eq 0 ]
}

# ── R3-FIX-4: .. component bypasses guards via path normalization ─────────────

@test "cmd_link: R3-FIX-4 rejects container target containing .." {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/workspace-siblings/../etc/foo"
		[ "$status" -ne 0 ]
		[[ "$output" == *".."* ]]
	)
}

@test "cmd_link: R3-FIX-4 rejects container target starting with .." {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/../etc/foo"
		[ "$status" -ne 0 ]
	)
}

# ── R3-FIX-5: . component bypasses guard (g) ─────────────────────────────────

@test "cmd_link: R3-FIX-5 rejects container target /workspace-siblings/." {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/workspace-siblings/."
		[ "$status" -ne 0 ]
		[[ "$output" == *"."* ]]
	)
}

@test "cmd_link: R3-FIX-5 rejects container target with embedded . component" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/some/./path"
		[ "$status" -ne 0 ]
	)
}

# ── R3-FIX-6: container-target guards use raw $HOME instead of $_real_home ───

@test "cmd_link: R3-FIX-6 container-target guard catches path under symlinked HOME" {
	_links_setup

	# Create a real home and a symlink HOME so $HOME != realpath($HOME)
	local real_home="$BATS_TEST_TMPDIR/real-cthome"
	local link_home="$BATS_TEST_TMPDIR/link-cthome"
	mkdir -p "$real_home"
	ln -s "$real_home" "$link_home"
	export HOME="$link_home"

	# Same dependency as the R2-FIX-1 tests above: when HOME's first path
	# component is system-denylisted (block c fires before block e/f), the
	# rejection message names "system directory" instead of "shadows". On CI
	# runners $BATS_TEST_TMPDIR is under /tmp — both real_home and link_home
	# are too. Skip cleanly.
	local _home_first="${HOME#/}"
	_home_first="${_home_first%%/*}"
	case "$_home_first" in
	etc | bin | sbin | usr | lib | lib32 | lib64 | boot | root | opt | proc | sys | dev | run | var | tmp)
		skip "HOME first-component '/$_home_first' is system-denylisted; block (c) fires first — run via scripts/test.sh on a host where /tmp is noexec"
		;;
	esac

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	# R4-FIX-7: target is the bare $real_home/.claude directory.
	# This proves the named invariant: the guard uses _real_home (realpath of
	# $HOME), NOT raw $HOME. With $HOME set to link_home, a naive raw-$HOME check
	# would compare link_home/.claude, which does NOT match real_home/.claude.
	# Only _real_home-based guard (e) catches this correctly.
	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "$real_home/.claude"
		[ "$status" -ne 0 ]
		[[ "$output" == *"shadows"* ]]
	)
}

# ── R3-FIX-3: trailing-slash mismatch hides container-target collisions ───────

@test "cmd_link: R3-FIX-3 custom target stored without trailing slash" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "/custom/mount/"
		[ "$status" -eq 0 ]
	)

	# Must be stored WITHOUT trailing slash
	grep -qF "$(realpath "$sibling_dir")|/custom/mount|" "$list_file"
	run ! grep -qF "$(realpath "$sibling_dir")|/custom/mount/|" "$list_file"
}

@test "cmd_link: R3-FIX-3 default target stored without trailing slash" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	# Default target must be stored WITHOUT trailing slash
	grep -qF "$(realpath "$sibling_dir")|/workspace-siblings/sibling-repo|" "$list_file"
	run ! grep -qF "$(realpath "$sibling_dir")|/workspace-siblings/sibling-repo/|" "$list_file"
}

@test "cmd_link: R3-FIX-3 collision detected when one entry uses trailing slash and new entry does not" {
	_links_setup

	local sibling_a="$BATS_TEST_TMPDIR/repo-a"
	local sibling_b="$BATS_TEST_TMPDIR/repo-b"
	mkdir -p "$sibling_a" "$sibling_b"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"
	mkdir -p "$(dirname "$list_file")"
	# Plant an entry with trailing slash (as if written by old code)
	printf '%s|/custom/target/|\n' "$(realpath "$sibling_a")" >> "$list_file"

	(
		cd "$PROJECT_DIR"
		# This should detect collision with /custom/target/ after normalization
		run cmd_link "$sibling_b" "/custom/target"
		[ "$status" -ne 0 ]
		[[ "$output" == *"collision"* ]]
	)
}

# ── R4-FIX-1: double-slash // bypasses all container-target guards ────────────

@test "cmd_link: R4-FIX-1 rejects container target starting with // (double-slash)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sibling_dir" "//etc/foo"
		[ "$status" -ne 0 ]
		[[ "$output" == *"//"* ]]
	)
}

# ── R4-FIX-2: credential-dir guards glob overmatch ───────────────────────────

@test "cmd_link: R4-FIX-2 accepts \$HOME/.ssh-backup (not a credential dir)" {
	_links_setup
	local ssh_backup="$FAKE_HOME/.ssh-backup"
	mkdir -p "$ssh_backup"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$ssh_backup"
		[ "$status" -eq 0 ]
	)
}

@test "cmd_link: R4-FIX-2 accepts \$HOME/.dockerfiles (not a credential dir)" {
	_links_setup
	local dockerfiles="$FAKE_HOME/.dockerfiles"
	mkdir -p "$dockerfiles"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$dockerfiles"
		[ "$status" -eq 0 ]
	)
}

@test "cmd_link: R4-FIX-2 still rejects \$HOME/.ssh (exact credential dir)" {
	_links_setup
	local ssh_dir="$FAKE_HOME/.ssh"
	mkdir -p "$ssh_dir"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$ssh_dir"
		[ "$status" -ne 0 ]
	)
}

@test "cmd_link: R4-FIX-2 still rejects \$HOME/.ssh/inner (subdir of credential dir)" {
	_links_setup
	local ssh_inner="$FAKE_HOME/.ssh/inner"
	mkdir -p "$ssh_inner"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$ssh_inner"
		[ "$status" -ne 0 ]
	)
}

# ── R4-FIX-3: dead code in guard (g) ─────────────────────────────────────────
# (Code-only fix; covered by existing R2-FIX-3 tests.)

# ── R4-FIX-4: file source rejected early ─────────────────────────────────────

@test "cmd_link: R4-FIX-4 rejects a regular file as source" {
	_links_setup

	local regular_file="$BATS_TEST_TMPDIR/notadir.txt"
	touch "$regular_file"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$regular_file"
		[ "$status" -ne 0 ]
		[[ "$output" == *"not a directory"* ]]
	)
}

# ── R4-FIX-5: re-linking same host with different container target ─────────────

@test "cmd_link: R4-FIX-5 errors when re-linking same host with a different container target" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir" "/custom/A"
		run cmd_link "$sibling_dir" "/custom/B"
		[ "$status" -ne 0 ]
		[[ "$output" == *"unlink"* ]]
	)
}

@test "cmd_link: R4-FIX-5 idempotent when same host and same target re-linked" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir" "/custom/A"
		run cmd_link "$sibling_dir" "/custom/A"
		[ "$status" -eq 0 ]
		[[ "$output" == *"already linked"* ]]
	)
}

# ── R4-FIX-6: awk failure in cmd_unlink leaves no tmp file ───────────────────

@test "cmd_unlink: R4-FIX-6 no stale .tmp file left when awk fails" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir"
	)

	# Simulate awk failure by overriding awk as a function in the subprocess.
	(
		cd "$PROJECT_DIR"
		# shellcheck disable=SC2329
		awk() {
			# First awk call is the existence check — let it succeed.
			# Second awk call is the rewrite — fail it.
			if [ "${_awk_calls:-0}" -eq 0 ]; then
				_awk_calls=1
				command awk "$@"
			else
				return 1
			fi
		}
		export -f awk
		run cmd_unlink "$sibling_dir"
		[ "$status" -ne 0 ]
	)

	# No .tmp* file must remain
	local tmp_count
	tmp_count="$(find "$FAKE_HOME/.config/drydock/links/" -name "*.tmp*" 2>/dev/null | wc -l || echo 0)"
	[ "$tmp_count" -eq 0 ]
}

# ── R4-FIX-7: R3-FIX-6 test validates the correct invariant ─────────────────
# (Test-only fix; no new test added here — the existing test is rewritten below.)

# ── WU6: T12-RED — SP-3-NEW: cmd_link --rw wire-up ───────────────────────────

# Helper: set up a fake git repo as a sibling with a canonical remote
_make_git_sibling() {
	local dir="$1"
	local url="${2:-git@github.com:owner/myrepo.git}"
	mkdir -p "$dir"
	git -C "$dir" init -b main >/dev/null 2>&1
	git -C "$dir" remote add origin "$url"
}

@test "SP-3-NEW: cmd_link --rw <git-repo> exits 0 and .list entry has flags=rw" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/rw-sibling"
	_make_git_sibling "$sibling_dir"

	# Create a primary key for managed SSH config generation
	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_link --rw "$sibling_dir"
		[ "$status" -eq 0 ]
		# No "not yet implemented" message
		[[ "$output" != *"not yet implemented"* ]]
	)

	[ -f "$list_file" ]
	# .list entry must have flags=rw (field 3)
	local canonical
	canonical="$(realpath "$sibling_dir")"
	grep -qF "${canonical}|" "$list_file"
	local flags
	flags="$(awk -F'|' -v c="$canonical" '$1==c{print $3}' "$list_file")"
	[ "$flags" = "rw" ]
}

@test "OQ-A-1: cmd_link --rw creates deploy key (0600) and pubkey (0644)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/rw-key-sibling"
	_make_git_sibling "$sibling_dir"

	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
	)

	local sanitized
	sanitized="$(basename "$sibling_dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"
	local key_path="$FAKE_HOME/.config/drydock/keys/${sanitized}_deploy"
	[ -f "$key_path" ]
	[ -f "${key_path}.pub" ]
	[ "$(stat -c '%a' "$key_path")" = "600" ]
	[ "$(stat -c '%a' "${key_path}.pub")" = "644" ]
}

@test "OQ-A-2: cmd_link --rw generates managed SSH config with both alias and fallback blocks; chmod 600" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/rw-cfg-sibling"
	_make_git_sibling "$sibling_dir"

	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"
	chmod 600 "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
	)

	local config="$FAKE_HOME/.config/drydock/ssh-config-myproject"
	[ -f "$config" ]

	local sanitized
	sanitized="$(basename "$sibling_dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"
	grep -q "Host github.com-${sanitized}" "$config"
	grep -q "Host github.com$" "$config"
	[ "$(stat -c '%a' "$config")" = "600" ]
}

@test "OQ-A-3 (#89): cmd_link --rw leaves sibling remote.origin.url canonical (no host contamination)" {
	# Pre-#89 (v0.2.1) rewrote remote.origin.url to the aliased form, breaking
	# `git fetch` on the host. Post-#89 the sibling .git/config is never
	# mutated — URL routing happens via url.insteadOf inside the container.
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/rw-url-sibling"
	_make_git_sibling "$sibling_dir" "git@github.com:owner/repo.git"

	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
	)

	local url
	url="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$url" = "git@github.com:owner/repo.git" ]
}

@test "D10: cmd_link --rw <plain-dir> (no .git/) mounts RW, skips key-gen + URL rewrite" {
	_links_setup

	local plain_dir="$BATS_TEST_TMPDIR/plain-dir"
	mkdir -p "$plain_dir"
	# No .git/ subdirectory

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_link --rw "$plain_dir"
		[ "$status" -eq 0 ]
	)

	# Must have rw entry
	local canonical
	canonical="$(realpath "$plain_dir")"
	local flags
	flags="$(awk -F'|' -v c="$canonical" '$1==c{print $3}' "$list_file")"
	[ "$flags" = "rw" ]

	# No key should be created
	local sanitized
	sanitized="$(basename "$plain_dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"
	local key_path="$FAKE_HOME/.config/drydock/keys/${sanitized}_deploy"
	[ ! -f "$key_path" ]
}

@test "D11 (#89): re-running cmd_link --rw on same path is idempotent — key unchanged, URL stays canonical" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/rw-idempotent"
	_make_git_sibling "$sibling_dir" "git@github.com:owner/repo.git"

	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	local sanitized
	sanitized="$(basename "$sibling_dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"
	local key_path="$FAKE_HOME/.config/drydock/keys/${sanitized}_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
	)

	local mtime1
	mtime1="$(stat -c '%Y' "$key_path" 2>/dev/null || echo 0)"
	sleep 1

	(
		cd "$PROJECT_DIR"
		run cmd_link --rw "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	local mtime2
	mtime2="$(stat -c '%Y' "$key_path" 2>/dev/null || echo 0)"
	[ "$mtime1" = "$mtime2" ]

	# Issue #89: URL must stay canonical — link does not mutate .git/config.
	local url
	url="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$url" = "git@github.com:owner/repo.git" ]
}

@test "D5: cmd_link --rw with same sanitized basename from different path — rejected" {
	_links_setup

	# First: link /tmp/.../sibling-a
	local sibling_a="$BATS_TEST_TMPDIR/my-lib"
	_make_git_sibling "$sibling_a" "git@github.com:owner/my-lib.git"
	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_a"
	)

	# Second: try to link a DIFFERENT path with the same basename
	local sibling_b="$BATS_TEST_TMPDIR/other-loc/my-lib"
	_make_git_sibling "$sibling_b" "git@github.com:owner2/my-lib.git"

	local canonical_a
	canonical_a="$(realpath "$sibling_a")"
	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"
	local entry_count_before
	entry_count_before="$(wc -l <"$list_file" || echo 0)"

	(
		cd "$PROJECT_DIR"
		run cmd_link --rw "$sibling_b"
		[ "$status" -ne 0 ]
	)

	# .list must be unchanged (only the first sibling)
	local entry_count_after
	entry_count_after="$(wc -l <"$list_file" || echo 0)"
	[ "$entry_count_before" = "$entry_count_after" ]
}

@test "PRIMARY-URL-INTACT: after link --rw <sibling>, primary repo URL is unchanged" {
	_links_setup

	# Set up primary as a git repo
	git -C "$PROJECT_DIR" init -b main >/dev/null 2>&1
	git -C "$PROJECT_DIR" remote add origin "git@github.com:owner/primary.git"

	local sibling_dir="$BATS_TEST_TMPDIR/rw-primary-intact"
	_make_git_sibling "$sibling_dir" "git@github.com:owner/sibling.git"

	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
	)

	# Primary URL must be unchanged
	local primary_url
	primary_url="$(git -C "$PROJECT_DIR" remote get-url origin)"
	[ "$primary_url" = "git@github.com:owner/primary.git" ]
}

@test "SR-10: cmd_link --rw rejects HTTPS remote — non-zero exit, no key created" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/https-sibling"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -b main >/dev/null 2>&1
	git -C "$sibling_dir" remote add origin "https://github.com/owner/repo.git"

	mkdir -p "$FAKE_HOME/.config/drydock/keys"

	(
		cd "$PROJECT_DIR"
		run cmd_link --rw "$sibling_dir"
		[ "$status" -ne 0 ]
	)

	local sanitized
	sanitized="$(basename "$sibling_dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"
	[ ! -f "$FAKE_HOME/.config/drydock/keys/${sanitized}_deploy" ]
}

# ── WU7: T20-RED — RW-UNLINK-1 ───────────────────────────────────────────────

@test "RW-UNLINK-1: unlink on RW-linked sibling — removes entry, restores URL, leaves key, dual hint" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/unlink-rw-sibling"
	_make_git_sibling "$sibling_dir" "git@github.com:owner/repo.git"

	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"
	chmod 600 "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
	)

	local sanitized
	sanitized="$(basename "$sibling_dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"
	local key_path="$FAKE_HOME/.config/drydock/keys/${sanitized}_deploy"
	[ -f "$key_path" ]

	local canonical
	canonical="$(realpath "$sibling_dir")"
	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_unlink "$sibling_dir"
		[ "$status" -eq 0 ]
		# Must print BOTH local key hint AND GitHub revocation hint
		[[ "$output" =~ "$key_path" ]] || [[ "$output" =~ "${key_path}.pub" ]]
		[[ "$output" =~ "GitHub" ]] || [[ "$output" =~ "github.com" ]]
	)

	# .list entry must be removed
	if [ -f "$list_file" ]; then
		run grep -F "${canonical}|" "$list_file"
		[ "$status" -ne 0 ]
	fi

	# Key must still exist on disk (D6)
	[ -f "$key_path" ]

	# URL must be restored to canonical form
	local url
	url="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$url" = "git@github.com:owner/repo.git" ]

	# Managed SSH config must not contain alias block for this sibling
	local config="$FAKE_HOME/.config/drydock/ssh-config-myproject"
	if [ -f "$config" ]; then
		run grep "Host github.com-${sanitized}" "$config"
		[ "$status" -ne 0 ]
	fi
}

@test "SR-6 symmetric: unlink --rw on RW sibling behaves same as unlink (flag ignored)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/unlink-rw-flag"
	_make_git_sibling "$sibling_dir" "git@github.com:owner/repo.git"

	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
	)

	local canonical
	canonical="$(realpath "$sibling_dir")"
	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_unlink --rw "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	# Entry must be removed
	if [ -f "$list_file" ]; then
		run grep -F "${canonical}|" "$list_file"
		[ "$status" -ne 0 ]
	fi
}

@test "SR-6 symmetric: unlink --rw on RO sibling performs standard RO unlink" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/unlink-ro-sibling"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir"  # RO link
	)

	local canonical
	canonical="$(realpath "$sibling_dir")"
	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	# Verify it was linked (RO)
	grep -qF "${canonical}|" "$list_file"

	(
		cd "$PROJECT_DIR"
		run cmd_unlink --rw "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	# Must be unlinked
	if [ -f "$list_file" ]; then
		run grep -F "${canonical}|" "$list_file"
		[ "$status" -ne 0 ]
	fi
}

# ── WU8: T22-RED — RW-LIST-1 ─────────────────────────────────────────────────

@test "RW-LIST-1: drydock links shows (rw) for RW sibling and (ro) for RO sibling" {
	_links_setup

	local ro_dir="$BATS_TEST_TMPDIR/ro-sibling-list"
	local rw_dir="$BATS_TEST_TMPDIR/rw-sibling-list"
	mkdir -p "$ro_dir"
	_make_git_sibling "$rw_dir" "git@github.com:owner/repo.git"

	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link "$ro_dir"
		cmd_link --rw "$rw_dir"
	)

	(
		cd "$PROJECT_DIR"
		run cmd_links
		[ "$status" -eq 0 ]
		[[ "$output" =~ "(rw)" ]]
		[[ "$output" =~ "(ro)" ]]
	)
}

# ── WU9: T23-RED — RO regression: link without --rw has empty flags ───────────

@test "RO-regression: cmd_link without --rw produces empty flags field in .list" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/ro-no-flags"
	mkdir -p "$sibling_dir"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir"
	)

	[ -f "$list_file" ]
	local canonical
	canonical="$(realpath "$sibling_dir")"
	# Field 3 (flags) must be empty for a plain RO link
	local flags
	flags="$(awk -F'|' -v c="$canonical" '$1==c{print $3}' "$list_file")"
	[ -z "$flags" ]

	# No deploy key created
	local sanitized
	sanitized="$(basename "$sibling_dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"
	[ ! -f "$FAKE_HOME/.config/drydock/keys/${sanitized}_deploy" ]
}

# ── JD1-AB-RED: idempotent check must consider flags field ────────────────────

@test "JD1-AB-1: link RO then link --rw same path → mode-mismatch error, non-zero, unlink hint" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/ab-sibling-1"
	mkdir -p "$sibling_dir"

	(
		cd "$PROJECT_DIR"
		cmd_link "$sibling_dir"
		run cmd_link --rw "$sibling_dir"
		[ "$status" -ne 0 ]
		[[ "$output" == *"already linked as"*"ro"* ]]
		[[ "$output" == *"drydock unlink"* ]]
	)
}

@test "JD1-AB-2: link --rw then link (no flag) same path → mode-mismatch error, non-zero, unlink hint" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/ab-sibling-2"
	_make_git_sibling "$sibling_dir"
	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
		run cmd_link "$sibling_dir"
		[ "$status" -ne 0 ]
		[[ "$output" == *"already linked as"*"rw"* ]]
		[[ "$output" == *"drydock unlink"* ]]
	)
}

@test "JD1-AB-3 (#89): link --rw then link --rw same path → idempotent success, URL stays canonical" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/ab-sibling-3"
	_make_git_sibling "$sibling_dir"
	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
		run cmd_link --rw "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	# Exactly one entry in .list for this canonical path
	local canonical
	canonical="$(realpath "$sibling_dir")"
	local count
	count="$(grep -cF "$canonical" "$list_file")"
	[ "$count" -eq 1 ]

	# SSH config still has alias block (managed SSH config is the container-side
	# routing artifact — owned by drydock, not the host).
	local sanitized
	sanitized="$(basename "$sibling_dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"
	local ssh_config="$FAKE_HOME/.config/drydock/ssh-config-myproject"
	[ -f "$ssh_config" ]
	grep -q "Host github.com-${sanitized}" "$ssh_config"

	# Key file still present
	[ -f "$FAKE_HOME/.config/drydock/keys/${sanitized}_deploy" ]

	# Issue #89: sibling .git/config URL stays canonical end-to-end.
	local url
	url="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$url" = "git@github.com:owner/myrepo.git" ]
}

@test "JD1-AB-4 (#89): partial-state self-heal — .list entry exists but SSH config absent, re-link --rw completes mutations" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/ab-sibling-4"
	_make_git_sibling "$sibling_dir"
	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"
	local canonical
	canonical="$(realpath "$sibling_dir")"
	local sanitized
	sanitized="$(basename "$sibling_dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"

	# Simulate partial state: .list has the RW entry, but no SSH config exists.
	mkdir -p "$(dirname "$list_file")"
	printf '%s|/workspace-siblings/%s|rw\n' "$canonical" "$(basename "$sibling_dir")" >"$list_file"
	local ssh_config="$FAKE_HOME/.config/drydock/ssh-config-myproject"
	rm -f "$ssh_config"

	(
		cd "$PROJECT_DIR"
		run cmd_link --rw "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	# SSH config must now have the alias block (self-healed by re-link).
	[ -f "$ssh_config" ]
	grep -q "Host github.com-${sanitized}" "$ssh_config"

	# Issue #89: URL stays canonical — link never mutates .git/config.
	local url
	url="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$url" = "git@github.com:owner/myrepo.git" ]

	# Still exactly one entry in .list
	local count
	count="$(grep -cF "$canonical" "$list_file")"
	[ "$count" -eq 1 ]
}

# ── #89 RED — link/unlink no longer mutate the sibling's .git/config ──────────
#
# Issue #89: rewriting remote.origin.url broke `git fetch` on the host because
# the SSH alias only resolves inside the container. The fix routes URLs via
# url.insteadOf in a container-only gitconfig — the sibling .git/config stays
# canonical end-to-end. INV-1 extended: drydock never contaminates the host's
# git configuration.

@test "#89 RED: cmd_link --rw does NOT mutate sibling remote.origin.url (host stays intact)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/89-link-noop"
	_make_git_sibling "$sibling_dir" "git@github.com:owner/repo.git"
	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	local before
	before="$(git -C "$sibling_dir" remote get-url origin)"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
	)

	local after
	after="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$before" = "$after" ]
	[ "$after" = "git@github.com:owner/repo.git" ]
}

@test "#89 RED: cmd_link --rw auto-heals a stale aliased URL from v0.2.1 by restoring to canonical" {
	_links_setup

	# Sibling was already linked under v0.2.1 — URL is the aliased form left
	# behind by _rewrite_sibling_remote_url before the user upgraded.
	local sibling_dir="$BATS_TEST_TMPDIR/89-link-heal"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -q -b main
	local sanitized
	sanitized="$(basename "$sibling_dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"
	git -C "$sibling_dir" remote add origin "git@github.com-${sanitized}:owner/repo.git"

	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		run cmd_link --rw "$sibling_dir"
		[ "$status" -eq 0 ]
	)

	# Auto-heal: link restored the URL to canonical so host git works again.
	local url
	url="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$url" = "git@github.com:owner/repo.git" ]
}

@test "#89 RED: cmd_unlink leaves sibling remote.origin.url unchanged (no mutation to undo)" {
	_links_setup

	local sibling_dir="$BATS_TEST_TMPDIR/89-unlink-noop"
	_make_git_sibling "$sibling_dir" "git@github.com:owner/repo.git"
	mkdir -p "$FAKE_HOME/.config/drydock/keys"
	touch "$FAKE_HOME/.config/drydock/keys/myproject_deploy"

	(
		cd "$PROJECT_DIR"
		cmd_link --rw "$sibling_dir"
	)

	# URL is still canonical post-link (covered by separate RED test above).
	# Unlink must leave it canonical too — no mutation, no restore.
	local before
	before="$(git -C "$sibling_dir" remote get-url origin)"

	(
		cd "$PROJECT_DIR"
		cmd_unlink "$sibling_dir"
	)

	local after
	after="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$before" = "$after" ]
	[ "$after" = "git@github.com:owner/repo.git" ]
}

# ── #122: --mirror flag (host-path-mirror syntactic sugar) ────────────────────

@test "cmd_link: #122 --mirror stores the host source path as the container target" {
	_links_setup

	# Mirror target == host source path. When $BATS_TEST_TMPDIR is under a
	# system-denylisted first component (CI runs `bats` directly with TMPDIR
	# under /tmp), block (c) rejects the target before the mount succeeds.
	# scripts/test.sh redirects TMPDIR to a /home-rooted path where this runs.
	# `skip` must be called inline (not via a helper) to return from the test.
	local _tmp_first="${BATS_TEST_TMPDIR#/}"
	_tmp_first="${_tmp_first%%/*}"
	case "$_tmp_first" in
	etc | bin | sbin | usr | lib | lib32 | lib64 | boot | root | opt | proc | sys | dev | run | var | tmp)
		skip "tmpdir first-component '/$_tmp_first' is system-denylisted as a mirror target; run via scripts/test.sh"
		;;
	esac

	local sib="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sib"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_link --mirror "$sib"
		[ "$status" -eq 0 ]
	)

	# Mirror entry: realpath(host)|<host source path>| (RO → empty flags).
	grep -qF "$(realpath "$sib")|$sib|" "$list_file"
}

@test "cmd_link: #122 --mirror is equivalent to the two-arg same-path form" {
	_links_setup

	# See the guard note above: skip when the mirror target lands under a
	# system-denylisted first component (direct `bats` run with TMPDIR=/tmp).
	local _tmp_first="${BATS_TEST_TMPDIR#/}"
	_tmp_first="${_tmp_first%%/*}"
	case "$_tmp_first" in
	etc | bin | sbin | usr | lib | lib32 | lib64 | boot | root | opt | proc | sys | dev | run | var | tmp)
		skip "tmpdir first-component '/$_tmp_first' is system-denylisted as a mirror target; run via scripts/test.sh"
		;;
	esac

	local sib="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sib"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		run cmd_link --mirror "$sib"
		[ "$status" -eq 0 ]
	)
	local mirror_line
	mirror_line="$(grep . "$list_file")"

	rm -f "$list_file"

	(
		cd "$PROJECT_DIR"
		run cmd_link "$sib" "$sib"
		[ "$status" -eq 0 ]
	)
	local twoarg_line
	twoarg_line="$(grep . "$list_file")"

	[ "$mirror_line" = "$twoarg_line" ]
}

@test "cmd_link: #122 --mirror rejects an explicit container target (conflict)" {
	_links_setup

	local sib="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sib"

	(
		cd "$PROJECT_DIR"
		run cmd_link --mirror "$sib" "/custom/mount"
		[ "$status" -ne 0 ]
		[[ "$output" == *"--mirror"* ]]
	)
}

@test "cmd_link: #122 --mirror still applies host-source rejection guards (INV-1)" {
	_links_setup

	mkdir -p "$FAKE_HOME/.ssh"

	(
		cd "$PROJECT_DIR"
		run cmd_link --mirror "$FAKE_HOME/.ssh"
		[ "$status" -ne 0 ]
		[[ "$output" == *"protected path"* ]]
	)
}

@test "cmd_unlink: #122 --mirror is accepted as an alias and removes the entry" {
	_links_setup

	# See the guard note above: the link step uses --mirror, so skip when the
	# mirror target lands under a system-denylisted first component.
	local _tmp_first="${BATS_TEST_TMPDIR#/}"
	_tmp_first="${_tmp_first%%/*}"
	case "$_tmp_first" in
	etc | bin | sbin | usr | lib | lib32 | lib64 | boot | root | opt | proc | sys | dev | run | var | tmp)
		skip "tmpdir first-component '/$_tmp_first' is system-denylisted as a mirror target; run via scripts/test.sh"
		;;
	esac

	local sib="$BATS_TEST_TMPDIR/sibling-repo"
	mkdir -p "$sib"

	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"

	(
		cd "$PROJECT_DIR"
		cmd_link --mirror "$sib"
		run cmd_unlink --mirror "$sib"
		[ "$status" -eq 0 ]
	)

	# Entry removed (file may be empty after removing the last entry).
	! grep -qF "$(realpath "$sib")|" "$list_file"
}

# ── #123: warn_unlinked_skill_symlinks (broken-skill-symlink pre-flight) ──────

@test "warn_unlinked_skill_symlinks: #123 outside-project unlinked symlink → one warning with fix" {
	_links_setup

	local ext="$BATS_TEST_TMPDIR/external-skills/playwright"
	mkdir -p "$ext"
	mkdir -p "$PROJECT_DIR/.claude/skills"
	ln -s "$ext" "$PROJECT_DIR/.claude/skills/playwright"

	run warn_unlinked_skill_symlinks "$PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"playwright"* ]]
	[[ "$output" == *"not linked"* ]]
	# Fix command names --mirror and points at the target's parent dir.
	[[ "$output" == *"drydock link --mirror $(dirname "$(realpath -m "$ext")")"* ]]
}

@test "warn_unlinked_skill_symlinks: #123 no warning when target tree is mirror-linked" {
	_links_setup

	local ext_root="$BATS_TEST_TMPDIR/external-skills"
	local ext="$ext_root/playwright"
	mkdir -p "$ext"
	mkdir -p "$PROJECT_DIR/.claude/skills"
	ln -s "$ext" "$PROJECT_DIR/.claude/skills/playwright"

	# Mirror entry covering the parent tree: container target == host path.
	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"
	mkdir -p "$(dirname "$list_file")"
	local canon
	canon="$(realpath -m "$ext_root")"
	printf '%s|%s|\n' "$canon" "$canon" >"$list_file"

	run warn_unlinked_skill_symlinks "$PROJECT_DIR"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "warn_unlinked_skill_symlinks: #123 default (/workspace-siblings) link does NOT suppress the warning" {
	_links_setup

	local ext_root="$BATS_TEST_TMPDIR/external-skills"
	local ext="$ext_root/playwright"
	mkdir -p "$ext"
	mkdir -p "$PROJECT_DIR/.claude/skills"
	ln -s "$ext" "$PROJECT_DIR/.claude/skills/playwright"

	# Default link: host path mounted at /workspace-siblings — does NOT make the
	# absolute symlink target resolve in the container, so the warning must fire.
	local list_file="$FAKE_HOME/.config/drydock/links/myproject.list"
	mkdir -p "$(dirname "$list_file")"
	local canon
	canon="$(realpath -m "$ext_root")"
	printf '%s|/workspace-siblings/external-skills|\n' "$canon" >"$list_file"

	run warn_unlinked_skill_symlinks "$PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"not linked"* ]]
	[[ "$output" == *"drydock link --mirror"* ]]
}

@test "warn_unlinked_skill_symlinks: #123 N symlinks into one tree → one grouped warning" {
	_links_setup

	local ext_root="$BATS_TEST_TMPDIR/external-skills"
	mkdir -p "$ext_root/a" "$ext_root/b" "$ext_root/c"
	mkdir -p "$PROJECT_DIR/.claude/skills"
	ln -s "$ext_root/a" "$PROJECT_DIR/.claude/skills/a"
	ln -s "$ext_root/b" "$PROJECT_DIR/.claude/skills/b"
	ln -s "$ext_root/c" "$PROJECT_DIR/.claude/skills/c"

	run warn_unlinked_skill_symlinks "$PROJECT_DIR"
	[ "$status" -eq 0 ]
	# All three share parent $ext_root → exactly one fix line.
	local fix_count
	fix_count="$(printf '%s\n' "$output" | grep -c 'drydock link --mirror')"
	[ "$fix_count" -eq 1 ]
}

@test "warn_unlinked_skill_symlinks: #123 symlink that stays inside the project → no warning" {
	_links_setup

	mkdir -p "$PROJECT_DIR/.claude/skills" "$PROJECT_DIR/shared"
	ln -s "$PROJECT_DIR/shared" "$PROJECT_DIR/.claude/skills/local"

	run warn_unlinked_skill_symlinks "$PROJECT_DIR"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "warn_unlinked_skill_symlinks: #123 no skills dir → silent, exit 0" {
	_links_setup

	run warn_unlinked_skill_symlinks "$PROJECT_DIR"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "warn_unlinked_skill_symlinks: #123 relative symlink escaping the project → warning" {
	_links_setup

	# A relative symlink that climbs out of the project tree. realpath -m must
	# resolve it relative to the symlink's own directory before the under-project
	# check, otherwise an escaping relative link would be missed.
	local ext="$BATS_TEST_TMPDIR/outside-tree/skill"
	mkdir -p "$ext"
	mkdir -p "$PROJECT_DIR/.claude/skills"
	ln -s "../../../outside-tree/skill" "$PROJECT_DIR/.claude/skills/escaper"

	run warn_unlinked_skill_symlinks "$PROJECT_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"escaper"* ]]
	[[ "$output" == *"drydock link --mirror"* ]]
}

@test "warn_unlinked_skill_symlinks: #123 two distinct parents → two warnings" {
	_links_setup

	local tree_a="$BATS_TEST_TMPDIR/tree-a"
	local tree_b="$BATS_TEST_TMPDIR/tree-b"
	mkdir -p "$tree_a/one" "$tree_b/two"
	mkdir -p "$PROJECT_DIR/.claude/skills"
	ln -s "$tree_a/one" "$PROJECT_DIR/.claude/skills/one"
	ln -s "$tree_b/two" "$PROJECT_DIR/.claude/skills/two"

	run warn_unlinked_skill_symlinks "$PROJECT_DIR"
	[ "$status" -eq 0 ]
	# Distinct parents must NOT be grouped — one fix line each.
	local fix_count
	fix_count="$(printf '%s\n' "$output" | grep -c 'drydock link --mirror')"
	[ "$fix_count" -eq 2 ]
}
