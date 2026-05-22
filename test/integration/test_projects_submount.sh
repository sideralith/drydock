#!/usr/bin/env bash
# test/integration/test_projects_submount.sh — SR-9 integration test
#
# Proves that the shared projects/ sub-mount in docker-compose.yml resolves
# correctly end-to-end: a file written to ~/.claude/projects/<slug>/ inside the
# container appears at ~/.claude-container/projects/<slug>/ on the HOST.
#
# This is an integration-level test. It requires:
#   - A real Docker daemon socket (available in the drydock container and on host)
#   - The drydock:latest image to already be built
#
# Run locally or in CI:
#   RUN_INTEGRATION=1 test/integration/test_projects_submount.sh
#
# Guard: skips (with a clear message and exit 0) unless RUN_INTEGRATION=1 is set.
# scripts/test.sh does NOT include this file — it only runs test/*.bats — so the
# normal bats suite stays green without a Docker daemon. To run manually:
#
#   cd /path/to/drydock && RUN_INTEGRATION=1 test/integration/test_projects_submount.sh
#
# DooD note: when this script itself runs inside a drydock container, the nested
# test container's bind mounts resolve against the OUTER host filesystem (the
# Docker socket is shared). Assertions that check host paths therefore probe the
# outer host, not the current container. To avoid this complexity, the assertions
# use a self-contained approach: a second container run reads back the file to
# confirm the sub-mount is the same backing store (shared-store persistence
# across two distinct container invocations proves the mount is correct).
#
# CI wiring note: if a GitHub Actions workflow exists, add this as a separate job
# with `RUN_INTEGRATION: 1` and Docker available. For now this is a local-only
# pre-PR gate — run it before merging changes to docker-compose.yml or the
# compose volume list.
set -euo pipefail

# ── Guard ─────────────────────────────────────────────────────────────────────
if [ "${RUN_INTEGRATION:-}" != "1" ]; then
	echo "SKIP: SR-9 integration test (requires Docker daemon — set RUN_INTEGRATION=1 to run)"
	exit 0
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRYDOCK_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "==> SR-9 integration: projects/ sub-mount resolution"
echo "    DRYDOCK_HOME=$DRYDOCK_HOME"

# Test identifiers
TEST_SLUG="integration-test-sr9"
TEST_UUID="00000000-0000-0000-0000-000000000001"
TEST_CONTENT="SR-9 integration test: sub-mount resolution"
TEST_DISC_A="a1b2" # first container (writer)
TEST_DISC_B="c3d4" # second container (reader — proves shared persistence)

SHARED_STORE="$HOME/.claude-container/projects"
SESSION_DIR_A="$HOME/.claude-container-${TEST_DISC_A}"
SESSION_JSON_A="$HOME/.claude-container-${TEST_DISC_A}.json"
SESSION_DIR_B="$HOME/.claude-container-${TEST_DISC_B}"
SESSION_JSON_B="$HOME/.claude-container-${TEST_DISC_B}.json"

# ── Pre-flight cleanup ────────────────────────────────────────────────────────
CREATED_PROTOTYPE=0

cleanup_prototype() {
	if [ "${CREATED_PROTOTYPE:-0}" = "1" ]; then
		rm -rf "$HOME/.claude-container"
		rm -f "$HOME/.claude-container.json"
	fi
}

cleanup() {
	echo "==> Cleaning up test artifacts..."
	rm -rf "$SESSION_DIR_A" "$SESSION_DIR_B"
	rm -f "$SESSION_JSON_A" "$SESSION_JSON_B"
	rm -rf "${SHARED_STORE:?}/$TEST_SLUG" 2>/dev/null || true
	docker rm -f "drydock-inttest-sr9-${TEST_DISC_A}" "drydock-inttest-sr9-${TEST_DISC_B}" 2>/dev/null || true
	cleanup_prototype
}
trap cleanup EXIT
cleanup 2>/dev/null || true

# ── Ensure prototype exists ───────────────────────────────────────────────────
if [ ! -d "$HOME/.claude-container" ]; then
	echo "==> Creating minimal ~/.claude-container prototype for this test..."
	mkdir -p "$HOME/.claude-container"
	echo '{}' >"$HOME/.claude-container.json" 2>/dev/null || true
	CREATED_PROTOTYPE=1
fi
mkdir -p "$SHARED_STORE"

# ── Ensure drydock:latest image exists ───────────────────────────────────────
if ! docker image inspect drydock:latest >/dev/null 2>&1; then
	echo "==> SKIP: drydock:latest image not found; run 'drydock build' first"
	exit 0
fi

# ── Helper: seed a per-session dir ───────────────────────────────────────────
seed_session() {
	local disc="$1"
	local session_dir="$HOME/.claude-container-${disc}"
	local session_json="$HOME/.claude-container-${disc}.json"
	mkdir -p "$session_dir"
	while IFS= read -r -d '' _entry; do
		[ "${_entry##*/}" = projects ] && continue
		cp -a "$_entry" "$session_dir/" 2>/dev/null || true
	done < <(find "$HOME/.claude-container" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
	cp "$HOME/.claude-container.json" "$session_json" 2>/dev/null || echo '{}' >"$session_json"
	mkdir -p "$session_dir/projects"
}

# ── Helper: run a container with given disc ───────────────────────────────────
run_container() {
	local disc="$1"
	local cmd="$2"
	local session_dir="$HOME/.claude-container-${disc}"
	local session_json="$HOME/.claude-container-${disc}.json"
	local _uid _gid _docker_gid

	_uid="$(id -u)"
	_gid="$(id -g)"
	_docker_gid="$(getent group docker 2>/dev/null | cut -d: -f3 || echo 1001)"

	env \
		DRYDOCK_HOME="$DRYDOCK_HOME" \
		USER_NAME="${USER:-$(id -un)}" \
		USER_UID="$_uid" \
		USER_GID="$_gid" \
		HOST_DOCKER_GID="$_docker_gid" \
		PROJECT_DIR="$DRYDOCK_HOME" \
		PROJECT_NAME="inttest" \
		DRYDOCK_DISCRIMINATOR="$disc" \
		DRYDOCK_SESSION_CLAUDE_DIR="$session_dir" \
		DRYDOCK_SESSION_CLAUDE_JSON="$session_json" \
		DRYDOCK_SESSION_NAME="drydock-inttest-sr9-${disc}" \
		docker compose \
		-f "$DRYDOCK_HOME/docker-compose.yml" \
		run --rm \
		--name "drydock-inttest-sr9-${disc}" \
		drydock \
		bash -c "$cmd"
}

# ── Assert 0: sub-mount is active inside the container ───────────────────────
echo ""
echo "==> Assert 0: projects/ sub-mount is visible inside the container..."
seed_session "$TEST_DISC_A"
MOUNT_CHECK="$(run_container "$TEST_DISC_A" 'cat /proc/mounts | grep "\.claude/projects" || echo NONE')"
if echo "$MOUNT_CHECK" | grep -q "NONE"; then
	echo "FAIL: no ~/.claude/projects bind mount found in container"
	exit 1
fi
echo "    PASS: projects/ sub-mount is active inside the container"
echo "    mount line: $MOUNT_CHECK"

# ── Assert 1: write in container A, read back in container B ─────────────────
echo ""
echo "==> Assert 1: write in container A..."
seed_session "$TEST_DISC_A"
run_container "$TEST_DISC_A" \
	"mkdir -p \"\$HOME/.claude/projects/$TEST_SLUG\" && printf '%s\n' '$TEST_CONTENT' > \"\$HOME/.claude/projects/$TEST_SLUG/$TEST_UUID.jsonl\" && echo 'write OK'"

echo "==> Assert 1: read back in container B (different disc = different session dir)..."
seed_session "$TEST_DISC_B"
READ_RESULT="$(run_container "$TEST_DISC_B" \
	"cat \"\$HOME/.claude/projects/$TEST_SLUG/$TEST_UUID.jsonl\" 2>/dev/null || echo FILE_NOT_FOUND")"

if echo "$READ_RESULT" | grep -q "FILE_NOT_FOUND"; then
	echo "FAIL: file written in container A is not visible in container B via shared store"
	echo "  Expected shared projects/ sub-mount to persist files across sessions"
	exit 1
fi
if ! echo "$READ_RESULT" | grep -q "$TEST_CONTENT"; then
	echo "FAIL: file content mismatch"
	echo "  expected: $TEST_CONTENT"
	echo "  actual:   $READ_RESULT"
	exit 1
fi
echo "    PASS: file written in session A is readable in session B (shared store confirmed)"

# ── Assert 2: file is NOT under the per-session dir (on the current host/fs) ──
echo ""
echo "==> Assert 2: verify the file is in shared store (not per-session dir)..."
# We verify by checking that the per-session dir's projects/ is empty.
# (The actual .jsonl lives in ~/.claude-container/projects/ which may be on the
# outer host if running DooD; we verify absence in the per-session dir which IS
# accessible from this script's filesystem.)
PER_SESSION_FILE_A="$SESSION_DIR_A/projects/$TEST_SLUG/$TEST_UUID.jsonl"
if [ -f "$PER_SESSION_FILE_A" ]; then
	echo "FAIL: file found inside per-session dir (should only be in shared store): $PER_SESSION_FILE_A"
	exit 1
fi
echo "    PASS: file is NOT present inside per-session dir $SESSION_DIR_A/projects/"

echo ""
echo "==> SR-9 integration test PASSED"
