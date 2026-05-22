#!/usr/bin/env bats
# test/container_config_overlay.bats — unit + integration tests for
# apply_claude_overlay (lib/compose.sh, issue #77).
#
# Test seam: each test sets HOST_CLAUDE_OVERLAY to a tmp subdir so the
# source-time constant from lib/paths.sh is overridden per-test.  HOME is
# also overridden to keep seed_session_config_dir integration tests hermetic.

load "helpers/load"

setup() {
	# Mirror lib_compose.bats source order: common → paths → compose → sibling_ssh.
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/sibling_ssh.sh"

	# Stub cmd_setup so ensure_runtime_dirs is safe if anything edges toward it.
	cmd_setup() { :; }

	# Per-test fixture root.
	FIXTURE_HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$FIXTURE_HOME"
	export HOME="$FIXTURE_HOME"

	# session_dir: a per-session claude-container dir (pre-created, empty).
	SESSION_DIR="$FIXTURE_HOME/.claude-container-test"
	mkdir -p "$SESSION_DIR"

	# Overlay dir: each test creates or populates as needed.
	OVERLAY_DIR="$FIXTURE_HOME/.config/drydock/claude-overlay"

	# Override the source-time constant so apply_claude_overlay sees the fixture.
	HOST_CLAUDE_OVERLAY="$OVERLAY_DIR"

	# Minimal DOCKER stub for seed_session_config_dir integration tests.
	local _docker_stub="$BATS_TEST_TMPDIR/docker-stub-$$"
	cat >"$_docker_stub" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "ps" ]; then printf ''; fi
exit 0
STUB
	chmod +x "$_docker_stub"
	export DOCKER="$_docker_stub"

	# Stable discriminator for integration tests.
	_stable_disc() { printf 'test'; }
	export DRYDOCK_DISCRIMINATOR_FN=_stable_disc
}

# ── Case 1: absent overlay → silent no-op ────────────────────────────────────

@test "apply_claude_overlay: absent overlay dir → returns 0, session dir unchanged" {
	# HOST_CLAUDE_OVERLAY is $OVERLAY_DIR — never created.
	[ ! -d "$OVERLAY_DIR" ]
	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -eq 0 ]
	# session dir still empty (no files copied).
	local count
	count=$(find "$SESSION_DIR" -mindepth 1 | wc -l)
	[ "$count" -eq 0 ]
}

# ── Case 2: empty overlay → silent no-op ─────────────────────────────────────

@test "apply_claude_overlay: empty overlay dir → returns 0, no files copied" {
	mkdir -p "$OVERLAY_DIR"
	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -eq 0 ]
	local count
	count=$(find "$SESSION_DIR" -mindepth 1 | wc -l)
	[ "$count" -eq 0 ]
}

# ── Case 3: happy path — top-level file ──────────────────────────────────────

@test "apply_claude_overlay: top-level file copied into session dir" {
	mkdir -p "$OVERLAY_DIR"
	printf 'mcp-content' >"$OVERLAY_DIR/.mcp.json"

	apply_claude_overlay "$SESSION_DIR"

	[ -f "$SESSION_DIR/.mcp.json" ]
	content="$(cat "$SESSION_DIR/.mcp.json")"
	[ "$content" = "mcp-content" ]
}

# ── Case 4: happy path — nested directory ────────────────────────────────────

@test "apply_claude_overlay: nested dir/file copied with directory chain created" {
	mkdir -p "$OVERLAY_DIR/plugins/foo"
	printf 'bar-content' >"$OVERLAY_DIR/plugins/foo/bar.json"

	apply_claude_overlay "$SESSION_DIR"

	[ -f "$SESSION_DIR/plugins/foo/bar.json" ]
	content="$(cat "$SESSION_DIR/plugins/foo/bar.json")"
	[ "$content" = "bar-content" ]
}

# ── Case 5: overlay overwrites seeded file ────────────────────────────────────

@test "apply_claude_overlay: overlay file overwrites pre-seeded session file (Format A)" {
	mkdir -p "$OVERLAY_DIR"
	printf 'overlay-content' >"$OVERLAY_DIR/.mcp.json"
	# Pre-seed the session dir with different content.
	printf 'seeded-content' >"$SESSION_DIR/.mcp.json"

	apply_claude_overlay "$SESSION_DIR"

	content="$(cat "$SESSION_DIR/.mcp.json")"
	[ "$content" = "overlay-content" ]
}

# ── Case 6: forbidden basename .claude.json at depth 1 → err ─────────────────

@test "apply_claude_overlay: .claude.json at overlay root → fails with named path" {
	mkdir -p "$OVERLAY_DIR"
	printf '{}' >"$OVERLAY_DIR/.claude.json"

	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *".claude.json"* ]]
}

# ── Case 7: forbidden basename .credentials.json at depth 1 → err ────────────

@test "apply_claude_overlay: .credentials.json at overlay root → fails with named path" {
	mkdir -p "$OVERLAY_DIR"
	printf '{}' >"$OVERLAY_DIR/.credentials.json"

	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *".credentials.json"* ]]
}

# ── Case 6/7 depth-1 scoping: subdirectory .claude.json is NOT rejected ───────
# Design §Q1 explicitly limits the forbidden-basename check to depth 1.
# A file at sub/.claude.json does NOT match the forbidden set — only depth-1
# basenames are forbidden.  This test documents that scoping so a future
# contributor does not widen the check to any-basename-match.

@test "apply_claude_overlay: .claude.json nested under subdir is NOT rejected (depth-1 scoping)" {
	mkdir -p "$OVERLAY_DIR/sub"
	printf '{}' >"$OVERLAY_DIR/sub/.claude.json"

	apply_claude_overlay "$SESSION_DIR"

	[ -f "$SESSION_DIR/sub/.claude.json" ]
}

# ── Case 8: symlink rejected → err ───────────────────────────────────────────

@test "apply_claude_overlay: symlink with benign target → fails naming the symlink" {
	mkdir -p "$OVERLAY_DIR"
	printf 'real' >"$BATS_TEST_TMPDIR/real-file.txt"
	ln -s "$BATS_TEST_TMPDIR/real-file.txt" "$OVERLAY_DIR/evil.json"

	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *"evil.json"* ]]
}

@test "apply_claude_overlay: symlink pointing at .credentials.json → fails naming symlink" {
	mkdir -p "$OVERLAY_DIR"
	printf '{}' >"$BATS_TEST_TMPDIR/creds.json"
	ln -s "$BATS_TEST_TMPDIR/creds.json" "$OVERLAY_DIR/creds"

	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *"creds"* ]]
}

# ── Case 9: projects/ subtree silently skipped ────────────────────────────────
# DELIBERATE DIVERGENCE from blanket fail-loud (design §3):
# projects/ inside the overlay is silently skipped because ~/.claude/projects/
# is conversation history, not config — it is shadowed by the dedicated :rw
# sub-mount in docker-compose.yml (INV-2 carve-out for shared projects/ store).
# Copying it would be silently wasted I/O identical to the prototype-copy
# loop above.  This is NOT a missing rejection; it is the same "projects is
# not per-session config" rule already encoded in seed_session_config_dir.

@test "apply_claude_overlay: projects/ subtree silently skipped — no err, not copied" {
	mkdir -p "$OVERLAY_DIR/projects/x"
	printf 'history' >"$OVERLAY_DIR/projects/x/y.jsonl"

	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -eq 0 ]
	# The session dir must NOT contain the projects subtree from the overlay.
	[ ! -d "$SESSION_DIR/projects/x" ]
}

# ── Case 10: non-regular entry (FIFO) → err ──────────────────────────────────

@test "apply_claude_overlay: FIFO in overlay → fails naming the entry" {
	mkdir -p "$OVERLAY_DIR"
	mkfifo "$OVERLAY_DIR/afifo"

	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *"afifo"* ]]
}

# ── Case 11: integration — overlay survives re-seed ───────────────────────────

@test "apply_claude_overlay: integration — overlay file present after seed_session_config_dir re-run" {
	# Populate a minimal prototype (mirrors _make_prototype in lib_compose.bats).
	local fake_home="$BATS_TEST_TMPDIR/integrate-home"
	mkdir -p "$fake_home/.claude-container"
	printf 'proto-settings' >"$fake_home/.claude-container/settings.json"
	printf 'proto-json' >"$fake_home/.claude-container.json"
	export HOME="$fake_home"

	# Set the overlay dir in the fixture HOME.
	local overlay_dir="$fake_home/.config/drydock/claude-overlay"
	mkdir -p "$overlay_dir"
	printf 'playwright-config' >"$overlay_dir/playwright.json"
	HOST_CLAUDE_OVERLAY="$overlay_dir"

	# First seed.
	seed_session_config_dir "test"
	[ -f "$fake_home/.claude-container-test/playwright.json" ]
	content="$(cat "$fake_home/.claude-container-test/playwright.json")"
	[ "$content" = "playwright-config" ]

	# Simulate re-seed (rm -rf session dir, call again — this is what drydock does on re-run).
	rm -rf "$fake_home/.claude-container-test" "$fake_home/.claude-container-test.json"
	seed_session_config_dir "test"
	[ -f "$fake_home/.claude-container-test/playwright.json" ]
	content="$(cat "$fake_home/.claude-container-test/playwright.json")"
	[ "$content" = "playwright-config" ]
}

# ── Case 12: type collision — overlay dir vs seeded file → err ────────────────
# If the prototype seeded a regular file at path X and the overlay supplies a
# directory at X, the function must abort via err naming the path — not mkdir-p
# over the existing file (which would fail with a raw kernel error instead of a
# friendly drydock message).

@test "apply_claude_overlay: overlay dir collides with seeded file → fails with drydock err naming path" {
	mkdir -p "$OVERLAY_DIR"
	mkdir -p "$OVERLAY_DIR/settings.json"   # overlay delivers a DIRECTORY

	# Seed a regular FILE at the same relative path.
	printf 'seeded' >"$SESSION_DIR/settings.json"

	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *"drydock:"* ]]
	[[ "$output" == *"settings.json"* ]]
}

# ── Case 13: type collision — overlay file vs seeded dir → err ────────────────
# If the prototype seeded a directory at path X and the overlay supplies a
# regular file at X, cp -p would silently copy the file INTO the dir (wrong
# result, no error).  The function must abort via err naming the path.

@test "apply_claude_overlay: overlay file collides with seeded dir → fails with drydock err naming path" {
	mkdir -p "$OVERLAY_DIR"
	printf 'overlay-content' >"$OVERLAY_DIR/plugins"   # overlay delivers a FILE

	# Seed a DIRECTORY at the same relative path.
	mkdir -p "$SESSION_DIR/plugins"

	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *"drydock:"* ]]
	[[ "$output" == *"plugins"* ]]
	# The file must NOT have been silently copied inside the directory.
	[ ! -f "$SESSION_DIR/plugins/plugins" ]
	[ ! -f "$SESSION_DIR/plugins" ]
}

# ── Case 14: unreadable overlay subdir → abort non-zero ─────────────────────
# An unreadable subtree (chmod 000 subdir) must make apply_claude_overlay
# abort non-zero — the 2>/dev/null suppression that existed before the fix
# would have silently returned 0.
# Skipped when running as root (chmod 000 is bypassable by root).

@test "apply_claude_overlay: unreadable overlay subdir → aborts non-zero (not silent skip)" {
	[ "$(id -u)" -eq 0 ] && skip "root bypasses chmod 000 — test not meaningful"

	mkdir -p "$OVERLAY_DIR/secret-subdir"
	printf 'hidden' >"$OVERLAY_DIR/secret-subdir/file.txt"
	chmod 000 "$OVERLAY_DIR/secret-subdir"

	run apply_claude_overlay "$SESSION_DIR"

	# Restore permissions before any assertion so bats can clean up.
	chmod 755 "$OVERLAY_DIR/secret-subdir"

	[ "$status" -ne 0 ]
}

# ── Case 15: integration — forbidden overlay file makes seed abort non-zero ───
# Verifies that apply_claude_overlay's err bubbles all the way up through
# seed_session_config_dir (which calls apply_claude_overlay as its last step).

@test "apply_claude_overlay: integration — forbidden .claude.json causes seed_session_config_dir to abort" {
	local fake_home="$BATS_TEST_TMPDIR/integrate-home-abort"
	mkdir -p "$fake_home/.claude-container"
	printf 'proto-settings' >"$fake_home/.claude-container/settings.json"
	printf 'proto-json' >"$fake_home/.claude-container.json"
	export HOME="$fake_home"

	local overlay_dir="$fake_home/.config/drydock/claude-overlay"
	mkdir -p "$overlay_dir"
	printf '{}' >"$overlay_dir/.claude.json"   # forbidden by INV-2
	HOST_CLAUDE_OVERLAY="$overlay_dir"

	run seed_session_config_dir "test"
	[ "$status" -ne 0 ]
	[[ "$output" == *".claude.json"* ]]
}

# ── Case 16: symlink rejection — target content NOT delivered ────────────────
# Strengthens the existing symlink cases (9, 10) with a negative assertion:
# the symlink target's content must NOT appear in the session dir.

@test "apply_claude_overlay: symlink rejection — target content not delivered into session dir" {
	mkdir -p "$OVERLAY_DIR"
	printf 'real-content' >"$BATS_TEST_TMPDIR/real-file.txt"
	ln -s "$BATS_TEST_TMPDIR/real-file.txt" "$OVERLAY_DIR/evil.json"

	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *"evil.json"* ]]
	# The symlink target's content must NOT have been delivered.
	[ ! -e "$SESSION_DIR/evil.json" ]
}

@test "apply_claude_overlay: symlink-to-.credentials.json — target content not delivered into session dir" {
	mkdir -p "$OVERLAY_DIR"
	printf '{}' >"$BATS_TEST_TMPDIR/creds.json"
	ln -s "$BATS_TEST_TMPDIR/creds.json" "$OVERLAY_DIR/creds"

	run apply_claude_overlay "$SESSION_DIR"
	[ "$status" -ne 0 ]
	[[ "$output" == *"creds"* ]]
	# The symlink target's content must NOT have been delivered.
	[ ! -e "$SESSION_DIR/creds" ]
}
