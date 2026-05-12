#!/usr/bin/env bash
# lib/compose.sh — compose file helpers, image management, and DOCKER seam
#
# Sourced by bin/drydock (the thin dispatcher). Never sourced directly by
# lib/*.sh siblings — let the dispatcher control the source order.
# Requires: lib/paths.sh sourced first (is_separate_mount, DRYDOCK_HOME).

# ── DOCKER seam ───────────────────────────────────────────────────────────────
# Moved here from bin/drydock (was an inline seam in slice 1).
# Override in tests: export DOCKER=/path/to/mock-docker before sourcing.
: "${DOCKER:=docker}"

# ── Constants ─────────────────────────────────────────────────────────────────
# DRYDOCK_HOME is set by the inline bootstrap in bin/drydock before this file
# is sourced, so these references are safe at source time.
IMAGE="drydock:latest"
COMPOSE_BASE="$DRYDOCK_HOME/docker-compose.yml"
COMPOSE_DOCS="$DRYDOCK_HOME/docker-compose.docs.yml"
# shellcheck disable=SC2034  # used in lib/commands.sh (cmd_init)
DEFAULT_SETTINGS_TEMPLATE="$DRYDOCK_HOME/templates/default-settings.json"

# ── Functions ─────────────────────────────────────────────────────────────────

# Print one compose -f arg per line, in order. Caller assembles into array.
compose_files() {
	local project_dir="$1"
	printf '%s\n' "-f" "$COMPOSE_BASE"
	if [ -d "$project_dir/docs" ] && is_separate_mount "$project_dir/docs"; then
		printf '%s\n' "-f" "$COMPOSE_DOCS"
	fi
}

# Export env vars needed by docker-compose.yml interpolation.
export_compose_env() {
	local project_dir="$1"
	export PROJECT_DIR="$project_dir"
	export PROJECT_NAME
	PROJECT_NAME="$(basename "$project_dir")"
	export USER_UID
	USER_UID="$(id -u)"
	export USER_GID
	USER_GID="$(id -g)"
	export HOST_DOCKER_GID
	HOST_DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 1001)"
	export COMPOSE_PROJECT_NAME="drydock-${PROJECT_NAME}"
}

image_exists() {
	"$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1
}

ensure_prereqs() {
	command -v docker >/dev/null || err "docker no está en PATH"
	[ -S /var/run/docker.sock ] || err "docker socket no encontrado en /var/run/docker.sock"
	[ -f "$COMPOSE_BASE" ] || err "compose base no encontrado: $COMPOSE_BASE"
}

ensure_runtime_dirs() {
	# Auto-setup if missing. Transparent for first-time users — cmd_setup is
	# idempotent and prints a note when it runs.
	if [ ! -d "$CONTAINER_CLAUDE" ] || [ ! -d "$CONTAINER_ENGRAM" ] || [ ! -f "$CONTAINER_CLAUDE_JSON" ]; then
		note "runtime state faltante — ejecutando 'drydock setup' automáticamente"
		cmd_setup
	fi
}

ensure_image() {
	if ! image_exists; then
		note "image $IMAGE no construida — building now"
		cmd_build
	fi
}
