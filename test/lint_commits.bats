#!/usr/bin/env bats
# test/lint_commits.bats — tests for scripts/lint-commits.sh
#
# Each test creates an isolated git repo under BATS_TEST_TMPDIR.
# Always run via: scripts/test.sh   (not `bats test/` directly — see CONTRIBUTING.md)

load "helpers/load"

# ── Shared helpers ────────────────────────────────────────────────────────────

# _lc_setup: initialise a fresh git repo with one seed commit.
# Sets REPO and BASE in the calling test's environment.
_lc_setup() {
	REPO="$BATS_TEST_TMPDIR/repo"
	git -c init.defaultBranch=main init "$REPO" >/dev/null 2>&1
	git -C "$REPO" -c user.email=t@t.com -c user.name=T \
		commit --allow-empty -m "feat: seed" >/dev/null 2>&1
	BASE=$(git -C "$REPO" rev-parse HEAD)
	# Note: the script reads git state from CWD; tests run with `run env -C "$REPO" ...`
	# or by cd-ing into $REPO before running.  No system-dir paths are touched — the
	# script only calls `git log` and `git rev-parse`; no _lc_setup guard needed.
}

# _lc_commit: add a commit with an exact subject to $REPO.
_lc_commit() {
	local subject=$1
	git -C "$REPO" -c user.email=t@t.com -c user.name=T \
		commit --allow-empty -m "$subject" >/dev/null 2>&1
}

# ── Phase A: Scaffolding ──────────────────────────────────────────────────────

# T-2: trivial smoke test — --help exits 0 (confirms bats picks up the file).
@test "--help exits 0 (smoke)" {
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --help
	[ "$status" -eq 0 ]
}

# ── T-4 RED / T-5 GREEN: REQ-10 --help / -h (S-9) ────────────────────────────

@test "REQ-10: --help exits 0 and output contains --base" {
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --help
	[ "$status" -eq 0 ]
	[[ "$output" =~ "--base" ]]
}

@test "REQ-10: -h exits 0 and output contains --base" {
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" -h
	[ "$status" -eq 0 ]
	[[ "$output" =~ "--base" ]]
}

# ── T-6 RED / T-7 GREEN: REQ-3/REQ-6 passing commits (S-1, S-5a-g, S-6a-c) ──

@test "REQ-6/S-1: feat: foo passes and prints 1 commit(s) checked, all OK" {
	_lc_setup
	_lc_commit "feat: foo"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

@test "REQ-6/S-5a: feat: add thing passes" {
	_lc_setup
	_lc_commit "feat: add thing"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

@test "REQ-6/S-5b: fix: correct typo passes" {
	_lc_setup
	_lc_commit "fix: correct typo"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

@test "REQ-6/S-5c: docs: update readme passes" {
	_lc_setup
	_lc_commit "docs: update readme"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

@test "REQ-6/S-5d: refactor: extract fn passes" {
	_lc_setup
	_lc_commit "refactor: extract fn"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

@test "REQ-6/S-5e: test: cover edge case passes" {
	_lc_setup
	_lc_commit "test: cover edge case"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

@test "REQ-6/S-5f: style: fix whitespace passes" {
	_lc_setup
	_lc_commit "style: fix whitespace"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

@test "REQ-6/S-5g: chore: update deps passes" {
	_lc_setup
	_lc_commit "chore: update deps"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

@test "REQ-6/S-6b: feat(ci): foo (alphanumeric scope) passes" {
	_lc_setup
	_lc_commit "feat(ci): foo"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

@test "REQ-6/S-6c: feat(foo bar): foo (scope with space) passes" {
	_lc_setup
	_lc_commit "feat(foo bar): foo"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

# ── T-8 RED / T-9 GREEN: REQ-3 non-conformant commits (S-2, S-13, S-14, S-15) ─

@test "REQ-3/S-2: fixed thing fails with exit 1 and short SHA in output" {
	_lc_setup
	_lc_commit "fixed thing"
	local sha
	sha=$(git -C "$REPO" rev-parse HEAD)
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 1 ]
	[[ "$output" =~ "${sha:0:7}" ]]
	[[ "$output" =~ "fixed thing" ]]
}

@test "REQ-3/S-13: Feat: foo (uppercase type) fails with exit 1" {
	_lc_setup
	_lc_commit "Feat: foo"
	local sha
	sha=$(git -C "$REPO" rev-parse HEAD)
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 1 ]
	[[ "$output" =~ "${sha:0:7}" ]]
}

@test "REQ-3/S-14: feat:no-space fails with exit 1" {
	_lc_setup
	_lc_commit "feat:no-space"
	local sha
	sha=$(git -C "$REPO" rev-parse HEAD)
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 1 ]
	[[ "$output" =~ "${sha:0:7}" ]]
}

@test "REQ-3/S-15: feat:   (trailing whitespace only subject) fails with exit 1" {
	_lc_setup
	# "feat:   " — trailing spaces, empty description after stripping
	_lc_commit "feat:   "
	local sha
	sha=$(git -C "$REPO" rev-parse HEAD)
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 1 ]
	[[ "$output" =~ "${sha:0:7}" ]]
}

# ── T-10 RED / T-11 GREEN: REQ-5 collect-then-fail (S-3) ─────────────────────

@test "REQ-5/S-3: mixed PR — both violations reported (collect-then-fail)" {
	_lc_setup
	_lc_commit "feat: ok"
	_lc_commit "WIP: broken"
	local sha_wip
	sha_wip=$(git -C "$REPO" rev-parse HEAD)
	_lc_commit "feat: another ok"
	_lc_commit "bad commit"
	local sha_bad
	sha_bad=$(git -C "$REPO" rev-parse HEAD)
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 1 ]
	[[ "$output" =~ "${sha_wip:0:7}" ]]
	[[ "$output" =~ "${sha_bad:0:7}" ]]
}

# ── T-12 RED / T-13 RED / T-14 GREEN: REQ-4 merge commit skipping (S-4) ──────

@test "REQ-4/S-4/LC-skip-github-merge: real merge commit skipped via --no-merges" {
	_lc_setup
	# Create a feature branch, commit conformant subject on it, merge back to main.
	# The merge commit subject is non-conformant; it must be skipped.
	git -C "$REPO" checkout -b feature >/dev/null 2>&1
	_lc_commit "feat: feature work"
	git -C "$REPO" checkout main >/dev/null 2>&1
	git -C "$REPO" -c user.email=t@t.com -c user.name=T \
		merge --no-ff feature -m "Merge pull request #1 from foo/bar" >/dev/null 2>&1
	cd "$REPO"
	# Range has: feat: feature work (conformant) + merge commit (non-conformant subject).
	# With --no-merges, the merge commit is excluded. Only the branch commit is checked.
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
}

@test "REQ-4/S-4/LC-skip-rebase-merge: single-parent rebase artifact skipped via regex" {
	_lc_setup
	# Commit a single-parent commit with a "Merge branch..." subject (rebase artifact).
	# --no-merges won't catch it (single parent), but ^Merge regex should skip it.
	# S-4: all commits skipped → count must be 0, not 1.
	_lc_commit "Merge branch 'dev' into feat/x"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "0 commit(s) checked, all OK" ]]
}

# ── T-15 RED / T-16 GREEN: REQ-13 empty commit range (S-10) ──────────────────

@test "REQ-13/S-10/LC-pass-empty-range: empty range exits 0 with 0 commit(s) checked, all OK" {
	_lc_setup
	# No commits added after BASE — range is empty.
	local empty_base
	empty_base=$(git -C "$REPO" rev-parse HEAD)
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$empty_base"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "0 commit(s) checked, all OK" ]]
}

# ── T-17 RED / T-18 GREEN: REQ-8 explicit --base (LC-base-explicit) ──────────

@test "REQ-8/LC-base-explicit: --base <sha> checks exactly the commits past base" {
	_lc_setup
	_lc_commit "feat: first"
	_lc_commit "fix: second"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "$BASE"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "2 commit(s) checked, all OK" ]]
}

# ── T-19 RED / T-20 GREEN: exit 3 on invalid --base SHA ──────────────────────

@test "LC-base-error-invalid-sha: invalid --base exits 3 with error message" {
	_lc_setup
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --base "deadbeef000"
	[ "$status" -eq 3 ]
	[[ "$output" =~ "not a valid git commit" ]]
}

# ── T-21 RED / T-22 GREEN: exit 2 on unknown flag ────────────────────────────

@test "LC-usage-unknown-flag: unknown flag exits 2 with error message" {
	_lc_setup
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh" --foo
	[ "$status" -eq 2 ]
	[[ "$output" =~ "unknown flag" ]]
}

# ── T-23 RED / T-24 RED / T-25 GREEN: REQ-7/REQ-9 auto-detect (S-8, S-11, S-12) ─

@test "REQ-7/S-8/LC-base-autodetect: auto-detects base via origin/dev when present" {
	_lc_setup
	# Set up a bare remote with a dev branch, add as origin, push, fetch.
	local bare="$BATS_TEST_TMPDIR/bare.git"
	git -c init.defaultBranch=main init --bare "$bare" >/dev/null 2>&1
	git -C "$REPO" remote add origin "$bare" >/dev/null 2>&1
	git -C "$REPO" push origin main >/dev/null 2>&1
	# Create a dev branch on the remote (push current HEAD as dev)
	git -C "$REPO" push origin main:dev >/dev/null 2>&1
	git -C "$REPO" fetch origin >/dev/null 2>&1
	# Now add a conformant commit past origin/dev
	_lc_commit "feat: autodetect test"
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh"
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1 commit(s) checked, all OK" ]]
}

@test "REQ-9/S-12/LC-base-autodetect-fail: no origin/dev and fetch fails exits 3" {
	_lc_setup
	# Repo has no remote — auto-detect must fail loudly with exit 3.
	cd "$REPO"
	run "$DRYDOCK_HOME/scripts/lint-commits.sh"
	[ "$status" -eq 3 ]
	[[ "$output" =~ "origin/dev" ]]
}
