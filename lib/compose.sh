#!/usr/bin/env bash
# lib/compose.sh — compose file helpers, image management, and DOCKER seam
#
# Sourced by bin/drydock (the thin dispatcher). Never sourced directly by
# lib/*.sh siblings — let the dispatcher control the source order.
# Requires: lib/paths.sh sourced first (detect_submounts, DRYDOCK_HOME).

# ── DOCKER seam ───────────────────────────────────────────────────────────────
# Moved here from bin/drydock (was an inline seam in slice 1).
# Override in tests: export DOCKER=/path/to/mock-docker before sourcing.
: "${DOCKER:=docker}"

# ── Constants ─────────────────────────────────────────────────────────────────
# DRYDOCK_HOME is set by the inline bootstrap in bin/drydock before this file
# is sourced, so these references are safe at source time.
IMAGE="drydock:latest"
COMPOSE_BASE="$DRYDOCK_HOME/docker-compose.yml"
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

# _submount_env_name — derive the env-var basename for a sub-mount.
# Shared by export_compose_env (host-side, where the value is set),
# generate_submount_overlay (YAML environment: block, where the name is
# declared so docker compose inherits from the CLI shell into the container),
# and sync_submount_env_file (marker-block content in PROJECT_DIR/.env).
# Keep these three callsites in sync via this helper.
_submount_env_name() {
	local mount_pt="$1"
	local project_dir="$2"
	local rel="${mount_pt#"$project_dir"/}"
	printf '%s' "$rel" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_' | sed 's/__*/_/g; s/^_//; s/_$//'
}

# _build_submount_env_block — emit one DRYDOCK_SUBMOUNT_<NAME>_HOST_PATH=<value>
# line per detected sub-mount (newline-terminated). Output is empty when no
# sub-mounts are detected. Consumed by sync_submount_env_file().
_build_submount_env_block() {
	local project_dir="$1"
	local detected _src _mp _class _name
	detected=$(detect_submounts "$project_dir") || true
	[ -n "$detected" ] || return 0
	while IFS='|' read -r _src _mp _class; do
		[ -n "$_src" ] || continue
		[ -n "$_mp" ] || continue
		_name=$(_submount_env_name "$_mp" "$project_dir")
		[ -n "$_name" ] || continue
		printf 'DRYDOCK_SUBMOUNT_%s_HOST_PATH=%s\n' "$_name" "$_src"
	done <<<"$detected"
}

# sync_submount_env_file — maintain a marker-delimited block in
# ${PROJECT_DIR}/.env containing the current DRYDOCK_SUBMOUNT_*_HOST_PATH
# vars. Enables `docker compose` invocations from the HOST SHELL (without
# drydock involvement) to substitute the env vars into the project's
# docker-compose.yml — docker compose reads .env automatically.
#
# Behavior matrix:
#   .env absent + no sub-mounts        → no-op
#   .env absent + sub-mounts           → create .env with marker block only
#   .env present + no marker + no subs → no-op
#   .env present + no marker + subs    → append marker block at end
#   .env present + marker + subs match → no-op (idempotent)
#   .env present + marker + subs diff  → replace marker block content
#   .env present + marker + no subs    → remove marker block (cleanup)
#
# Atomic write via mktemp + rename. Opt-out: DRYDOCK_SKIP_ENV_WRITE=1.
# Marker text intentionally distinctive so external tools (lint, formatters)
# can identify drydock-managed lines without confusion.
sync_submount_env_file() {
	local project_dir="$1"
	[ "${DRYDOCK_SKIP_ENV_WRITE:-0}" = "1" ] && return 0
	[ -d "$project_dir" ] || return 0

	local env_file="$project_dir/.env"
	local marker_start="# >>> drydock managed (auto-generated, do not edit manually) <<<"
	local marker_end="# <<< end drydock managed >>>"

	local block
	block=$(_build_submount_env_block "$project_dir")

	local has_file=0 has_marker=0
	[ -f "$env_file" ] && has_file=1
	[ "$has_file" = "1" ] && grep -qE '^# >>> drydock managed' "$env_file" 2>/dev/null && has_marker=1

	# Fast paths.
	[ "$has_file" = "0" ] && [ -z "$block" ] && return 0
	[ "$has_file" = "1" ] && [ "$has_marker" = "0" ] && [ -z "$block" ] && return 0

	# Idempotency check: if marker exists and content already matches, skip write.
	if [ "$has_marker" = "1" ]; then
		local existing_block
		existing_block=$(awk '
			/^# >>> drydock managed/ { in_block = 1; next }
			/^# <<< end drydock managed/ { in_block = 0; next }
			in_block { print }
		' "$env_file")
		[ "$existing_block" = "$block" ] && return 0
	fi

	# Extract user content (everything outside marker block).
	local user_content=""
	if [ "$has_file" = "1" ]; then
		user_content=$(awk '
			/^# >>> drydock managed/ { in_block = 1; next }
			/^# <<< end drydock managed/ { in_block = 0; next }
			!in_block { print }
		' "$env_file")
	fi

	# Atomic write: tmp + rename.
	local tmp
	tmp=$(mktemp "${env_file}.drydock.XXXXXX") || return 1
	{
		if [ -n "$user_content" ]; then
			printf '%s\n' "$user_content"
		fi
		if [ -n "$block" ]; then
			[ -n "$user_content" ] && printf '\n'
			printf '%s\n' "$marker_start"
			printf '%s' "$block"
			printf '%s\n' "$marker_end"
		fi
	} >"$tmp"
	mv -f "$tmp" "$env_file"
}

# generate_submount_overlay — write a compose overlay listing each sub-mount
# of $1 to $SUBMOUNT_OVERLAY. If detect_submounts returns empty, do NOT create
# the file (so compose_files can use file existence as the gate).
#
# Per-row behaviour:
#   - linux-native with empty docker-source (FS row missing) → skip + warn
#   - exotic:*                                                → emit + warn
#   - drvfs / linux-native with non-empty source              → emit silently
#
# The overlay declares BOTH a volumes: block (translated host paths into the
# drydock container itself) AND an environment: block listing the
# DRYDOCK_SUBMOUNT_<NAME>_HOST_PATH variables in KEY-only form so docker compose
# inherits each value from the CLI shell (where export_compose_env set them)
# into the container's environment. The inner container needs these env vars
# visible so docker-compose-launched-via-DooD can substitute them in the
# project's docker-compose.yml.
#
# If after filtering there are zero emittable rows, the overlay file is NOT
# written.
generate_submount_overlay() {
	local project_dir="$1"
	[ -n "${SUBMOUNT_OVERLAY:-}" ] || return 0
	local detected
	detected=$(detect_submounts "$project_dir")
	[ -n "$detected" ] || return 0

	local body=""
	local env_body=""
	local docker_src mount_pt class _name
	while IFS='|' read -r docker_src mount_pt class; do
		[ -n "$mount_pt" ] || continue
		if [ -z "$docker_src" ]; then
			warn "sub-mount $mount_pt skipped — source FS root not found in mountinfo"
			continue
		fi
		case "$class" in
		exotic:*)
			warn "sub-mount $mount_pt uses fstype ${class#exotic:} — propagation may not work"
			;;
		esac
		body+=$(printf '      - "%s:%s:rw"\n' "$docker_src" "$mount_pt")
		body+=$'\n'

		_name=$(_submount_env_name "$mount_pt" "$project_dir")
		if [ -n "$_name" ]; then
			env_body+=$(printf '      - DRYDOCK_SUBMOUNT_%s_HOST_PATH\n' "$_name")
			env_body+=$'\n'
		fi
	done <<<"$detected"

	[ -n "$body" ] || return 0

	{
		printf 'services:\n'
		printf '  drydock:\n'
		printf '    volumes:\n'
		printf '%s' "$body"
		if [ -n "$env_body" ]; then
			printf '    environment:\n'
			printf '%s' "$env_body"
		fi
	} >"$SUBMOUNT_OVERLAY"
}

# Print one compose -f arg per line, in order. Caller assembles into array.
compose_files() {
	local project_dir="$1"
	printf '%s\n' "-f" "$COMPOSE_BASE"
	generate_submount_overlay "$project_dir"
	if [ -f "${SUBMOUNT_OVERLAY:-}" ] && [ -s "${SUBMOUNT_OVERLAY:-}" ]; then
		printf '%s\n' "-f" "$SUBMOUNT_OVERLAY"
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

	# ── sub-mount host-path env vars (DooD passthrough) ───────────────────────
	# For every detected sub-mount under project_dir, export a translated host
	# path as DRYDOCK_SUBMOUNT_<UPPER_RELPATH>_HOST_PATH. The container drydock
	# already gets the sub-mount via the generated overlay (submount-propagation
	# SDD), but containers launched inside drydock via Docker-out-of-Docker
	# (DooD) talk to the HOST daemon — which cannot see drvfs sub-mounts created
	# post-boot of its WSL2 share. Exposing the translated path as an env var
	# lets the project's docker-compose.yml reference it:
	#
	#   volumes:
	#     - ${DRYDOCK_SUBMOUNT_DOCS_HOST_PATH:-./docs}:/var/www/docs
	#
	# The :- fallback keeps the compose portable for collaborators without the
	# bind mount. Naming: relative-to-project_dir, uppercased, non-alphanumeric
	# → '_' (see _submount_env_name helper). Nested sub-mounts produce distinct
	# names (docs/sub → DOCS_SUB). Only non-empty docker-sources are exported
	# (linux-native fallback misses are skipped by detect_submounts already;
	# exotic fstypes pass through).
	#
	# generate_submount_overlay() also emits the same names in the overlay's
	# environment: block (KEY-only) so docker compose inherits each value from
	# the CLI shell into the container drydock — necessary because the inner
	# DooD docker compose runs from a shell inside the container.
	local _detected _src _mp _class _name
	_detected=$(detect_submounts "$project_dir") || true
	if [ -n "$_detected" ]; then
		while IFS='|' read -r _src _mp _class; do
			[ -n "$_src" ] || continue
			[ -n "$_mp" ] || continue
			_name=$(_submount_env_name "$_mp" "$project_dir")
			[ -n "$_name" ] || continue
			export "DRYDOCK_SUBMOUNT_${_name}_HOST_PATH=$_src"
		done <<<"$_detected"
	fi

	# Auto-maintain ${PROJECT_DIR}/.env so `docker compose` invocations from
	# the HOST SHELL (without drydock involvement) substitute the vars too.
	sync_submount_env_file "$project_dir"
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
