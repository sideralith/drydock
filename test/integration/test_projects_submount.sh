#!/usr/bin/env bash
# test/integration/test_projects_submount.sh — SR-9 integration test
#
# Proves that the shared projects/ sub-mount in docker-compose.yml resolves
# correctly end-to-end: a file written to ~/.claude/projects/<slug>/ inside one
# container is readable from a second, independently-launched container via the
# shared ~/.claude-container/projects/ backing store.
#
# This is an integration-level test. It requires:
#   - A real Docker daemon socket (available in the drydock container and on host)
#   - The drydock:latest image to already be built
#
# Run locally or inside a drydock container:
#   DRYDOCK_INTEGRATION_HOSTNET=1 test/integration/test_projects_submount.sh
#
# Guard: skips (with a clear message and exit 0) unless DRYDOCK_INTEGRATION_HOSTNET=1 is set.
# scripts/test.sh does NOT include this file — it only runs test/*.bats — so the
# normal bats suite stays green without a Docker daemon.
#
# ── Hermetic design (issue #73) ───────────────────────────────────────────────
# This test stages ALL scratch state under $DRYDOCK_HOME/.inttest-tmp/ — never
# under $HOME. The reason is the Docker-out-of-Docker (DooD) boundary: when this
# script itself runs inside a drydock container, `docker compose run` talks to
# the HOST daemon via the shared socket, so the launched container's bind-mount
# sources resolve against the HOST filesystem — NOT the test-runner container's.
# The two $HOME directories are different filesystems. Staging under $HOME and
# letting Docker auto-create the missing mount sources produced root-owned dirs
# in the real host home (issue #73).
#
# The project directory ($DRYDOCK_HOME / PROJECT_DIR) is the one path drydock
# bind-mounts at an IDENTICAL path on the host and inside every container. So a
# fake $HOME built underneath it is visible, with the same path, to both the
# test process and the launched containers. Every mount source docker-compose.yml
# references is pre-created (user-owned, empty) so Docker never auto-creates a
# root-owned directory. Cleanup is a plain `rm -rf` of user-owned files —
# reliable under DooD and on a bare host alike.
#
# CI wiring note: this test is LOCAL-ONLY and cannot run in GitHub Actions.
# network_mode: host (required here) now lives in docker-compose.dood.yml (the DooD
# mode overlay); it is no longer in the base docker-compose.yml. The run_container()
# helper below passes both -f docker-compose.yml and -f docker-compose.dood.yml
# explicitly (DRYDOCK_DOOD=1 env alone is not enough — this file never calls
# compose_files()). Run this test locally (host or drydock container) before merging
# changes to docker-compose.yml, docker-compose.dood.yml, or their volume lists, or
# on a self-hosted runner with true host networking.
set -euo pipefail

# ── Guard ─────────────────────────────────────────────────────────────────────
if [ "${DRYDOCK_INTEGRATION_HOSTNET:-}" != "1" ]; then
	echo "SKIP: SR-9 integration test (requires Docker daemon and dood mode host network — set DRYDOCK_INTEGRATION_HOSTNET=1 to run)"
	exit 0
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRYDOCK_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"

# All scratch lives here — under the project tree (the only DooD-stable path),
# never under $HOME. Gitignored via /.inttest-tmp/ in .gitignore.
INTTEST_ROOT="$DRYDOCK_HOME/.inttest-tmp"
# A fake $HOME built inside the scratch root. Because it lives under the project
# bind-mount, the test process and the launched containers see it at the same
# path. `docker compose` is invoked with HOME pointed here (so every ${HOME} in
# docker-compose.yml resolves into the fake tree), and each container run gets
# `-e HOME=$FAKE_HOME` so its in-container $HOME matches the mount targets.
FAKE_HOME="$INTTEST_ROOT/home"

echo "==> SR-9 integration: projects/ sub-mount resolution (hermetic)"
echo "    DRYDOCK_HOME=$DRYDOCK_HOME"
echo "    FAKE_HOME=$FAKE_HOME"

# ── Random session discriminators ────────────────────────────────────────────
# Same shape as drydock's own _gen_discriminator (lib/paths.sh) — 4-char hex.
# Random (not fixed a1b2/c3d4) so a crashed run can never leave pollution on a
# deterministic, predictable path.
_gen_disc() { printf '%04x' "$(((RANDOM << 8 ^ RANDOM) & 0xffff))"; }
TEST_DISC_A="$(_gen_disc)" # first container (writer)
TEST_DISC_B="$(_gen_disc)" # second container (reader — proves shared persistence)
while [ "$TEST_DISC_B" = "$TEST_DISC_A" ]; do TEST_DISC_B="$(_gen_disc)"; done

# ── Test identifiers ─────────────────────────────────────────────────────────
TEST_SLUG="integration-test-sr9"
TEST_UUID="00000000-0000-0000-0000-000000000001"
TEST_CONTENT="SR-9 integration test: sub-mount resolution"

SHARED_STORE="$FAKE_HOME/.claude-container/projects"
SESSION_DIR_A="$FAKE_HOME/.claude-container-${TEST_DISC_A}"
SESSION_DIR_B="$FAKE_HOME/.claude-container-${TEST_DISC_B}"

# ── Cleanup ──────────────────────────────────────────────────────────────────
cleanup() {
	echo "==> Cleaning up test artifacts..."
	# Remove any containers this run launched (names carry the random discs).
	docker rm -f "drydock-inttest-sr9-${TEST_DISC_A}" "drydock-inttest-sr9-${TEST_DISC_B}" 2>/dev/null || true
	# Everything else is user-owned scratch under the project tree — one rm -rf.
	rm -rf "$INTTEST_ROOT"
}
trap cleanup EXIT
# Pre-flight: clear any leftover scratch from a previous crashed run.
rm -rf "$INTTEST_ROOT"

# ── Pre-create every docker-compose.yml mount source ─────────────────────────
# Docker auto-creates a missing bind-mount source as a ROOT-OWNED directory.
# Pre-creating each source (user-owned, empty) is what keeps this test hermetic:
# Docker never has to auto-create anything, so nothing root-owned ever appears.
#
# This list MUST track the base docker-compose.yml `volumes:` block. If a new
# host-path mount source is added there, add it here too — otherwise this test
# silently regresses and starts polluting the host again.
#
#   docker-compose.yml line │ source path (under $FAKE_HOME)
#   ────────────────────────┼──────────────────────────────────────────────────
#   66  (DRYDOCK_SESSION_CLAUDE_DIR)  → .claude-container-<disc>/   (per-session)
#   67  (DRYDOCK_SESSION_CLAUDE_JSON) → .claude-container-<disc>.json
#   77                               → .claude-container/projects/
#   90  (DRYDOCK_SESSION_CLAUDE_DIR/hooks) → .claude-container-<disc>/hooks/
#   108 (DRYDOCK_SESSION_HOOKS_DIR)   → .claude-container-<disc>/drydock-hooks/
#   114 (DRYDOCK_SESSION_HOOKS_DIR inode alias) → same source, .claude/drydock-hooks:ro
#   93                               → .local/
#   96                               → .gitconfig
#   97                               → .config/gh/
# (.claude-container/ + .claude-container.json are the seed prototype copied
#  into each per-session pair by seed_session. seed_session creates the
#  per-session hooks/ and drydock-hooks/ subdirs below as part of that seed.)
precreate_mount_sources() {
	mkdir -p \
		"$FAKE_HOME/.claude-container/hooks" \
		"$FAKE_HOME/.claude-container/projects" \
		"$FAKE_HOME/.local" \
		"$FAKE_HOME/.config/gh"
	printf '{}' >"$FAKE_HOME/.claude-container.json"
	: >"$FAKE_HOME/.gitconfig"
}

# ── Helper: seed a per-session dir + its .json from the prototype ─────────────
seed_session() {
	local disc="$1"
	local session_dir="$FAKE_HOME/.claude-container-${disc}"
	local session_json="$FAKE_HOME/.claude-container-${disc}.json"
	mkdir -p "$session_dir" "$session_dir/drydock-hooks"
	# Copy prototype entries except projects/ (projects/ is the shared sub-mount).
	while IFS= read -r -d '' _entry; do
		[ "${_entry##*/}" = projects ] && continue
		cp -a "$_entry" "$session_dir/" 2>/dev/null || true
	done < <(find "$FAKE_HOME/.claude-container" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
	cp "$FAKE_HOME/.claude-container.json" "$session_json" 2>/dev/null || printf '{}' >"$session_json"
	mkdir -p "$session_dir/projects"
}

# ── Helper: run a container with the given discriminator ─────────────────────
run_container() {
	local disc="$1"
	local cmd="$2"
	local session_dir="$FAKE_HOME/.claude-container-${disc}"
	local session_json="$FAKE_HOME/.claude-container-${disc}.json"
	local _uid _gid _docker_gid

	_uid="$(id -u)"
	_gid="$(id -g)"
	_docker_gid="$(getent group docker 2>/dev/null | cut -d: -f3 || echo 1001)"

	# HOME=$FAKE_HOME → every ${HOME} in docker-compose.yml resolves into the
	# fake tree (mount SOURCES and TARGETS alike — the compose file uses one
	# ${HOME} for both sides of the bind).
	# -e HOME=$FAKE_HOME → the launched container's in-container $HOME matches
	# those mount targets, so `$HOME/.claude/...` in the test command lands on
	# the bind mount instead of the image's baked /home/<user>.
	# network_mode: host + the Docker socket now live in docker-compose.dood.yml
	# (the DooD mode overlay). This test requires host networking for the
	# shared-projects-store sub-mount assertion, so both compose files are passed
	# explicitly. DRYDOCK_DOOD=1 env is not sufficient here because this function
	# bypasses compose_files() and invokes docker compose directly.
	env \
		HOME="$FAKE_HOME" \
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
		DRYDOCK_SESSION_HOOKS_DIR="$session_dir/drydock-hooks" \
		DRYDOCK_SESSION_NAME="drydock-inttest-sr9-${disc}" \
		docker compose \
		-f "$DRYDOCK_HOME/docker-compose.yml" \
		-f "$DRYDOCK_HOME/docker-compose.dood.yml" \
		run --rm \
		-e HOME="$FAKE_HOME" \
		--name "drydock-inttest-sr9-${disc}" \
		drydock \
		bash -c "$cmd"
}

# ── Build the hermetic fake-HOME skeleton ────────────────────────────────────
precreate_mount_sources

# ── Ensure drydock:latest image exists ───────────────────────────────────────
if ! docker image inspect drydock:latest >/dev/null 2>&1; then
	echo "==> SKIP: drydock:latest image not found; run 'drydock build' first"
	exit 0
fi

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

# ── Assert 2: file is in the shared store, NOT the per-session dir ───────────
echo ""
echo "==> Assert 2: verify the file is in shared store (not per-session dir)..."
# The .jsonl must live in the shared store; the per-session dir's own projects/
# is shadowed by the sub-mount inside the container and must stay empty on disk.
PER_SESSION_FILE_A="$SESSION_DIR_A/projects/$TEST_SLUG/$TEST_UUID.jsonl"
if [ -f "$PER_SESSION_FILE_A" ]; then
	echo "FAIL: file found inside per-session dir (should only be in shared store): $PER_SESSION_FILE_A"
	exit 1
fi
SHARED_FILE="$SHARED_STORE/$TEST_SLUG/$TEST_UUID.jsonl"
if [ ! -f "$SHARED_FILE" ]; then
	echo "FAIL: file not found in shared store: $SHARED_FILE"
	exit 1
fi
echo "    PASS: file is in the shared store, not the per-session dir"
echo "    (per-session dir B: $SESSION_DIR_B/projects/ — also empty by the same rule)"

echo ""
echo "==> SR-9 integration test PASSED"
