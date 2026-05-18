#!/usr/bin/env bash
# test/install.bats — tests for install.sh (drydock installer)
# Run: bats test/install.bats

# ── Fixture helpers ───────────────────────────────────────────────────────────

# make_fifo <path> <answer>
# Create a FIFO at <path> seeded with <answer>\n in the background.
# The background printf exits after writing; the FIFO blocks until install.sh
# reads it. Cleans up automatically via teardown (BATS_TEST_TMPDIR is wiped).
make_fifo() {
	local _path="$1" _answer="$2"
	mkfifo "$_path"
	printf '%s\n' "$_answer" >"$_path" &
}

# make_uname_stub <dir> <os>
# Write a uname stub into <dir> that echoes <os> when called with -s.
make_uname_stub() {
	local _dir="$1" _os="$2"
	printf '#!/usr/bin/env bash\nprintf '"'"'%s\n'"'"' "%s"\n' "$_os" >"$_dir/uname"
	chmod +x "$_dir/uname"
}

# make_osrelease_fixture <dir> <content>
# Write a fake /proc/sys/kernel/osrelease file with the given content.
make_osrelease_fixture() {
	local _dir="$1" _content="$2"
	mkdir -p "$_dir"
	printf '%s\n' "$_content" >"$_dir/osrelease"
}

# make_drydock_stub <dir> <exit_code>
# Write a bin/drydock stub into <dir> that exits with <exit_code>.
# Used by build-image prompt tests to avoid triggering a real drydock build.
make_drydock_stub() {
	local _dir="$1" _exit="$2"
	mkdir -p "$_dir"
	printf '#!/usr/bin/env bash\nexit %s\n' "$_exit" >"$_dir/drydock"
	chmod +x "$_dir/drydock"
}

setup() {
	load 'test_helper/bats-support/load'
	load 'test_helper/bats-assert/load'

	INSTALL_DIR="$BATS_TEST_TMPDIR/drydock-install"
	BIN_DIR="$BATS_TEST_TMPDIR/drydock-bin"

	# Copy install.sh to tmp so BASH_SOURCE resolves outside the repo,
	# preventing LOCAL_MODE from being triggered when bin/drydock + lib/ are present.
	INSTALL_SH="$BATS_TEST_TMPDIR/install.sh"
	cp "$(pwd)/install.sh" "$INSTALL_SH"

	# Create a minimal local bare repo as DRYDOCK_REPO_URL seam.
	# Force `main` as the initial branch independent of host git config:
	# CI runners may default to `master` (legacy), but install.sh clones
	# `--branch main` so the fixture must have `main` regardless of host.
	BARE_REPO="$BATS_TEST_TMPDIR/bare.git"
	git -c init.defaultBranch=main init --bare "$BARE_REPO" >/dev/null 2>&1

	# Seed it with a minimal commit so clone succeeds
	local _work="$BATS_TEST_TMPDIR/seed-work"
	git clone "$BARE_REPO" "$_work" >/dev/null 2>&1
	# Belt-and-suspenders: ensure the work clone is on `main`, regardless
	# of host's init.defaultBranch (cloning an empty bare may not propagate).
	git -C "$_work" symbolic-ref HEAD refs/heads/main
	mkdir -p "$_work/bin" "$_work/lib"
	# bin/drydock stub in the bare repo: exits 0, records its call log.
	# The build-image prompt uses DRYDOCK_INSTALL_DIR/bin/drydock directly
	# (absolute path), so DRYDOCK_INSTALL_DIR must point at an install tree
	# whose bin/drydock is this stub — never the real binary.
	printf '#!/usr/bin/env bash\nexit 0\n' >"$_work/bin/drydock"
	chmod +x "$_work/bin/drydock"
	touch "$_work/lib/common.sh"
	git -C "$_work" add . >/dev/null 2>&1
	git -C "$_work" -c user.email=t@t.com -c user.name=T commit -m init >/dev/null 2>&1
	git -C "$_work" push >/dev/null 2>&1

	# OS-detection fixture directories
	OSRELEASE_DIR="$BATS_TEST_TMPDIR/osrelease-fixtures"
	FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin"
	mkdir -p "$OSRELEASE_DIR" "$FAKE_BIN"

	# Native Linux fixture: clean osrelease (no "microsoft")
	make_osrelease_fixture "$OSRELEASE_DIR/native" "6.1.0-generic"
	# WSL2 fixture: contains "microsoft"
	make_osrelease_fixture "$OSRELEASE_DIR/wsl2" "5.15.167.4-microsoft-standard-WSL2"
	# macOS is simulated via UNAME stub (no osrelease on macOS)
	make_uname_stub "$FAKE_BIN" "Darwin"
}

# Case 1: happy_path_fresh
@test "happy path: fresh install creates symlink" {
	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		bash "$INSTALL_SH"
	assert_success
	assert [ -L "$BIN_DIR/drydock" ]
	local _target
	_target="$(readlink "$BIN_DIR/drydock")"
	assert_equal "$_target" "$INSTALL_DIR/bin/drydock"
}

# Case 2: happy_path_idempotent
@test "idempotent: second run is a no-op" {
	env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		bash "$INSTALL_SH" >/dev/null 2>&1

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		bash "$INSTALL_SH"
	assert_success
	assert_output --partial "skipping clone"
}

# Case 3: missing_prereq_jq
@test "missing prereq jq: exit 1 with error message" {
	local _fake_bin="$BATS_TEST_TMPDIR/fake-bin"
	mkdir -p "$_fake_bin"
	# Stub docker: accepts 'compose version' subcommand
	printf '#!/usr/bin/env bash\n[ "$1" = "compose" ] && [ "$2" = "version" ] && { printf "Docker Compose version v2.30.0\\n"; exit 0; }; printf "Docker version 29.4.0\\n"; exit 0\n' \
		>"$_fake_bin/docker"
	chmod +x "$_fake_bin/docker"
	# Stub git
	printf '#!/usr/bin/env bash\nprintf "git version 2.39.0\\n"\n' >"$_fake_bin/git"
	chmod +x "$_fake_bin/git"
	# jq is intentionally absent; symlink everything else install.sh needs from /usr/bin
	# so we can use PATH=$_fake_bin as the complete PATH without jq.
	local _tool
	for _tool in bash sed cut head uname readlink mkdir ln pwd printf cat dirname; do
		[ -e "/usr/bin/$_tool" ] && ln -sf "/usr/bin/$_tool" "$_fake_bin/$_tool"
	done
	# Also need /bin essentials if they differ
	for _tool in bash sed cut head; do
		[ -e "/bin/$_tool" ] && [ ! -e "$_fake_bin/$_tool" ] && ln -sf "/bin/$_tool" "$_fake_bin/$_tool"
	done

	run env PATH="$_fake_bin" \
		DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		bash "$INSTALL_SH"
	assert_failure
	assert_output --partial "jq"
	assert_output --partial "apt-get install jq"
	assert_output --partial "brew install jq"
}

# Case 4: symlink_conflict_diff_target
@test "symlink conflict: different target aborts with both paths named" {
	mkdir -p "$BIN_DIR"
	ln -s /etc/hostname "$BIN_DIR/drydock"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		bash "$INSTALL_SH"
	assert_failure
	assert_output --partial "/etc/hostname"
	assert_output --partial "$INSTALL_DIR/bin/drydock"
}

# Case 5: tty_off_plain_text
@test "non-TTY output: no ANSI escape codes, no box-drawing chars" {
	run bash -c "env DRYDOCK_INSTALL_DIR='$INSTALL_DIR' \
		DRYDOCK_BIN_DIR='$BIN_DIR' \
		DRYDOCK_REPO_URL='$BARE_REPO' \
		bash '$INSTALL_SH' | cat"
	refute_output --regexp $'\033\['
	refute_output --partial '┌'
	assert_output --partial '[OK]'
}

# Case 6: env_overrides
@test "env overrides: all 4 vars respected" {
	local _custom_install="$BATS_TEST_TMPDIR/custom-install"
	local _custom_bin="$BATS_TEST_TMPDIR/custom-bin"
	run env DRYDOCK_INSTALL_DIR="$_custom_install" \
		DRYDOCK_BIN_DIR="$_custom_bin" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_BRANCH="main" \
		bash "$INSTALL_SH"
	assert_success
	assert [ -L "$_custom_bin/drydock" ]
	local _target
	_target="$(readlink "$_custom_bin/drydock")"
	assert_equal "$_target" "$_custom_install/bin/drydock"
}
