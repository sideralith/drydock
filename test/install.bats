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
	printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' "%s"\n' "$_os" >"$_dir/uname"
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

# ── T-04: ask() helper RED tests ─────────────────────────────────────────────
# These tests verify ask() behavior indirectly through ask_engram_mode(),
# which is the first prompt that calls ask(). Tests assert POSITIVE outcomes
# that require the production code to exist → proper RED before implementation.

@test "ask(): interactive + y answer → sentinel created (ask() reads TTY)" {
	# DRYDOCK_INTERACTIVE=1, native Linux, _DRYDOCK_TTY provides 'y'
	# → ask() must read the FIFO and return 'y' → sentinel IS created
	# Fails RED: ask_engram_mode() / ask() don't exist yet
	local _home="$BATS_TEST_TMPDIR/home-ask-y"
	local _tty="$BATS_TEST_TMPDIR/ask-tty-y"
	printf 'y\n' >"$_tty" # regular file: ask() opens it via exec 3<

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		bash "$INSTALL_SH"
	assert_success
	assert [ -f "$_home/.config/drydock/engram-shared" ]
}

@test "ask(): empty input (newline only) applies default n — sentinel not created" {
	# ask() reads FIFO containing only a newline → empty → default n → sentinel absent
	# Fails RED: ask_engram_mode() / ask() don't exist yet
	# (Once implemented: sentinel absent is the correct conservative default)
	local _home="$BATS_TEST_TMPDIR/home-ask-empty"
	local _tty="$BATS_TEST_TMPDIR/ask-tty-empty"
	printf '\n' >"$_tty" # only a newline → empty answer → default

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		bash "$INSTALL_SH"
	assert_success
	# After implementation: ask() returns default 'n', so sentinel is absent
	refute [ -f "$_home/.config/drydock/engram-shared" ]
}

@test "ask(): TTY open failure falls back to default n — installer exits 0" {
	# _DRYDOCK_TTY points at non-existent path → ask() must use default, not abort
	# Fails RED: ask_engram_mode() / ask() don't exist yet
	# (Once implemented: sentinel absent + exit 0 is the correct behavior)
	local _home="$BATS_TEST_TMPDIR/home-ask-notty"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$BATS_TEST_TMPDIR/no-such-tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		bash "$INSTALL_SH"
	assert_success
	# After implementation: ask() falls back to default 'n', sentinel absent
	refute [ -f "$_home/.config/drydock/engram-shared" ]
}

# ── T-06/T-07: _host_shared_safe() + ask_engram_mode INV-5 trichotomy ────────
# Tests verify _host_shared_safe OS-detection via ask_engram_mode behavior.
# Implementation note: _host_shared_safe was implemented alongside ask() in T-05
# (needed by ask_engram_mode). These are approval tests validating the
# already-implemented trichotomy.

@test "_host_shared_safe: WSL2 — no prompt, sentinel NOT created" {
	# OSRELEASE_FILE contains 'microsoft' → _host_shared_safe returns 1
	# → ask_engram_mode silently skips; sentinel never written
	local _home="$BATS_TEST_TMPDIR/home-wsl2"
	local _tty="$BATS_TEST_TMPDIR/tty-wsl2"
	printf 'y\n' >"$_tty" # would say yes if prompt appeared

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/wsl2/osrelease" \
		HOME="$_home" \
		bash "$INSTALL_SH"
	assert_success
	refute [ -f "$_home/.config/drydock/engram-shared" ]
}

@test "_host_shared_safe: macOS (UNAME=Darwin) — no prompt, sentinel NOT created" {
	# UNAME stub returns Darwin → _host_shared_safe returns 1
	# → ask_engram_mode silently skips; sentinel never written
	local _home="$BATS_TEST_TMPDIR/home-macos"
	local _tty="$BATS_TEST_TMPDIR/tty-macos"
	printf 'y\n' >"$_tty" # would say yes if prompt appeared

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME="$FAKE_BIN/uname" \
		HOME="$_home" \
		bash "$INSTALL_SH"
	assert_success
	refute [ -f "$_home/.config/drydock/engram-shared" ]
}

@test "_host_shared_safe: native Linux + accept — sentinel created" {
	# Clean OSRELEASE_FILE, UNAME=uname (Linux) → _host_shared_safe returns 0
	# → ask_engram_mode fires; 'y' → sentinel IS created
	local _home="$BATS_TEST_TMPDIR/home-native"
	local _tty="$BATS_TEST_TMPDIR/tty-native-y"
	printf 'y\n' >"$_tty"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		bash "$INSTALL_SH"
	assert_success
	assert [ -f "$_home/.config/drydock/engram-shared" ]
}

@test "_host_shared_safe: native Linux + decline — sentinel NOT created" {
	# Clean OSRELEASE_FILE, UNAME=uname (Linux) → ask fires; 'n' → no sentinel
	local _home="$BATS_TEST_TMPDIR/home-native-n"
	local _tty="$BATS_TEST_TMPDIR/tty-native-n"
	printf 'n\n' >"$_tty"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		bash "$INSTALL_SH"
	assert_success
	refute [ -f "$_home/.config/drydock/engram-shared" ]
}

# ── T-08: engram-mode prompt — non-interactive parity ────────────────────────
# Explicit non-interactive guard: DRYDOCK_INTERACTIVE=0 → sentinel not created.
# This is the parity contract test referenced in T-14.

@test "engram-mode: non-interactive (DRYDOCK_INTERACTIVE=0) — sentinel NOT created" {
	local _home="$BATS_TEST_TMPDIR/home-ni-engram"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=0 \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		bash "$INSTALL_SH"
	assert_success
	refute [ -f "$_home/.config/drydock/engram-shared" ]
}

# ── T-10: build-image prompt RED tests ───────────────────────────────────────
# HARD CONSTRAINT: every test path MUST use the bin/drydock stub from the
# seeded INSTALL_DIR. The real drydock binary MUST NEVER be invoked.
# ask_build_image() calls "$DRYDOCK_INSTALL_DIR/bin/drydock" build (absolute
# path) — DRYDOCK_INSTALL_DIR seam ensures the stub is always used.
#
# Setup helper for build tests: pre-seed INSTALL_DIR with a .git marker and
# a custom bin/drydock stub so do_clone() skips (existing clone path).

_setup_build_stub() {
	local _dir="$1" _exit="$2"
	mkdir -p "$_dir/.git" "$_dir/bin" "$_dir/lib"
	touch "$_dir/lib/common.sh"
	printf '#!/usr/bin/env bash\nexit %s\n' "$_exit" >"$_dir/bin/drydock"
	chmod +x "$_dir/bin/drydock"
}

@test "build-image: non-interactive — drydock build NOT invoked" {
	# DRYDOCK_INTERACTIVE=0 → ask_build_image() must be a no-op
	# Verify: stub would exit 1 if called; overall exit must still be 0
	local _install="$BATS_TEST_TMPDIR/build-ni-install"
	local _log="$BATS_TEST_TMPDIR/build-ni.log"
	mkdir -p "$_install/.git" "$_install/bin" "$_install/lib"
	touch "$_install/lib/common.sh"
	# Write a stub that logs its call and exits 1 — if called, test must fail
	printf '#!/usr/bin/env bash\nprintf "STUB_CALLED\n" >%s\nexit 1\n' "$_log" \
		>"$_install/bin/drydock"
	chmod +x "$_install/bin/drydock"

	run env DRYDOCK_INSTALL_DIR="$_install" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=0 \
		HOME="$BATS_TEST_TMPDIR/home-build-ni" \
		bash "$INSTALL_SH"
	assert_success
	refute [ -f "$_log" ]
}

@test "build-image: interactive + accept + build succeeds — stub invoked, exit 0" {
	# ask_build_image() fires, user says 'y', stub exits 0 → install exits 0
	# stub records its invocation in a log file; assert log exists (RED: stub not called yet)
	local _install="$BATS_TEST_TMPDIR/build-ok-install"
	local _log="$BATS_TEST_TMPDIR/build-ok.log"
	mkdir -p "$_install/.git" "$_install/bin" "$_install/lib"
	touch "$_install/lib/common.sh"
	printf '#!/usr/bin/env bash\nprintf "DRYDOCK_BUILD_CALLED %%s\n" "$@" >%s\nexit 0\n' "$_log" \
		>"$_install/bin/drydock"
	chmod +x "$_install/bin/drydock"
	local _tty="$BATS_TEST_TMPDIR/tty-build-ok"
	# Two prompts: engram-mode ('n') then build-image ('y')
	printf 'n\ny\n' >"$_tty"

	run env DRYDOCK_INSTALL_DIR="$_install" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$BATS_TEST_TMPDIR/home-build-ok" \
		bash "$INSTALL_SH"
	assert_success
	# Fails RED: ask_build_image() doesn't call the stub yet
	assert [ -f "$_log" ]
}

@test "build-image: interactive + accept + build fails — warn + exit 0" {
	# ask_build_image() fires, user says 'y', stub exits 1 → build-specific warn + exit 0
	# Fails RED: ask_build_image() does not exist yet
	local _install="$BATS_TEST_TMPDIR/build-fail-install"
	_setup_build_stub "$_install" 1
	local _tty="$BATS_TEST_TMPDIR/tty-build-fail"
	printf 'n\ny\n' >"$_tty"

	run env DRYDOCK_INSTALL_DIR="$_install" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$BATS_TEST_TMPDIR/home-build-fail" \
		bash "$INSTALL_SH"
	assert_success
	# Fails RED: ask_build_image() doesn't produce this specific warning yet
	assert_output --partial "build failed"
}

@test "build-image: interactive + decline — drydock build NOT invoked" {
	# ask_build_image() fires, user says 'n' → stub must NOT be invoked
	# Fails RED: ask_build_image() does not exist yet
	local _install="$BATS_TEST_TMPDIR/build-decline-install"
	local _log="$BATS_TEST_TMPDIR/build-decline.log"
	mkdir -p "$_install/.git" "$_install/bin" "$_install/lib"
	touch "$_install/lib/common.sh"
	printf '#!/usr/bin/env bash\nprintf "STUB_CALLED\n" >%s\nexit 0\n' "$_log" \
		>"$_install/bin/drydock"
	chmod +x "$_install/bin/drydock"
	local _tty="$BATS_TEST_TMPDIR/tty-build-decline"
	printf 'n\nn\n' >"$_tty" # engram: n, build: n

	run env DRYDOCK_INSTALL_DIR="$_install" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$BATS_TEST_TMPDIR/home-build-decline" \
		bash "$INSTALL_SH"
	assert_success
	refute [ -f "$_log" ]
}

# ── T-12: PATH rc-append + rc-select RED tests ────────────────────────────────
# Helper: run install.sh with custom HOME and PATH that does NOT include BIN_DIR,
# plus a pre-configured tty file for sequential prompt answers.
# Returns nothing; callers use $output and the rc file state.
#
# ask_add_path_to_rc replaces check_path.
# Prompts in order on native Linux: engram-mode, build-image, add-to-PATH.

@test "path-rc: non-interactive warns only, rc NOT modified" {
	# DRYDOCK_INTERACTIVE=0 → warn+hint behavior preserved (check_path byte-identical)
	local _home="$BATS_TEST_TMPDIR/home-path-ni"
	mkdir -p "$_home"
	printf '' >"$_home/.bashrc"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=0 \
		HOME="$_home" \
		bash "$INSTALL_SH"
	assert_success
	assert_output --partial "not in PATH"
	# rc file must be unchanged (empty)
	assert [ ! -s "$_home/.bashrc" ]
}

@test "path-rc: interactive + PATH already includes BIN_DIR — no prompt" {
	# When BIN_DIR is already in PATH, ask_add_path_to_rc must not prompt
	# Passes trivially (no prompt assertion) but validates parity
	local _home="$BATS_TEST_TMPDIR/home-path-in-path"
	mkdir -p "$_home"
	local _tty="$BATS_TEST_TMPDIR/tty-path-in-path"
	printf 'n\nn\n' >"$_tty" # engram: n, build: n; no 3rd prompt expected

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		PATH="$BIN_DIR:$PATH" \
		bash "$INSTALL_SH"
	assert_success
}

@test "path-rc: interactive + accept — export line appended to rc" {
	# ask_add_path_to_rc fires, user says 'y' → export line appended
	# Fails RED: ask_add_path_to_rc doesn't exist yet
	local _home="$BATS_TEST_TMPDIR/home-path-append"
	mkdir -p "$_home"
	touch "$_home/.bashrc"
	local _tty="$BATS_TEST_TMPDIR/tty-path-append"
	# Prompts: engram:n, build:n, path:y
	printf 'n\nn\ny\n' >"$_tty"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		SHELL=/bin/bash \
		bash "$INSTALL_SH"
	assert_success
	# Fails RED: export line not appended yet
	assert_output --partial 'export PATH'
	run grep -Fxc "export PATH=\"\$HOME/.local/bin:\$PATH\"" "$_home/.bashrc"
	assert_output 1
}

@test "path-rc: idempotent — re-run does not double-append" {
	# Run twice with same rc fixture; assert export line appears exactly once
	# Fails RED: idempotent guard not implemented yet
	local _home="$BATS_TEST_TMPDIR/home-path-idemp"
	mkdir -p "$_home"
	touch "$_home/.bashrc"
	local _tty="$BATS_TEST_TMPDIR/tty-idemp1"
	printf 'n\nn\ny\n' >"$_tty"

	# First run
	env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		SHELL=/bin/bash \
		bash "$INSTALL_SH" >/dev/null 2>&1 || true

	local _tty2="$BATS_TEST_TMPDIR/tty-idemp2"
	printf 'n\nn\ny\n' >"$_tty2"

	# Second run
	env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty2" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		SHELL=/bin/bash \
		bash "$INSTALL_SH" >/dev/null 2>&1 || true

	# Assert exactly one copy
	run grep -Fc "export PATH=\"\$HOME/.local/bin:\$PATH\"" "$_home/.bashrc"
	assert_output 1
}

@test "path-rc: interactive + decline — rc NOT modified" {
	# ask_add_path_to_rc fires, user says 'n' → rc unchanged
	# Passes trivially for now (no modification without implementation either)
	local _home="$BATS_TEST_TMPDIR/home-path-decline"
	mkdir -p "$_home"
	touch "$_home/.bashrc"
	local _tty="$BATS_TEST_TMPDIR/tty-path-decline"
	printf 'n\nn\nn\n' >"$_tty"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		SHELL=/bin/bash \
		bash "$INSTALL_SH"
	assert_success
	refute [ -s "$_home/.bashrc" ]
}

@test "path-rc: ambiguous SHELL + multiple rc candidates — numbered prompt fires" {
	# SHELL empty, both .bashrc and .zshrc exist → rc-select prompt appears
	# Fails RED: rc-file selection not implemented yet
	local _home="$BATS_TEST_TMPDIR/home-path-ambig"
	mkdir -p "$_home"
	touch "$_home/.bashrc" "$_home/.zshrc"
	local _tty="$BATS_TEST_TMPDIR/tty-path-ambig"
	# Prompts: engram:n, build:n, path:y, rc-select:1
	printf 'n\nn\ny\n1\n' >"$_tty"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		SHELL="" \
		bash "$INSTALL_SH"
	assert_success
	# Fails RED: numbered rc-select prompt not shown yet
	assert_output --partial "1)"
}

@test "path-rc: unambiguous SHELL=/bin/bash + only .bashrc — no rc-select prompt" {
	# SHELL=/bin/bash, only .bashrc exists → auto-detect, no numbered prompt
	local _home="$BATS_TEST_TMPDIR/home-path-unamb"
	mkdir -p "$_home"
	touch "$_home/.bashrc"
	local _tty="$BATS_TEST_TMPDIR/tty-path-unamb"
	printf 'n\nn\ny\n' >"$_tty" # only 3 prompts, no rc-select

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		SHELL=/bin/bash \
		bash "$INSTALL_SH"
	assert_success
	# No numbered prompt: assert no "1)" or "2)" in output
	refute_output --partial "1)"
}

# ── T-13: CRITICAL bug regression tests ──────────────────────────────────────

@test "path-rc: CRITICAL-1 — empty _candidates does not abort installer (grep -c . exit-1)" {
	# SHELL="" + NO rc files in HOME → _rc_candidates returns empty string.
	# Bug: grep -c . on empty input exits 1 → set -e aborts installer before
	# the fallback _rc="$HOME/.bashrc" can run.
	# RED: installer exits non-zero. GREEN: exits 0 and .bashrc is created+written.
	local _home="$BATS_TEST_TMPDIR/home-crit1"
	mkdir -p "$_home"
	# No .bashrc, .zshrc, or .profile — empty candidates

	local _tty="$BATS_TEST_TMPDIR/tty-crit1"
	# Prompts: engram:n, build:n, path:y
	printf 'n\nn\ny\n' >"$_tty"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		SHELL="" \
		bash "$INSTALL_SH"
	# Bug: exits non-zero. Fix: exits 0 and creates .bashrc with export line.
	assert_success
	assert [ -f "$_home/.bashrc" ]
	run grep -Fc "export PATH=" "$_home/.bashrc"
	assert_output 1
}

@test "path-rc: CRITICAL-2 — choice '0' does not abort installer (sed -n 0p invalid address)" {
	# SHELL="" + both .bashrc and .zshrc exist → numbered prompt fires.
	# Bug: user types '0' → sed -n "0p" is an invalid line address → sed exits
	# non-zero → set -e aborts installer.
	# RED: installer exits non-zero. GREEN: exits 0 and defaults to candidate 1.
	local _home="$BATS_TEST_TMPDIR/home-crit2"
	mkdir -p "$_home"
	touch "$_home/.bashrc" "$_home/.zshrc"

	local _tty="$BATS_TEST_TMPDIR/tty-crit2"
	# Prompts: engram:n, build:n, path:y, rc-select:0 (invalid → default to 1)
	printf 'n\nn\ny\n0\n' >"$_tty"

	run env DRYDOCK_INSTALL_DIR="$INSTALL_DIR" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=1 \
		_DRYDOCK_TTY="$_tty" \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		SHELL="" \
		bash "$INSTALL_SH"
	# Bug: exits non-zero. Fix: exits 0 and falls back to candidate 1 (.bashrc).
	assert_success
	run grep -Fc "export PATH=" "$_home/.bashrc"
	assert_output 1
}

# ── T-14/T-15: Non-interactive parity regression guards ──────────────────────
# Explicit parity assertions: DRYDOCK_INTERACTIVE=0 (pipe-install / curl|bash)
# MUST produce byte-identical non-interactive behavior — no sentinel, no build,
# no rc modification — and exit 0. These are regression guards that survive
# future refactors even if the per-feature tests above are changed.

@test "parity(NI): no engram sentinel, no build, no rc change, exit 0" {
	# Combined non-interactive parity: one single run asserts ALL three
	# interactive features are suppressed when DRYDOCK_INTERACTIVE=0
	local _home="$BATS_TEST_TMPDIR/home-parity"
	mkdir -p "$_home"
	touch "$_home/.bashrc"

	# Pre-seed INSTALL_DIR: avoids clone, provides a callable bin/drydock stub
	local _install="$BATS_TEST_TMPDIR/parity-install"
	local _build_log="$BATS_TEST_TMPDIR/parity-build.log"
	mkdir -p "$_install/.git" "$_install/bin" "$_install/lib"
	touch "$_install/lib/common.sh"
	# Stub that would fail loudly if ever called
	printf '#!/usr/bin/env bash\nprintf "PARITY_STUB_CALLED\n" >%s\nexit 1\n' "$_build_log" \
		>"$_install/bin/drydock"
	chmod +x "$_install/bin/drydock"

	run env DRYDOCK_INSTALL_DIR="$_install" \
		DRYDOCK_BIN_DIR="$BIN_DIR" \
		DRYDOCK_REPO_URL="$BARE_REPO" \
		DRYDOCK_INTERACTIVE=0 \
		UNAME=uname \
		OSRELEASE_FILE="$OSRELEASE_DIR/native/osrelease" \
		HOME="$_home" \
		bash "$INSTALL_SH"

	# Exit 0 — install must succeed
	assert_success
	# No engram sentinel
	refute [ -f "$_home/.config/drydock/engram-shared" ]
	# bin/drydock build stub NOT called
	refute [ -f "$_build_log" ]
	# rc file not modified (still empty / unchanged)
	assert [ ! -s "$_home/.bashrc" ]
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
