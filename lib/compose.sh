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
COMPOSE_MCP_AUTH="$DRYDOCK_HOME/docker-compose.mcp-auth.yml"
COMPOSE_CCSTATUSLINE="$DRYDOCK_HOME/docker-compose.ccstatusline.yml"
COMPOSE_HARDENING="$DRYDOCK_HOME/docker-compose.hardening.yml"
# shellcheck disable=SC2034  # used in lib/commands.sh (cmd_init)
DEFAULT_SETTINGS_TEMPLATE="$DRYDOCK_HOME/templates/default-settings.json"

# ── Functions ─────────────────────────────────────────────────────────────────

# Returns 0 when engram can run inside the container: binary on host PATH AND
# host OS is Linux. On macOS, command -v engram may succeed but the Mach-O
# binary cannot run in the Linux container — treated as effectively absent.
engram_usable() {
	command -v engram >/dev/null 2>&1 && host_is_linux
}

# sanitize_project_name — pure transform: directory basename → Docker Compose-safe
# project name. Accepts one argument (raw string), emits the sanitized name on
# stdout. No side effects, no globals. Steps per REQ-1:
#   1. Lowercase all characters.
#   2. Map every character outside [a-z0-9_-] to '-'.
#   3. Collapse repeated '-' into a single '-' (belt-and-suspenders with tr -s).
#   4. Strip ALL leading characters that are not [a-z0-9] (dashes AND underscores).
#   5. Strip trailing '-' and '_'.
#   6. If the result is empty, output the literal string 'project'.
sanitize_project_name() {
	local raw="$1" name
	name="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-')"
	# collapse repeated dashes; strip leading non-alphanumerics (dash AND underscore);
	# strip trailing dash/underscore
	name="$(printf '%s' "$name" | sed 's/--*/-/g; s/^[^a-z0-9]*//; s/[-_]*$//')"
	[ -n "$name" ] || name="project"
	printf '%s' "$name"
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
		# Idiom: $(printf '...\n') strips the trailing newline (command-substitution
		# behavior); the explicit body+=$'\n' restores exactly one newline per
		# entry. Net output: one line per volume, no blank lines between. Do NOT
		# remove either half — removing the $'\n' concatenates entries on one
		# line; removing the $() wrapping breaks the strip-and-add pairing.
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

# generate_links_overlay — write a compose overlay for sibling mounts from the
# project's link list (~/.config/drydock/links/<project>.list).
# If the list is absent or empty, do NOT create the file.
# Overlay shape (simpler than submounts — no environment: block, D4):
#   services:
#     drydock:
#       volumes:
#         - "<host>:<target>:ro"
generate_links_overlay() {
	local project_dir="$1"
	[ -n "${LINKS_OVERLAY:-}" ] || return 0

	local proj_name
	proj_name="$(sanitize_project_name "$(basename "$project_dir")")"
	local list_file="$HOME/.config/drydock/links/${proj_name}.list"

	[ -f "$list_file" ] || return 0

	local body=""
	local host target
	while IFS='|' read -r host target _; do
		[ -z "$host" ] && continue
		# FIX #8: skip malformed lines with an empty target field to prevent
		# a broken "host::ro" volume spec from entering the compose overlay.
		[ -z "$target" ] && continue
		# Idiom (see generate_submount_overlay for the full rationale): $() strips
		# printf's trailing newline; body+=$'\n' restores exactly one — net is
		# one line per entry, no blank lines between.
		body+=$(printf '      - "%s:%s:ro"\n' "$host" "$target")
		body+=$'\n'
	done < "$list_file"

	[ -n "$body" ] || return 0

	{
		printf 'services:\n'
		printf '  drydock:\n'
		printf '    volumes:\n'
		printf '%s' "$body"
	} > "$LINKS_OVERLAY"
}

# Print one compose -f arg per line, in order. Caller assembles into array.
compose_files() {
	local project_dir="$1"
	printf '%s\n' "-f" "$COMPOSE_BASE"
	generate_submount_overlay "$project_dir"
	if [ -f "${SUBMOUNT_OVERLAY:-}" ] && [ -s "${SUBMOUNT_OVERLAY:-}" ]; then
		printf '%s\n' "-f" "$SUBMOUNT_OVERLAY"
	fi
	generate_links_overlay "$project_dir"
	if [ -f "${LINKS_OVERLAY:-}" ] && [ -s "${LINKS_OVERLAY:-}" ]; then
		printf '%s\n' "-f" "$LINKS_OVERLAY"
	fi
	# Container hardening defaults (cap_drop, no-new-privileges, tmpfs /tmp).
	# Suppressed ONLY when DRYDOCK_NO_HARDENING is set to the literal value "1"
	# (nuclear opt-out per INV-8). Values like "0", "false", "true", or empty
	# retain hardening — only the exact literal "1" disables.
	# DRYDOCK_TMPFS_SIZE is interpolated inside the overlay for granular tmpfs sizing.
	if [ "${DRYDOCK_NO_HARDENING:-0}" != "1" ]; then
		printf '%s\n' "-f" "$COMPOSE_HARDENING"
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
	# Auto-detect user-config opt-in overlays based on host directory presence.
	# Activated only when the user has actually configured the tool — never
	# creates empty dirs on hosts that don't use these tools. To opt in for the
	# first time, run the tool's setup once from host claude (where browser /
	# init flows work) and the directory appears automatically.
	if [ -d "$HOME/.mcp-auth" ]; then
		printf '%s\n' "-f" "$COMPOSE_MCP_AUTH"
	fi
	if [ -d "$HOME/.config/ccstatusline" ]; then
		printf '%s\n' "-f" "$COMPOSE_CCSTATUSLINE"
		# Co-mount cache only if the overlay activates — keeps the bind-mount
		# source list consistent with the overlay's expectations. ccstatusline
		# auto-creates its cache dir at first invocation, but bind mounts need
		# it pre-existing; make it idempotently when the parent overlay applies.
		[ -d "$HOME/.cache/ccstatusline" ] || mkdir -p "$HOME/.cache/ccstatusline"
	fi
}

# Export env vars needed by docker-compose.yml interpolation.
export_compose_env() {
	local project_dir="$1"
	export PROJECT_DIR="$project_dir"
	export PROJECT_NAME
	PROJECT_NAME="$(sanitize_project_name "$(basename "$project_dir")")"
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

	# ── Per-session identity: discriminator + session dirs ────────────────────
	# Order: GC orphans → generate discriminator (collision retry) → seed dir.
	# GC must run first so orphan dirs don't pollute the collision check.
	gc_orphan_session_dirs

	# Collision retry: generate a discriminator and verify it is free.
	# A "free" disc means no drydock-*-<disc> or drydock-*-<disc>-shell
	# container exists in docker ps -a. On a collision: remove the stopped
	# container for the CURRENT project+disc (belt-and-suspenders cleanup), then
	# retry with a fresh disc. R4 (no-kill): running containers are never stopped —
	# a collision with a running container forces a retry with a new disc.
	local _disc _session_name _ps_out _max_retries=5 _attempt=0
	while true; do
		_attempt=$((_attempt + 1))
		if [ "$_attempt" -gt "$_max_retries" ]; then
			err "drydock: could not find a free session discriminator after ${_max_retries} attempts — too many concurrent sessions?"
		fi
		_disc="$("$DRYDOCK_DISCRIMINATOR_FN")"
		_session_name="drydock-${PROJECT_NAME}-${_disc}"
		_ps_out="$("$DOCKER" ps -a --format '{{.Names}}' 2>/dev/null)" || true
		# Check if any container (any project) already uses this disc — match
		# both the run name (drydock-<proj>-<disc>) and the shell companion
		# (drydock-<proj>-<disc>-shell).  --format '{{.Names}}' gives one name
		# per line so ^ and $ anchors are exact; no column-padding false-matches.
		if printf '%s\n' "$_ps_out" | grep -qE "^drydock-.+-${_disc}(-shell)?$"; then
			# The collision check is project-agnostic (any drydock-*-<disc> match),
			# but the rm targets only THIS project's container for that disc.
			# If the collision belongs to a foreign project, the rm is a silent
			# no-op (container name mismatch); the loop retries with a fresh disc.
			"$DOCKER" rm "${_session_name}" >/dev/null 2>&1 || true
			# Always retry with a fresh disc to guarantee uniqueness.
			continue
		fi
		break
	done

	export DRYDOCK_DISCRIMINATOR="$_disc"
	export DRYDOCK_SESSION_CLAUDE_DIR="$HOME/.claude-container-${_disc}"
	export DRYDOCK_SESSION_CLAUDE_JSON="$HOME/.claude-container-${_disc}.json"
	export DRYDOCK_SESSION_NAME="$_session_name"
	export COMPOSE_PROJECT_NAME="$_session_name"

	# Seed the per-session config dir from the freshly-synced prototype.
	seed_session_config_dir "$_disc"

	# ── drydock container identity markers (issue #8, Slice A) ───────────────
	# Forwarded into the container via the environment: block so Claude can
	# detect it is running inside drydock. DRYDOCK_HOME is a plain bash var
	# set inline in bin/drydock; export it here so docker-compose.yml can
	# substitute ${DRYDOCK_HOME} in volume mount sources (e.g. Slice B hook mount).
	export DRYDOCK=1
	export DRYDOCK_VERSION
	export DRYDOCK_HOME

	# ── deploy-key migration warning (REQ-11) ─────────────────────────────────
	# If the raw basename differs from the sanitized PROJECT_NAME AND an old-named
	# key file exists at the old location, warn the user to rename it. Non-fatal.
	local _raw_basename
	_raw_basename="$(basename "$project_dir")"
	if [ "$_raw_basename" != "$PROJECT_NAME" ] &&
		[ -f "$HOME/.config/drydock/keys/${_raw_basename}_deploy" ]; then
		warn "project name normalized to '$PROJECT_NAME'; deploy key '${_raw_basename}_deploy' will not be found — rename it to '${PROJECT_NAME}_deploy'"
	fi

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
				warn "shared engram DB requested but bind-mount POSIX locks unreliable on this host (WSL2 9P / macOS virtiofs) — using isolated DB instead; see docs/engram.md to consolidate host and container memory, or set DRYDOCK_ENGRAM_SHARED=force to override (risks SQLite WAL corruption)"
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

# gc_orphan_session_dirs — prune per-session Claude config dirs whose container
# no longer exists. Called before discriminator generation so stale dirs are
# cleaned before a new session is seeded.
#
# Algorithm:
#   1. Glob $HOME/.claude-container-?*/ (pattern ?* requires ≥1 char after dash;
#      never matches the bare prototype ~/.claude-container — no trailing dash).
#   2. For each dir, extract <disc> from the dir name; derive both container names:
#      drydock-<PROJECT_NAME>-<disc> and drydock-<PROJECT_NAME>-<disc>-shell.
#   3. If NEITHER name appears in `docker ps -a`, rm -rf the dir and its .json sibling.
#   4. Returns 0 always — GC failures are non-fatal.
#
# Uses DOCKER seam.
gc_orphan_session_dirs() {
	local _disc _dir _json _ps_out
	# Collect docker ps -a output once (avoid N docker calls for N dirs).
	# --format '{{.Names}}' emits one container name per line so ^ and $ anchors
	# are exact and column-padding cannot produce false matches.
	_ps_out="$("$DOCKER" ps -a --format '{{.Names}}' 2>/dev/null)" || true

	# Use a for-loop with a glob; protect against no-match (nullglob absent).
	for _dir in "$HOME"/.claude-container-?*/; do
		# Skip if glob matched literally (no dirs exist).
		[ -d "$_dir" ] || continue
		# Extract disc: remove prefix "$HOME/.claude-container-" and trailing "/".
		_disc="${_dir#"$HOME"/.claude-container-}"
		_disc="${_disc%/}"
		# Validate discriminator shape: only prune dirs drydock itself could have
		# created (4-char lowercase hex).  Dirs with any other suffix — e.g.
		# ~/.claude-container-backup — are user-owned and must never be removed.
		[[ "$_disc" =~ ^[0-9a-f]{4}$ ]] || continue
		# Project-agnostic liveness check: protect the dir if ANY
		# drydock-*-<disc> or drydock-*-<disc>-shell container exists,
		# regardless of which project owns it.  Combined alternation so both
		# the run name and the shell companion are matched in one pass.
		if printf '%s\n' "$_ps_out" | grep -qE "^drydock-.+-${_disc}(-shell)?$"; then
			continue
		fi
		# Orphan — prune dir and sibling .json.
		_json="${_dir%/}.json"
		rm -rf "$_dir"
		rm -f "$_json"
	done
	return 0
}

# seed_session_config_dir — create (or re-create) a per-session Claude config
# dir and .json file by copying from the prototype ~/.claude-container/.
# Called after ensure_synced so the prototype is fresh, and after the
# discriminator is settled.
#
# Arguments:
#   $1 — disc: the 4-char hex discriminator for this session
#
# Behaviour:
#   - If a live container (run or shell) for this disc already exists in
#     docker ps -a, return early (safe guard — never overwrite an in-use dir).
#   - Otherwise: rm -rf the session dir (clean re-seed), cp -a the prototype
#     dir and .json into the session-specific paths.
#   - The .drydock-last-sync staleness marker is NOT copied (rm it from the
#     session dir if present — prototype owns it).
#
# Uses DOCKER seam.
seed_session_config_dir() {
	local disc="$1"
	# Guard against a degenerate empty discriminator: rm -rf "$HOME/.claude-container-"
	# would target the wrong path.  Return early — nothing safe to seed.
	[ -n "$disc" ] || return 0
	local session_dir="$HOME/.claude-container-${disc}"
	local session_json="$HOME/.claude-container-${disc}.json"
	# Live-container guard: project-agnostic — match ANY drydock-*-<disc> or
	# drydock-*-<disc>-shell container, regardless of which project owns it.
	# This prevents a cross-project invocation from re-seeding a live session dir
	# whose discriminator happens to match the current invocation's disc.
	# --format '{{.Names}}' gives one name per line; ^ and $ are exact anchors.
	local _ps_out
	_ps_out="$("$DOCKER" ps -a --format '{{.Names}}' 2>/dev/null)" || true
	if printf '%s\n' "$_ps_out" | grep -qE "^drydock-.+-${disc}(-shell)?$"; then
		return 0
	fi

	# If the prototype does not exist yet, skip seeding.
	# In production, ensure_runtime_dirs always creates it before export_compose_env
	# is called. Tests that bypass ensure_runtime_dirs may land here without a
	# prototype; returning early is safe (no dir to copy = no corruption).
	[ -d "$HOME/.claude-container" ] || return 0

	# Clean re-seed: remove stale session dir.
	rm -rf "$session_dir"

	# Copy prototype dir and .json into session-specific paths.
	cp -a "$HOME/.claude-container" "$session_dir"
	cp -a "$HOME/.claude-container.json" "$session_json"

	# Remove the staleness marker — it belongs to the prototype, not sessions.
	rm -f "$session_dir/.drydock-last-sync"
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
