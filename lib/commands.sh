#!/usr/bin/env bash
# lib/commands.sh — usage() and all cmd_* command implementations
#
# Sourced by bin/drydock (the thin dispatcher). Never sourced directly by
# lib/*.sh siblings — let the dispatcher control the source order.
# Requires: lib/common.sh (DRYDOCK_VERSION, err, warn, note, ok),
#           lib/paths.sh (resolve_project_dir, path constants),
#           lib/compose.sh (image_exists, ensure_*, compose_files, DOCKER).

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
	cat <<EOF
drydock $DRYDOCK_VERSION — containerized Claude Code sandbox

Usage:
  drydock [COMMAND] [ARGS]

Commands:
  (no args)           Default — launch Claude in current directory's project
  run [DIR] [-- ARGS] Launch Claude in DIR (or cwd); ARGS after -- go to claude
                        (e.g. drydock run -- --resume "my-session")
  shell [DIR] [-- CMD] Bash shell in container at DIR; with -- CMD, run CMD instead
  init [DIR]            Initialize a project — creates .claude/settings.json stub
                        (per-project, like \`git init\`); drydock policy lives in the
                        managed-settings layer baked into the image
  build               Build/rebuild the drydock image
  sync                Sync host ~/.claude/ → ~/.claude-container/
  status              Short health snapshot
  doctor              Detailed diagnostics
  setup               (advanced) One-time host setup — auto-triggered on first
                        run/build/sync if missing; you rarely call this explicitly
  link [PATH] [CONTAINER-PATH]
                      Mount a sibling project read-only inside the container.
                        PATH: host directory to mount (required).
                        CONTAINER-PATH: in-container mount target (optional;
                        default: /workspace-siblings/<basename>/).
                        RW links not yet implemented (--rw errors).
  unlink PATH         Remove a sibling mount from the project list.
  links               Show all siblings configured for the current project.
  version             Show drydock version
  help                Show this help

Examples:
  cd ~/git/myproject && drydock                # launch claude there
  drydock run ~/git/otherproject               # explicit dir
  drydock run -- --resume "my-session"         # resume a session
  drydock init ~/git/newproject                # create settings.json stub
  drydock build                                # rebuild image
  drydock link ~/git/shared-lib                # mount sibling read-only
  drydock link ~/git/shared-lib /opt/mylib     # mount at custom path
  drydock unlink ~/git/shared-lib              # remove sibling
  drydock links                                # list current project's siblings

DRYDOCK_HOME=$DRYDOCK_HOME
EOF
}

# ── Commands ──────────────────────────────────────────────────────────────────

# Host-side one-time setup. Idempotent. Auto-called by `ensure_runtime_dirs`
# from cmd_run / cmd_shell / cmd_sync when state is missing, so most users
# never invoke it explicitly.
cmd_setup() {
	ensure_prereqs

	# Engram container dir: only create/seed when engram is usable in the
	# container (Linux host + binary on PATH) AND isolated mode is active.
	# Shared mode: host's ~/.engram is mounted directly — no container dir needed.
	# On macOS or when engram is absent, skip — the overlay never activates.
	if engram_usable; then
		local _engram_sentinel="$HOME/.config/drydock/engram-shared"
		if [ -f "$_engram_sentinel" ]; then
			note "engram: shared mode — host ~/.engram used directly"
		else
			if [ ! -d "$CONTAINER_ENGRAM" ]; then
				if [ -d "$HOST_ENGRAM" ]; then
					cp -a "$HOST_ENGRAM" "$CONTAINER_ENGRAM"
					ok "$CONTAINER_ENGRAM inicializado como copia de $HOST_ENGRAM ($(du -sh "$CONTAINER_ENGRAM" | cut -f1))"
				else
					mkdir -p "$CONTAINER_ENGRAM"
					ok "$CONTAINER_ENGRAM creado vacío (no había $HOST_ENGRAM para copiar)"
				fi
			else
				ok "$CONTAINER_ENGRAM ya existe ($(du -sh "$CONTAINER_ENGRAM" | cut -f1))"
			fi
		fi
	else
		if host_is_linux; then
			note "engram not on PATH — skipped its MCP server in the container (no startup noise). Install engram to enable it."
		else
			note "engram's macOS binary can't run inside the Linux container — skipped its MCP server (no startup noise). A future drydock release may ship a Linux engram in the image."
		fi
	fi

	if [ ! -d "$CONTAINER_CLAUDE" ]; then
		note "Copiando $HOST_CLAUDE → $CONTAINER_CLAUDE (excluyendo session state)..."
		cp -a "$HOST_CLAUDE" "$CONTAINER_CLAUDE"
		# Purge immediately — closes the credential window between cp -a and the
		# deferred unconditional purge below (which covers the upgrade path).
		rm -f "${CONTAINER_CLAUDE:?}/.credentials.json"
		for excluded in sessions projects file-history shell-snapshots paste-cache cache backups telemetry ide session-env downloads uploads plans tasks themes; do
			rm -rf "${CONTAINER_CLAUDE:?}/$excluded"
		done
		rm -f "$CONTAINER_CLAUDE/.last-cleanup" "$CONTAINER_CLAUDE/scheduled_tasks.lock"
		mkdir -p "$CONTAINER_CLAUDE"/{sessions,projects,file-history,shell-snapshots,cache,backups,telemetry,plans,tasks,paste-cache}
		ok "$CONTAINER_CLAUDE inicializado ($(du -sh "$CONTAINER_CLAUDE" | cut -f1))"
	else
		ok "$CONTAINER_CLAUDE ya existe ($(du -sh "$CONTAINER_CLAUDE" | cut -f1))"
	fi
	# Purge any stale OAuth token unconditionally — covers both the fresh-init
	# and the upgrade (already-exists) path.  Uses the fail-safe ${VAR:?} form
	# consistent with the rm -rf calls above.
	rm -f "${CONTAINER_CLAUDE:?}/.credentials.json"

	# ~/.claude.json — the OTHER config location Claude Code reads (project list,
	# onboarding flags, MCP servers, OAuth account). Without a container-specific
	# copy, Claude Code inside the container can't find it, creates a fresh
	# ephemeral one, and "config doesn't persist" across sessions.
	# MCP filter: when engram is not usable in the container, strip the engram
	# MCP server from the copy so Claude Code doesn't try to spawn a missing
	# binary on every startup (zero error noise).
	if [ ! -f "$CONTAINER_CLAUDE_JSON" ]; then
		if [ -f "$HOST_CLAUDE_JSON" ]; then
			if engram_usable; then
				cp -a "$HOST_CLAUDE_JSON" "$CONTAINER_CLAUDE_JSON"
			else
				jq 'del(.mcpServers.engram, .projects[]?.mcpServers.engram)' \
					"$HOST_CLAUDE_JSON" >"$CONTAINER_CLAUDE_JSON"
			fi
			ok "$CONTAINER_CLAUDE_JSON inicializado como copia de $HOST_CLAUDE_JSON ($(stat -c '%s bytes' "$CONTAINER_CLAUDE_JSON"))"
		else
			echo '{}' >"$CONTAINER_CLAUDE_JSON"
			ok "$CONTAINER_CLAUDE_JSON creado mínimo (no había $HOST_CLAUDE_JSON para copiar)"
		fi
	else
		ok "$CONTAINER_CLAUDE_JSON ya existe ($(stat -c '%s bytes' "$CONTAINER_CLAUDE_JSON"))"
	fi

	# MCP filter belt-and-suspenders: remove mcp/engram.json from the container
	# claude dir when engram is not usable (rm -f is a no-op if absent).
	if ! engram_usable; then
		rm -f "${CONTAINER_CLAUDE:?}/mcp/engram.json"
	fi

	# Stamp last-sync marker so the first drydock run after setup is a no-op.
	# touch precedes the "Done" note so the marker exists before the user is told
	# setup succeeded (mirrors the ordering in cmd_sync: touch then ok "Sync done").
	touch "${CONTAINER_CLAUDE:?}/.drydock-last-sync"
	note "Done. Next: 'drydock build' (if image not built) and then 'drydock' from inside a project."
}

# Per-project setup. Creates `.claude/settings.json` stub in the target
# directory. Same mental model as `git init` — once per project.
# drydock policy (deny rules + SessionStart hook) lives in the managed-settings
# layer baked into the image; this stub is for per-project dev customization.
cmd_init() {
	# drydock init [DIR]
	local project_dir_arg=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-*) err "drydock init: opción desconocida: $1" ;;
		*) project_dir_arg="$1" ;;
		esac
		shift
	done

	local project_dir
	project_dir="$(resolve_project_dir "$project_dir_arg")"
	note "Initializing project at $project_dir"

	mkdir -p "$project_dir/.claude"
	local settings="$project_dir/.claude/settings.json"

	if [ ! -f "$settings" ]; then
		cp "$DEFAULT_SETTINGS_TEMPLATE" "$settings"
		ok "$settings creado"
	else
		warn "$settings ya existe — no lo sobrescribo"
		note "Template baseline en: $DEFAULT_SETTINGS_TEMPLATE"
	fi

	if [ -f "$project_dir/.gitignore" ] && ! grep -q '\.claude/settings\.local\.json' "$project_dir/.gitignore"; then
		note "Tip: agregar '.claude/settings.local.json' a .gitignore (settings personales no compartidas)"
	fi

	ok "Done. Lanzá Claude con: cd $project_dir && drydock"
}

cmd_build() {
	ensure_prereqs
	note "Building $IMAGE from $DRYDOCK_HOME..."
	# cmd_build shells out to `docker build` directly (not `docker compose`), so
	# the compose build.args don't reach it — pass USER_NAME explicitly here too.
	"$DOCKER" build \
		--build-arg USER_NAME="$(id -un)" \
		--build-arg USER_UID="$(id -u)" \
		--build-arg USER_GID="$(id -g)" \
		--build-arg HOST_DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 1001)" \
		-t "$IMAGE" \
		"$DRYDOCK_HOME"
	ok "Built $IMAGE"
}

cmd_sync() {
	ensure_prereqs
	ensure_image
	note "Sync $HOST_CLAUDE → $CONTAINER_CLAUDE (excluyendo session state)"
	# MCP filter: when engram is not usable in the container, exclude
	# mcp/engram.json from the rsync so the container config doesn't reference
	# a non-functional binary.
	local _engram_exclude=""
	if ! engram_usable; then
		_engram_exclude="--exclude=mcp/engram.json"
	fi
	"$DOCKER" run --rm \
		-v "$HOST_CLAUDE":/src:ro \
		-v "$CONTAINER_CLAUDE":/dst:rw \
		--user "$(id -u):$(id -g)" \
		"$IMAGE" \
		rsync -au --delete \
		--exclude='sessions/' \
		--exclude='projects/' \
		--exclude='file-history/' \
		--exclude='shell-snapshots/' \
		--exclude='paste-cache/' \
		--exclude='cache/' \
		--exclude='backups/' \
		--exclude='telemetry/' \
		--exclude='plans/' \
		--exclude='tasks/' \
		--exclude='ide/' \
		--exclude='session-env/' \
		--exclude='downloads/' \
		--exclude='uploads/' \
		--exclude='.last-cleanup' \
		--exclude='scheduled_tasks.lock' \
		--exclude='*.bak.pre-dockerized' \
		--exclude='*.bak.pre-dockerized/' \
		--exclude='.credentials.json' \
		--exclude='themes/' \
		--exclude='.drydock-last-sync' \
		${_engram_exclude:+"$_engram_exclude"} \
		/src/ /dst/ || return $?
	# Purge any stale OAuth token from the container.  rsync --exclude prevents
	# the file from being COPIED on new syncs, but --delete never removes excluded
	# files from the destination — so an explicit purge is required to clean up
	# tokens that were copied by pre-exclusion versions of drydock.
	rm -f "${CONTAINER_CLAUDE:?}/.credentials.json"
	# Also refresh ~/.claude.json (project list, onboarding flags, MCP servers).
	# MCP filter: when engram is not usable, strip the engram MCP server entry
	# so Claude Code in the container sees no startup error.
	if [ -f "$HOST_CLAUDE_JSON" ]; then
		if engram_usable; then
			cp -a "$HOST_CLAUDE_JSON" "$CONTAINER_CLAUDE_JSON"
		else
			jq 'del(.mcpServers.engram, .projects[]?.mcpServers.engram)' \
				"$HOST_CLAUDE_JSON" >"$CONTAINER_CLAUDE_JSON"
			if host_is_linux; then
				note "engram not on PATH — skipped its MCP server in the container (no startup noise). Install engram to enable it."
			else
				note "engram's macOS binary can't run inside the Linux container — skipped its MCP server (no startup noise). A future drydock release may ship a Linux engram in the image."
			fi
		fi
		ok "$CONTAINER_CLAUDE_JSON refreshed from host"
	fi
	# Stamp last-sync marker AFTER both rsync and the JSON refresh succeed.
	# Under set -euo pipefail an earlier touch would leave a falsely-fresh marker
	# if the JSON step failed. ensure_synced reads this marker to detect freshness.
	# NOTE: ensure_prereqs / ensure_image are also called by cmd_run / cmd_shell
	# before delegating here — that double call is intentional (idempotent; see design).
	touch "${CONTAINER_CLAUDE:?}/.drydock-last-sync"
	ok "Sync done"
}

# ensure_synced — auto-sync gate for cmd_run / cmd_shell.
# Evaluates staleness of the host ~/.claude/ config relative to the last-sync
# marker.  Calls cmd_sync when stale; is silent on the fresh path.
# Prune set mirrors cmd_sync's rsync --exclude list (including engram conditional).
# Probe includes HOST_CLAUDE_JSON (sibling file, not under HOST_CLAUDE) because
# drydock sync refreshes it and MCP server edits there are a primary motivator.
ensure_synced() {
	[ "$DRYDOCK_SKIP_AUTOSYNC" = "1" ] && return 0
	local marker="$CONTAINER_CLAUDE/.drydock-last-sync"
	if [ ! -f "$marker" ]; then
		cmd_sync || warn "auto-sync failed — continuing without sync"
		return 0
	fi
	# Engram-conditional prune entry: mirrors _engram_exclude in cmd_sync.
	# mcp/engram.json is a file on both sides (find -path and rsync --exclude),
	# no trailing slash either way — no asymmetry here.
	local -a engram_prune=()
	if ! engram_usable; then
		engram_prune=(-o -path '*/mcp/engram.json')
	fi
	# Build probe-paths array: always include HOST_CLAUDE; include HOST_CLAUDE_JSON
	# only when it exists — find emits an error on a missing path.  The guard
	# keeps the probe clean and avoids a spurious non-zero exit from find.
	local -a probe_paths=("$HOST_CLAUDE")
	[ -f "$HOST_CLAUDE_JSON" ] && probe_paths+=("$HOST_CLAUDE_JSON")
	# Find any non-state, non-excluded config file newer than the marker.
	# Prune list is kept byte-for-byte aligned with cmd_sync rsync excludes.
	# Directory entries omit the trailing /* so -prune skips the directory itself
	# before descent, preventing find from walking all files inside large state
	# dirs on every no-op invocation.
	# Deliberate asymmetry: these directory entries use -path '*/sessions' etc.
	# (no trailing slash → matches a file OR a directory of that name), while
	# cmd_sync's rsync uses --exclude='sessions/' (trailing slash → directories
	# only). Safe because Claude Code only ever creates these names as
	# directories in ~/.claude/; a bare file so named is the sole divergence
	# case and not a real scenario. -type d is omitted to keep the compound
	# expression simple.
	# -newer is on the PRINT branch (not the top-level) to avoid printing
	# HOST_CLAUDE_JSON unconditionally when it is not newer than the marker.
	# Output is captured into $hits; find's exit code is captured via find_rc.
	# When find prints a match, its exit code is irrelevant — the non-empty $hits
	# drives the sync regardless. When find prints nothing AND exits non-zero, the
	# probe failed entirely (e.g. HOST_CLAUDE unreadable at traversal start) and
	# we warn so the skipped sync is visible. When find prints nothing AND exits 0,
	# the config is genuinely fresh — the happy-path silent no-op.
	local hits find_rc=0
	hits="$(find "${probe_paths[@]}" \
		\( -path '*/sessions' -o -path '*/projects' \
		-o -path '*/file-history' -o -path '*/shell-snapshots' \
		-o -path '*/paste-cache' -o -path '*/cache' \
		-o -path '*/backups' -o -path '*/telemetry' \
		-o -path '*/plans' -o -path '*/tasks' \
		-o -path '*/ide' -o -path '*/session-env' \
		-o -path '*/downloads' -o -path '*/uploads' \
		-o -path '*/themes' \
		-o -name '.last-cleanup' -o -name 'scheduled_tasks.lock' \
		-o -name '.credentials.json' -o -name '.drydock-last-sync' \
		-o -name '*.bak.pre-dockerized' \
		"${engram_prune[@]}" \) -prune \
		-o -newer "$marker" -type f -print -quit 2>/dev/null)" || find_rc=$?
	if [ -n "$hits" ]; then
		note "auto-sync: host config changed — syncing into container..."
		cmd_sync || warn "auto-sync failed — continuing without sync"
	elif [ "$find_rc" -ne 0 ]; then
		warn "auto-sync: staleness probe failed (find exited $find_rc) — skipping; run 'drydock sync' manually if host config changed"
	fi
}

# pre_flight_notice — non-blocking informational notice printed before starting
# a new drydock session when other sessions for the same project are already
# running. Counts existing drydock-<project>-<disc> containers (run sessions
# only; -shell suffixed containers are excluded by the anchored regex) and
# prints one informational line. Never refuses — exit is always 0 (R5).
# Called from both cmd_run and cmd_shell after export_compose_env.
pre_flight_notice() {
	local existing count
	# Query running containers with an anchored name filter; strip any names the
	# filter passed through that don't strictly match (e.g. -shell variants when
	# the Docker daemon applies the regex less strictly than POSIX ERE).
	existing="$("$DOCKER" ps \
		--filter "name=^drydock-${PROJECT_NAME}-[0-9a-f]+$" \
		--format '{{.Names}}' 2>/dev/null |
		grep -E "^drydock-${PROJECT_NAME}-[0-9a-f]+$" || true)"
	count="$(printf '%s' "$existing" | grep -c . || true)"
	[ "$count" -gt 0 ] && note "drydock: $count existing drydock-${PROJECT_NAME}-* session(s) running; starting another."
	return 0
}

cmd_run() {
	# drydock run [DIR] [-- CLAUDE_ARGS...]
	local project_dir_arg=""
	local -a passthrough=()
	if [ $# -gt 0 ] && [ "$1" != "--" ]; then
		project_dir_arg="$1"
		shift
	fi
	if [ "${1:-}" = "--" ]; then
		shift
		passthrough=("$@")
	fi
	ensure_prereqs
	ensure_runtime_dirs
	ensure_image
	ensure_synced
	local project_dir
	project_dir="$(resolve_project_dir "$project_dir_arg")"

	note "Launching Claude in $project_dir"
	export_compose_env "$project_dir"

	local compose_args=()
	while IFS= read -r arg; do compose_args+=("$arg"); done < <(compose_files "$project_dir")

	# Per-session container name: export_compose_env has already generated a
	# unique DRYDOCK_SESSION_NAME (drydock-<project>-<disc>) via collision retry.
	# No is_container_running guard needed — the discriminator guarantees each
	# invocation gets its own unique name (R4: existing containers are never
	# stopped or killed).
	local _name="$DRYDOCK_SESSION_NAME"
	pre_flight_notice
	exec "$DOCKER" compose "${compose_args[@]}" run --rm --name "$_name" drydock claude "${passthrough[@]}"
}

cmd_shell() {
	# drydock shell [DIR] [-- CMD...]   (no CMD => interactive bash)
	local project_dir_arg=""
	local -a passthrough=()
	if [ $# -gt 0 ] && [ "$1" != "--" ]; then
		project_dir_arg="$1"
		shift
	fi
	if [ "${1:-}" = "--" ]; then
		shift
		passthrough=("$@")
	fi
	ensure_prereqs
	ensure_runtime_dirs
	ensure_image
	ensure_synced
	local project_dir
	project_dir="$(resolve_project_dir "$project_dir_arg")"

	note "Bash shell in container, mounted at $project_dir"
	export_compose_env "$project_dir"

	local compose_args=()
	while IFS= read -r arg; do compose_args+=("$arg"); done < <(compose_files "$project_dir")

	# Per-session container name: export_compose_env generated a fresh discriminator
	# via collision retry, so this shell session gets its OWN unique discriminator
	# and its OWN ~/.claude-container-<disc>/ dir — it does NOT share a config dir
	# with any concurrent drydock run. The -shell suffix further distinguishes the
	# container name so ps output is unambiguous (R4: no existing session killed).
	local _name="${DRYDOCK_SESSION_NAME}-shell"
	pre_flight_notice
	if [ "${#passthrough[@]}" -gt 0 ]; then
		exec "$DOCKER" compose "${compose_args[@]}" run --rm --name "$_name" drydock "${passthrough[@]}"
	else
		exec "$DOCKER" compose "${compose_args[@]}" run --rm --name "$_name" drydock bash
	fi
}

cmd_status() {
	printf '── drydock %s ──\n' "$DRYDOCK_VERSION"
	printf '  DRYDOCK_HOME:       %s\n' "$DRYDOCK_HOME"
	printf '  image %-15s ' "$IMAGE"
	if image_exists; then printf '\033[32mpresent\033[0m\n'; else printf '\033[31mmissing\033[0m → drydock build\n'; fi

	printf '  %-20s ' "$(basename "$CONTAINER_CLAUDE"):"
	if [ -e "$CONTAINER_CLAUDE" ]; then
		printf '\033[32m%s\033[0m\n' "$(du -sh "$CONTAINER_CLAUDE" 2>/dev/null | cut -f1)"
	else
		printf '\033[31mmissing\033[0m → drydock setup\n'
	fi

	# Engram status: re-derive mode inline (no call to export_compose_env — cmd_status
	# has no project-dir arg and must NOT call export_compose_env). Deliberate
	# duplication per design — the two callers have different inputs/side-effects.
	printf '  %-20s ' "engram:"
	if engram_usable; then
		local _status_sentinel="$HOME/.config/drydock/engram-shared"
		if [ -f "$_status_sentinel" ]; then
			if host_fs_locks_unreliable && [ "${DRYDOCK_ENGRAM_SHARED:-}" != "force" ]; then
				printf '\033[33mshared requested → forced isolated (unreliable bind-mount locks; set DRYDOCK_ENGRAM_SHARED=force to override)\033[0m\n'
			else
				printf '\033[32mshared (~/.engram)\033[0m\n'
			fi
		else
			printf '\033[32misolated (~/.engram-container)\033[0m'
			if [ -d "$CONTAINER_ENGRAM" ]; then
				printf ' (%s)\n' "$(du -sh "$CONTAINER_ENGRAM" 2>/dev/null | cut -f1)"
			else
				printf '\n'
			fi
		fi
	else
		printf '\033[33mnot detected (opt-in)\033[0m\n'
	fi
	printf '  %-20s ' ".claude-container.json:"
	if [ -f "$CONTAINER_CLAUDE_JSON" ]; then
		printf '\033[32m%s\033[0m\n' "$(stat -c '%s bytes' "$CONTAINER_CLAUDE_JSON" 2>/dev/null)"
	else
		printf '\033[31mmissing\033[0m → drydock setup\n'
	fi

	printf '  docker.sock:        '
	if [ -S /var/run/docker.sock ]; then
		printf '\033[32mok\033[0m (GID %s)\n' "$(stat -c '%g' /var/run/docker.sock)"
	else
		printf '\033[31mmissing\033[0m\n'
	fi
}

cmd_doctor() {
	cmd_status
	echo
	printf '── runtime versions ──\n'
	# Deliberately call the real docker binary (not $DOCKER) — these are
	# diagnostic probes, not routed operations.
	printf '  docker:           %s\n' "$(docker --version 2>/dev/null || echo MISSING)"
	printf '  docker compose:   %s\n' "$(docker compose version --short 2>/dev/null || echo MISSING)"
	if image_exists; then
		printf '  drydock image:    %s\n' "$(docker image inspect "$IMAGE" --format '{{.Created}}')"
	fi
	echo
	printf '── drydock policy ──\n'
	local _policy_count=0
	for _f in "$DRYDOCK_HOME/templates/managed-settings.d/"*.json; do
		[ -f "$_f" ] || continue
		local _n
		_n="$(jq '(.permissions.deny // []) | length' "$_f" 2>/dev/null || echo 0)"
		_policy_count=$((_policy_count + _n))
	done
	printf '  managed-settings:  \033[32m%s deny rules\033[0m (image-baked policy layer — always active)\n' "$_policy_count"
	echo
	printf '── current dir context ──\n'
	printf '  pwd:              %s\n' "$PWD"
	if [ -d "$PWD/.claude" ]; then
		if [ -f "$PWD/.claude/settings.json" ]; then
			printf '  .claude/settings.json: \033[32mfound\033[0m (project customization)\n'
		else
			printf '  .claude/settings.json: \033[33mmissing\033[0m → drydock init\n'
		fi
	else
		printf '  .claude/:         \033[33mmissing\033[0m → drydock init\n'
	fi
	printf '── sub-mounts under %s ──\n' "$PWD"
	local _detected
	# Do NOT suppress stderr — warnings from generate_submount_overlay
	# (linux-native fallback miss, exotic class) are diagnostic signal.
	_detected=$(detect_submounts "$PWD") || true
	if [ -z "$_detected" ]; then
		printf '  (none detected)\n'
	else
		local _docker_src _mount_pt _class
		while IFS='|' read -r _docker_src _mount_pt _class; do
			case "$_class" in
			drvfs)
				printf '  \033[32m✓\033[0m %s → %s (drvfs auto-translated)\n' "$_mount_pt" "$_docker_src"
				;;
			linux-native)
				if [ -z "$_docker_src" ]; then
					printf '  \033[33m⚠\033[0m %s → (source FS root not found — will be skipped)\n' "$_mount_pt"
				else
					printf '  \033[32m✓\033[0m %s → %s (Linux-native bind)\n' "$_mount_pt" "$_docker_src"
				fi
				;;
			exotic:*)
				printf '  \033[33m⚠\033[0m %s → %s (%s, may not propagate)\n' "$_mount_pt" "$_docker_src" "${_class#exotic:}"
				;;
			esac
		done <<<"$_detected"
	fi
	echo
	printf '── runtime context (for compose) ──\n'
	printf '  USER_UID:         %s\n' "$(id -u)"
	printf '  USER_GID:         %s\n' "$(id -g)"
	printf '  HOST_DOCKER_GID:  %s\n' "$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo '?')"
}

# ── Link helpers ──────────────────────────────────────────────────────────────

# _current_project_name — sanitized basename of the resolved cwd project dir.
# Pure string transform; no subprocess or compose dependency.
_current_project_name() {
	sanitize_project_name "$(basename "$(resolve_project_dir "")")"
}

# _links_list_file — path to the durable per-project link list.
# Format: ~/.config/drydock/links/<project>.list
_links_list_file() {
	printf '%s/.config/drydock/links/%s.list\n' "$HOME" "$(_current_project_name)"
}

# ── cmd_link ──────────────────────────────────────────────────────────────────

# cmd_link [--rw] <host-path> [container-target]
# Validates and appends a sibling entry to the project list file.
# RO-only this slice; --rw is parsed and rejected with a stub error.
cmd_link() {
	local rw=0
	local src="" target_arg=""

	# Parse args: --rw flag, then 1-2 positional args
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--rw)
			rw=1
			shift
			;;
		-*)
			err "unknown option: $1"
			;;
		*)
			if [ -z "$src" ]; then
				src="$1"
			elif [ -z "$target_arg" ]; then
				target_arg="$1"
			else
				err "too many arguments"
			fi
			shift
			;;
		esac
	done

	# SP-3: --rw is parsed but not yet implemented
	if [ "$rw" -eq 1 ]; then
		err "RW links not yet implemented"
	fi

	[ -n "$src" ] || err "usage: drydock link <host-path> [container-target]"

	# D7: canonicalize BEFORE all guards
	local canonical
	canonical="$(realpath "$src" 2>/dev/null)" || err "path does not exist: $src"

	# SP-6: host-source rejection guard
	# Reject $HOME itself, ancestors of $HOME, and sensitive subdirs.
	# Use [[ ]] for prefix matching; handle root "/" specially.
	if [ "$canonical" = "$HOME" ]; then
		err "rejected: '$canonical' is \$HOME"
	fi
	# Ancestor check: canonical is an ancestor of HOME when HOME starts with canonical/
	# Special-case root "/" which would produce a double-slash in pattern.
	if [ "$canonical" = "/" ] || [[ "$HOME/" == "$canonical/"* ]]; then
		err "rejected: '$canonical' is an ancestor of \$HOME"
	fi
	# Sensitive subdir check: prefix comparison on canonical
	if [[ "$canonical/" == "$HOME/.claude"* ]] \
		|| [[ "$canonical/" == "$HOME/.engram"* ]] \
		|| [[ "$canonical/" == "$HOME/.config/drydock"* ]]; then
		err "rejected: '$canonical' is under a drydock-managed path"
	fi

	# Reject the project's own directory
	local project_dir
	project_dir="$(resolve_project_dir "")"
	if [ "$canonical" = "$project_dir" ]; then
		err "rejected: '$canonical' is the current project directory (already mounted at /workspace)"
	fi

	# Derive <name> = basename of canonical host path
	local name
	name="$(basename "$canonical")"

	# Compute container target (default or custom)
	local container_target
	if [ -n "$target_arg" ]; then
		container_target="$target_arg"
		# SP-7: custom target rejection guard (FIX #2 — replaces incomplete denylist).
		# (a) Must be an absolute path.
		if [[ "$container_target" != /* ]]; then
			err "rejected: container target '$container_target' must be an absolute path"
		fi
		# (b) Reject root /.
		if [ "$container_target" = "/" ]; then
			err "rejected: container target '/' is the filesystem root"
		fi
		# (d) Explicitly reject the RO hooks mount path (INV-3): /opt/drydock/hooks.
		# Checked BEFORE the generic /opt system-dir reject so the error message
		# names INV-3 specifically. Bind-mounted :ro per docker-compose.yml line 84;
		# a shadowing sibling mount would silently bypass the read-only guardrail.
		if [[ "$container_target/" == "/opt/drydock/hooks/"* ]] || [ "$container_target" = "/opt/drydock/hooks" ]; then
			err "rejected: container target '$container_target' shadows the drydock hooks RO mount (INV-3)"
		fi
		# (c) Reject targets whose first path component is a system directory.
		local _first_comp
		_first_comp="${container_target#/}"
		_first_comp="${_first_comp%%/*}"
		case "$_first_comp" in
		etc|bin|sbin|usr|lib|lib32|lib64|boot|root|opt|proc|sys|dev|run|var)
			err "rejected: container target '$container_target' is under a system directory (/$_first_comp)"
			;;
		esac
		# (e) Reject paths that shadow /workspace or drydock-managed home dirs.
		# Append trailing / so "/workspace" and "/workspace/sub" both match.
		case "$container_target/" in
		"/workspace/"*)
			err "rejected: container target '$container_target' shadows /workspace"
			;;
		"$HOME/.claude"*)
			err "rejected: container target '$container_target' shadows container state"
			;;
		"$HOME/.engram"*)
			err "rejected: container target '$container_target' shadows container state"
			;;
		"$HOME/.config/drydock"*)
			err "rejected: container target '$container_target' shadows drydock config"
			;;
		esac
	else
		container_target="/workspace-siblings/$name/"
	fi

	# ADR-5: basename collision check + container-target uniqueness check
	local list_file
	list_file="$(_links_list_file)"
	if [ -f "$list_file" ]; then
		local existing_host existing_target existing_name
		while IFS='|' read -r existing_host existing_target _; do
			[ -z "$existing_host" ] && continue
			existing_name="$(basename "$existing_host")"
			if [ "$existing_name" = "$name" ] && [ "$existing_host" != "$canonical" ]; then
				err "basename collision: '$name' is already used by '$existing_host'; cannot also link '$canonical'"
			fi
			# Idempotent: same host path already present
			if [ "$existing_host" = "$canonical" ]; then
				note "already linked: $canonical"
				return 0
			fi
			# FIX #3: container target uniqueness — two entries sharing the same
			# container target would cause Docker Compose to silently keep only one.
			if [ -n "$existing_target" ] && [ "$existing_target" = "$container_target" ]; then
				err "container target collision: '$container_target' is already used by '$existing_host'"
			fi
		done < "$list_file"
	fi

	# Append entry (create dir+file if absent)
	mkdir -p "$(dirname "$list_file")"
	printf '%s|%s|\n' "$canonical" "$container_target" >> "$list_file"
	ok "linked: $canonical → $container_target (ro)"
}

# ── cmd_unlink ────────────────────────────────────────────────────────────────

# cmd_unlink <host-path>
# Removes the matching entry from the project list file.
# Exits non-zero when the path is not found in the list.
cmd_unlink() {
	local src="${1:-}"
	[ -n "$src" ] || err "usage: drydock unlink <host-path>"

	# Canonicalize input for consistent comparison
	local canonical
	canonical="$(realpath "$src" 2>/dev/null || printf '%s' "$src")"

	local list_file
	list_file="$(_links_list_file)"

	# Existence check anchored to first field: $1 == canonical (awk -F'|').
	# grep -F "${canonical}|" would match the literal string anywhere on the
	# line, including inside the target column — silent deletion of the wrong
	# entry. awk field-equality is exact.
	if [ ! -f "$list_file" ] || ! awk -F'|' -v c="$canonical" '$1==c{f=1} END{exit !f}' "$list_file"; then
		err "not linked: $canonical"
	fi

	# Remove lines whose first field equals canonical (anchored to host column).
	# awk exits 0 even when no output lines remain — set -e safe.
	local tmp_file
	tmp_file="${list_file}.tmp$$"
	awk -F'|' -v c="$canonical" '$1!=c' "$list_file" > "$tmp_file"
	mv "$tmp_file" "$list_file"
	ok "unlinked: $canonical"
}

# ── cmd_links ─────────────────────────────────────────────────────────────────

# cmd_links
# Prints all sibling entries for the current project, one per line.
# Empty list: silent exit 0.
cmd_links() {
	local list_file
	list_file="$(_links_list_file)"

	[ -f "$list_file" ] || return 0

	local host target
	while IFS='|' read -r host target _; do
		[ -z "$host" ] && continue
		printf '%s -> %s\n' "$host" "$target"
	done < "$list_file"
}
