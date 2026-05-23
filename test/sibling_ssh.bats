#!/usr/bin/env bats
# test/sibling_ssh.bats — unit tests for lib/sibling_ssh.sh
#
# Tests URL parse/rewrite/restore helpers, key-gen wrapper, and collision check.
# Uses a synthetic $HOME (BATS_TEST_TMPDIR/fakehome) so no real credentials
# are touched. Requires git and ssh-keygen to be available on PATH.

load "helpers/load"

# Shared setup: source all libs plus the new sibling_ssh.sh
_ssh_setup() {
	FAKE_HOME="$BATS_TEST_TMPDIR/fakehome-ssh"
	mkdir -p "$FAKE_HOME"
	export HOME="$FAKE_HOME"

	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/sibling_ssh.sh"
}

# ── #89: _restore_canonical_remote_url — migration / unlink safety net ───────
#
# History: pre-#89, drydock had a symmetric pair (_rewrite_sibling_remote_url /
# _restore_canonical_remote_url) that mutated remote.origin.url on link and
# undid it on unlink. That contaminated the host (`git fetch` broke). The
# rewrite was deleted; restore stays as the startup-migration entry point AND
# the unlink-time safety net for repos still carrying a v0.2.1 aliased URL.

@test "SR-restore: restores an aliased URL with .git suffix to canonical" {
	_ssh_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-restore-dotgit"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -q -b main >/dev/null 2>&1
	# Pre-seed with the v0.2.1-era aliased URL.
	git -C "$sibling_dir" remote add origin "git@github.com-my-alias:owner/repo.git"

	_restore_canonical_remote_url "$sibling_dir" "my-alias"

	local restored
	restored="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$restored" = "git@github.com:owner/repo.git" ]
}

@test "SR-restore: restores an aliased URL without .git suffix to canonical" {
	_ssh_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-restore-nodotgit"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -q -b main >/dev/null 2>&1
	git -C "$sibling_dir" remote add origin "git@github.com-my-alias:owner/repo"

	_restore_canonical_remote_url "$sibling_dir" "my-alias"

	local restored
	restored="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$restored" = "git@github.com:owner/repo" ]
}

@test "SR-restore: restore is no-op when URL is already canonical" {
	_ssh_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-noop"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -b main >/dev/null 2>&1
	git -C "$sibling_dir" remote add origin "git@github.com:owner/repo.git"

	run _restore_canonical_remote_url "$sibling_dir" "some-alias"
	[ "$status" -eq 0 ]

	local url
	url="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$url" = "git@github.com:owner/repo.git" ]
}

# ── T4-RED: SR-rw-url-foreign — restore is no-op on foreign alias ─────────────

@test "SR-rw-url-foreign: restore is no-op with warn when URL aliased to different sibling" {
	_ssh_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-foreign"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -b main >/dev/null 2>&1
	# Pre-aliased to "other-alias", not the alias we expect
	git -C "$sibling_dir" remote add origin "git@github.com-other-alias:owner/repo.git"

	run _restore_canonical_remote_url "$sibling_dir" "my-alias"
	[ "$status" -eq 0 ]

	# URL should remain unchanged
	local url
	url="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$url" = "git@github.com-other-alias:owner/repo.git" ]
}

@test "SR-rw-url-foreign: restore is no-op when .git/ is absent" {
	_ssh_setup

	local sibling_dir="$BATS_TEST_TMPDIR/sibling-no-git"
	mkdir -p "$sibling_dir"

	run _restore_canonical_remote_url "$sibling_dir" "my-alias"
	[ "$status" -eq 0 ]
}

# ── T5-RED: SR-rw-key — key generation ───────────────────────────────────────

@test "SR-rw-key: _generate_sibling_deploy_key creates private key (0600) and pub (0644)" {
	_ssh_setup

	run _generate_sibling_deploy_key "testsibling"
	[ "$status" -eq 0 ]

	local key_path="$FAKE_HOME/.config/drydock/keys/testsibling_deploy"
	[ -f "$key_path" ]
	[ -f "${key_path}.pub" ]

	local priv_perms pub_perms
	priv_perms="$(stat -c '%a' "$key_path")"
	pub_perms="$(stat -c '%a' "${key_path}.pub")"
	[ "$priv_perms" = "600" ]
	[ "$pub_perms" = "644" ]
}

@test "SR-rw-key: _generate_sibling_deploy_key is idempotent — reuses existing key" {
	_ssh_setup

	# First call: generate
	_generate_sibling_deploy_key "reusetest"

	local key_path="$FAKE_HOME/.config/drydock/keys/reusetest_deploy"
	local mtime1
	mtime1="$(stat -c '%Y' "$key_path")"

	# Wait a tick to make mtime differences detectable
	sleep 1

	# Second call: must reuse
	_generate_sibling_deploy_key "reusetest"
	local mtime2
	mtime2="$(stat -c '%Y' "$key_path")"

	[ "$mtime1" = "$mtime2" ]
}

@test "SR-rw-key: _generate_sibling_deploy_key returns the key path on stdout" {
	_ssh_setup

	run _generate_sibling_deploy_key "pathtest"
	[ "$status" -eq 0 ]
	[ "$output" = "$FAKE_HOME/.config/drydock/keys/pathtest_deploy" ]
}

# ── T6-RED: _check_sibling_basename_collision_rw ──────────────────────────────

@test "_check_sibling_basename_collision_rw: different canonical path with same sanitized name — non-zero exit" {
	_ssh_setup

	local list_file="$FAKE_HOME/.config/drydock/links/test.list"
	mkdir -p "$(dirname "$list_file")"

	# Seed the list with an existing rw entry for /projects/foo
	printf '/projects/foo|/workspace-siblings/foo|rw\n' >"$list_file"

	# Generate the key for "foo" (as if /projects/foo was linked)
	_generate_sibling_deploy_key "foo" >/dev/null

	# Now try a different canonical path with same basename
	run _check_sibling_basename_collision_rw "/other-dir/foo" "foo" "$list_file"
	[ "$status" -ne 0 ]
	[[ "$output" =~ "collision" ]]
}

@test "_check_sibling_basename_collision_rw: same canonical path — exit 0 (idempotent)" {
	_ssh_setup

	local list_file="$FAKE_HOME/.config/drydock/links/test.list"
	mkdir -p "$(dirname "$list_file")"

	printf '/projects/foo|/workspace-siblings/foo|rw\n' >"$list_file"
	_generate_sibling_deploy_key "foo" >/dev/null

	# Same canonical path as existing entry — should pass
	run _check_sibling_basename_collision_rw "/projects/foo" "foo" "$list_file"
	[ "$status" -eq 0 ]
}

@test "_check_sibling_basename_collision_rw: no existing entry — exit 0" {
	_ssh_setup

	local list_file="$FAKE_HOME/.config/drydock/links/test.list"
	# No list file at all

	run _check_sibling_basename_collision_rw "/projects/newsibling" "newsibling" "$list_file"
	[ "$status" -eq 0 ]
}

# ── FIX-1 / #89: _validate_sibling_remote_url is read-only ────────────────────
#
# Originally extracted as the partial-link guard in front of the now-deleted
# _rewrite_sibling_remote_url. Post-#89 the validator is the up-front URL
# acceptance gate in cmd_link --rw: any malformed remote rejects the link
# before key-gen and .list write run. The validator MUST NOT mutate the
# sibling .git/config.

@test "FIX-1: _validate_sibling_remote_url exists and is callable" {
	_ssh_setup
	# Existence + minimal happy-path call (canonical URL, returns 0)
	local sibling_dir="$BATS_TEST_TMPDIR/sibling-validate-exists"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -b main >/dev/null 2>&1
	git -C "$sibling_dir" remote add origin "git@github.com:owner/repo.git"

	run _validate_sibling_remote_url "$sibling_dir" "sibling-validate-exists"
	[ "$status" -eq 0 ]
}

@test "FIX-1: _validate_sibling_remote_url does NOT mutate URL on canonical input" {
	_ssh_setup
	local sibling_dir="$BATS_TEST_TMPDIR/sibling-validate-canonical"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -b main >/dev/null 2>&1
	git -C "$sibling_dir" remote add origin "git@github.com:owner/repo.git"

	local before
	before="$(git -C "$sibling_dir" remote get-url origin)"

	_validate_sibling_remote_url "$sibling_dir" "sibling-validate-canonical"

	local after
	after="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$before" = "$after" ]
	[ "$after" = "git@github.com:owner/repo.git" ]
}

@test "FIX-1: _validate_sibling_remote_url is idempotent on already-aliased same-alias URL" {
	_ssh_setup
	local sibling_dir="$BATS_TEST_TMPDIR/sibling-validate-idempotent"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -b main >/dev/null 2>&1
	git -C "$sibling_dir" remote add origin "git@github.com-sibling-validate-idempotent:owner/repo.git"

	local before
	before="$(git -C "$sibling_dir" remote get-url origin)"

	_validate_sibling_remote_url "$sibling_dir" "sibling-validate-idempotent"

	local after
	after="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$before" = "$after" ]
}

@test "FIX-1: _validate_sibling_remote_url rejects different-alias URL without mutating" {
	_ssh_setup
	local sibling_dir="$BATS_TEST_TMPDIR/sibling-validate-foreign"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -b main >/dev/null 2>&1
	git -C "$sibling_dir" remote add origin "git@github.com-other-sibling:owner/repo.git"

	local before
	before="$(git -C "$sibling_dir" remote get-url origin)"

	run _validate_sibling_remote_url "$sibling_dir" "expected-alias"
	[ "$status" -ne 0 ]
	[[ "$output" =~ "other-sibling" ]] || [[ "$output" =~ "manual cleanup" ]]

	# .git/config URL must remain unmodified
	local after
	after="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$before" = "$after" ]
}

@test "FIX-1: _validate_sibling_remote_url rejects HTTPS URL without mutating" {
	_ssh_setup
	local sibling_dir="$BATS_TEST_TMPDIR/sibling-validate-https"
	mkdir -p "$sibling_dir"
	git -C "$sibling_dir" init -b main >/dev/null 2>&1
	git -C "$sibling_dir" remote add origin "https://github.com/owner/repo.git"

	local before
	before="$(git -C "$sibling_dir" remote get-url origin)"

	run _validate_sibling_remote_url "$sibling_dir" "https-sibling"
	[ "$status" -ne 0 ]

	local after
	after="$(git -C "$sibling_dir" remote get-url origin)"
	[ "$before" = "$after" ]
}

# ── JD1-X-RED: cross-project basename collision detection ────────────────────

@test "JD1-X: cross-project collision — same sanitized basename in another project's .list is detected" {
	_ssh_setup

	local links_dir="$FAKE_HOME/.config/drydock/links"
	mkdir -p "$links_dir"
	mkdir -p "$FAKE_HOME/.config/drydock/keys"

	# Project A already linked ~/groupA/lib as RW.
	local list_a="$links_dir/projectA.list"
	printf '/home/user/groupA/lib|/workspace-siblings/lib|rw\n' >"$list_a"

	# Simulate the existing key (created by project A's link).
	touch "$FAKE_HOME/.config/drydock/keys/lib_deploy"

	# Project B's .list is empty for this basename.
	local list_b="$links_dir/projectB.list"
	touch "$list_b"

	# Call collision check for project B trying to link ~/groupB/lib.
	run _check_sibling_basename_collision_rw "/home/user/groupB/lib" "lib" "$list_b"
	[ "$status" -ne 0 ]
	# Error must mention the conflicting sibling from project A
	[[ "$output" == *"groupA/lib"* ]]
	# Error must mention the owning project
	[[ "$output" == *"projectA"* ]]
}
