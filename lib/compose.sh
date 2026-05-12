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
COMPOSE_SSH="$DRYDOCK_HOME/docker-compose.ssh.yml"
COMPOSE_GPG="$DRYDOCK_HOME/docker-compose.gpg.yml"
COMPOSE_ENGRAM="$DRYDOCK_HOME/docker-compose.engram.yml"
# shellcheck disable=SC2034  # used in lib/commands.sh (cmd_init)
DEFAULT_SETTINGS_TEMPLATE="$DRYDOCK_HOME/templates/default-settings.json"

# ── Functions ─────────────────────────────────────────────────────────────────

# Returns 0 when engram can run inside the container: binary on host PATH AND
# host OS is Linux. On macOS, command -v engram may succeed but the Mach-O
# binary cannot run in the Linux container — treated as effectively absent.
engram_usable() {
	command -v engram >/dev/null 2>&1 && host_is_linux
}

# Print one compose -f arg per line, in order. Caller assembles into array.
compose_files() {
	local project_dir="$1"
	printf '%s\n' "-f" "$COMPOSE_BASE"
	if [ -d "$project_dir/docs" ] && is_separate_mount "$project_dir/docs"; then
		printf '%s\n' "-f" "$COMPOSE_DOCS"
	fi
	# Optional, host opt-in — these vars are set by export_compose_env (called
	# before this fn) so the -f list and the overlay YAMLs share one decision.
	if [ -n "${DRYDOCK_SSH_DEPLOY_KEY:-}" ]; then
		printf '%s\n' "-f" "$COMPOSE_SSH"
	fi
	if [ -n "${DRYDOCK_GPG_SIGNINGKEY:-}" ]; then
		printf '%s\n' "-f" "$COMPOSE_GPG"
	fi
	if [ -n "${DRYDOCK_ENGRAM_SOURCE:-}" ]; then
		printf '%s\n' "-f" "$COMPOSE_ENGRAM"
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
	# USER_NAME drives the Dockerfile ARG (via compose build.args) so the
	# container user / $HOME match the invoking host user. id -un, not $USER —
	# $USER isn't reliably exported in non-interactive contexts.
	export USER_NAME
	USER_NAME="$(id -un)"
	export HOST_DOCKER_GID
	HOST_DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 1001)"
	export COMPOSE_PROJECT_NAME="drydock-${PROJECT_NAME}"

	# ── optional git-credential overlays (host opt-in) ────────────────────────
	# Detected here so compose_files() and the overlay YAMLs share one source of
	# truth. Material lives under ~/.config/drydock/ (NEVER ~/.ssh or ~/.gnupg),
	# so the hook/deny rules on those host dirs stay strong and unconditional.
	#
	# SSH deploy key: ~/.config/drydock/keys/<project>_deploy → git push over SSH
	# (consumed by docker-compose.ssh.yml: bind-mount :ro + GIT_SSH_COMMAND).
	local _deploy_key="$HOME/.config/drydock/keys/${PROJECT_NAME}_deploy"
	if [ -f "$_deploy_key" ]; then
		export DRYDOCK_SSH_DEPLOY_KEY="$_deploy_key"
	fi
	# Sandbox GPG signing key: ~/.config/drydock/signing/ → GitHub-Verified commits
	# (consumed by docker-compose.gpg.yml: bind-mount rw + GNUPGHOME + GIT_CONFIG_*).
	local _signing_home="$HOME/.config/drydock/signing"
	if [ -d "$_signing_home" ] && command -v gpg >/dev/null 2>&1; then
		local _fpr=""
		_fpr="$(gpg --homedir "$_signing_home" --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec:/{print $5; exit}')" || true
		if [ -n "$_fpr" ]; then
			export DRYDOCK_GPG_SIGNING_HOME="$_signing_home"
			export DRYDOCK_GPG_SIGNINGKEY="$_fpr"
		else
			warn "$_signing_home existe pero no contiene clave secreta — firma GPG no activada"
		fi
	fi

	# ── optional engram overlay (host opt-in) ─────────────────────────────────
	# Engram is usable in the container only when: (a) the engram binary is on
	# the host PATH AND (b) the host OS is Linux — a macOS Mach-O engram cannot
	# run inside the Debian Linux container.
	# Shared mode: opt-in via sentinel file ~/.config/drydock/engram-shared.
	# Safety gate: on hosts with unreliable bind-mount POSIX locks (WSL2 / macOS),
	# shared mode is force-downgraded to isolated unless DRYDOCK_ENGRAM_SHARED=force.
	if engram_usable; then
		local _sentinel="$HOME/.config/drydock/engram-shared"
		if [ -f "$_sentinel" ]; then
			if host_fs_locks_unreliable && [ "${DRYDOCK_ENGRAM_SHARED:-}" != "force" ]; then
				export DRYDOCK_ENGRAM_SOURCE="$HOME/.engram-container"
				warn "shared engram DB requested but bind-mount POSIX locks unreliable on this host (WSL2 9P / macOS virtiofs) — using isolated DB instead; run 'engram sync --import' to bridge, or set DRYDOCK_ENGRAM_SHARED=force to override (risks SQLite WAL corruption)"
			else
				export DRYDOCK_ENGRAM_SOURCE="$HOME/.engram"
				if host_fs_locks_unreliable; then
					warn "shared DB override active: you've bypassed the data-safety check; concurrent host+container writes can corrupt ~/.engram/engram.db"
				else
					warn "shared engram DB — avoid running host Claude and the container against it simultaneously"
				fi
			fi
		else
			export DRYDOCK_ENGRAM_SOURCE="$HOME/.engram-container"
		fi
	fi
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
	# The engram dir guard is conditional: only included when engram is usable in
	# the container AND isolated mode is active (no engram-shared sentinel).
	# When engram is not usable, a missing CONTAINER_ENGRAM is harmless — the
	# overlay never activates, so no setup trigger is needed for that reason alone.
	local _needs_setup=0
	[ ! -d "$CONTAINER_CLAUDE" ] && _needs_setup=1
	[ ! -f "$CONTAINER_CLAUDE_JSON" ] && _needs_setup=1
	# The CONTAINER_ENGRAM guard applies only in the default isolated topology.
	# In shared mode the container uses the host's ~/.engram directly — that dir
	# is user-owned and must already exist; no setup trigger is needed. When
	# engram is not usable at all (absent or macOS), the overlay never activates
	# so a missing CONTAINER_ENGRAM is harmless and must NOT trigger setup.
	if engram_usable && [ ! -f "$HOME/.config/drydock/engram-shared" ]; then
		[ ! -d "$CONTAINER_ENGRAM" ] && _needs_setup=1
	fi
	if [ "$_needs_setup" -eq 1 ]; then
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
