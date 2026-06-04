#!/usr/bin/env bats
# test/compose_overlay_render.bats — compose render assertions for dual-mode overlays
#
# Validates YAML correctness by running `docker compose config` (no daemon needed,
# config-only read) against the base + mode overlay combinations.
#
# Design §7c: render tests are negative/positive assertions over the resolved YAML.
# - contain render: docker.sock ABSENT, network_mode: host ABSENT, internal: true ABSENT
# - dood render: docker.sock PRESENT, network_mode: host PRESENT
# - hardening composes cleanly with both modes
#
# Each test provides dummy non-empty env vars so compose interpolation succeeds without
# a daemon (compose config is offline, doesn't check bind-source path existence).

load "helpers/load"

setup() {
	# Skip entire file if docker is not available.
	if ! command -v docker >/dev/null 2>&1; then
		skip "docker not available"
	fi

	# Dummy env vars required by docker-compose.yml :? guards.
	# Compose config is offline — dummy paths work; no daemon or real fs checks.
	export USER_NAME="testuser"
	export USER_UID="1000"
	export USER_GID="1000"
	export HOST_DOCKER_GID="999"
	export PROJECT_DIR="/tmp/render-test-project"
	export PROJECT_NAME="testproject"
	export DRYDOCK_DISCRIMINATOR="abcd"
	export DRYDOCK_SESSION_CLAUDE_DIR="/tmp/render-cdir"
	export DRYDOCK_SESSION_CLAUDE_JSON="/tmp/render-cjson"
	export DRYDOCK_SESSION_HOOKS_DIR="/tmp/render-hooks"
	export DRYDOCK_TMPFS_SIZE="1g"

	# Clear any ambient mode env vars so tests control the mode explicitly.
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN DRYDOCK_NO_HARDENING

	DRYDOCK_HOME="${DRYDOCK_HOME:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)}"
}

# ── Contained mode render assertions ─────────────────────────────────────────

@test "render: contain — docker.sock absent" {
	run docker compose \
		-f "$DRYDOCK_HOME/docker-compose.yml" \
		-f "$DRYDOCK_HOME/docker-compose.contain.yml" \
		config --no-path-resolution
	[ "$status" -eq 0 ]
	[[ "$output" != *"docker.sock"* ]]
}

@test "render: contain — network_mode: host absent" {
	run docker compose \
		-f "$DRYDOCK_HOME/docker-compose.yml" \
		-f "$DRYDOCK_HOME/docker-compose.contain.yml" \
		config --no-path-resolution
	[ "$status" -eq 0 ]
	[[ "$output" != *"network_mode: host"* ]]
}

@test "render: contain — internal: true absent (egress-open regression guard)" {
	# HARD REQUIREMENT (R8.6): this test acts as the regression guard preventing
	# accidental reintroduction of internal: true in Phase 1. internal: true removes
	# the default gateway / NAT, blocking Claude Code's access to api.anthropic.com.
	run docker compose \
		-f "$DRYDOCK_HOME/docker-compose.yml" \
		-f "$DRYDOCK_HOME/docker-compose.contain.yml" \
		config --no-path-resolution
	[ "$status" -eq 0 ]
	[[ "$output" != *"internal: true"* ]]
}

@test "render: contain — service attached to drydock_net bridge" {
	run docker compose \
		-f "$DRYDOCK_HOME/docker-compose.yml" \
		-f "$DRYDOCK_HOME/docker-compose.contain.yml" \
		config --no-path-resolution
	[ "$status" -eq 0 ]
	[[ "$output" == *"drydock_net"* ]]
}

# ── DooD mode render assertions ───────────────────────────────────────────────

@test "render: dood — docker.sock present" {
	run docker compose \
		-f "$DRYDOCK_HOME/docker-compose.yml" \
		-f "$DRYDOCK_HOME/docker-compose.dood.yml" \
		config --no-path-resolution
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker.sock"* ]]
}

@test "render: dood — network_mode: host present" {
	run docker compose \
		-f "$DRYDOCK_HOME/docker-compose.yml" \
		-f "$DRYDOCK_HOME/docker-compose.dood.yml" \
		config --no-path-resolution
	[ "$status" -eq 0 ]
	[[ "$output" == *"network_mode: host"* ]]
}

# ── Hardening + mode composition ─────────────────────────────────────────────

@test "render: hardening + contain — cap_drop present, socket absent" {
	run docker compose \
		-f "$DRYDOCK_HOME/docker-compose.yml" \
		-f "$DRYDOCK_HOME/docker-compose.contain.yml" \
		-f "$DRYDOCK_HOME/docker-compose.hardening.yml" \
		config --no-path-resolution
	[ "$status" -eq 0 ]
	[[ "$output" == *"cap_drop"* ]]
	[[ "$output" != *"docker.sock"* ]]
}

@test "render: hardening + dood — cap_drop present, socket present" {
	run docker compose \
		-f "$DRYDOCK_HOME/docker-compose.yml" \
		-f "$DRYDOCK_HOME/docker-compose.dood.yml" \
		-f "$DRYDOCK_HOME/docker-compose.hardening.yml" \
		config --no-path-resolution
	[ "$status" -eq 0 ]
	[[ "$output" == *"cap_drop"* ]]
	[[ "$output" == *"docker.sock"* ]]
}

# ── compose_files never emits both overlays (R1-E scenario) ──────────────────

@test "compose_files: never emits both overlays simultaneously" {
	# Source the library stack to call compose_files directly.
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"

	# Stub docker for GC/collision checks.
	local _stub="$BATS_TEST_TMPDIR/docker-stub-render-$$"
	cat >"$_stub" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "ps" ]; then printf ''; fi
exit 0
STUB
	chmod +x "$_stub"
	export DOCKER="$_stub"

	local _home="$BATS_TEST_TMPDIR/render-no-both-$$"
	mkdir -p "$_home/.claude-container"
	touch "$_home/.claude-container.json"
	export HOME="$_home"

	local _proj="$BATS_TEST_TMPDIR/render-proj-$$"
	mkdir -p "$_proj"

	export MOUNTINFO_FILE=/dev/null
	unset DRYDOCK_DOOD DRYDOCK_CONTAIN

	local _output
	_output="$(compose_files "$_proj")"

	# Must contain exactly one of the two overlays, never both.
	local _dood_count=0 _contain_count=0
	[[ "$_output" == *"docker-compose.dood.yml"* ]] && _dood_count=1
	[[ "$_output" == *"docker-compose.contain.yml"* ]] && _contain_count=1
	[ $((_dood_count + _contain_count)) -eq 1 ]
}
