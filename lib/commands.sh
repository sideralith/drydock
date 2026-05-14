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
  init [DIR] [--update] Initialize a project — creates .claude/settings.json baseline
                        (per-project, like \`git init\`); --update merges new template
                        deny entries into an existing file
  build               Build/rebuild the drydock image
  sync                Sync host ~/.claude/ → ~/.claude-container/
  status              Short health snapshot
  doctor              Detailed diagnostics
  setup               (advanced) One-time host setup — auto-triggered on first
                        run/build/sync if missing; you rarely call this explicitly
  version             Show drydock version
  help                Show this help

Examples:
  cd ~/git/myproject && drydock                # launch claude there
  drydock run ~/git/otherproject               # explicit dir
  drydock run -- --resume "my-session"         # resume a session
  drydock init ~/git/newproject                # baseline for a new project
  drydock init --update                        # merge new template denies
  drydock build                                # rebuild image

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
		for excluded in sessions projects file-history shell-snapshots paste-cache cache backups telemetry ide session-env downloads uploads plans tasks themes; do
			rm -rf "${CONTAINER_CLAUDE:?}/$excluded"
		done
		rm -f "$CONTAINER_CLAUDE/.last-cleanup" "$CONTAINER_CLAUDE/scheduled_tasks.lock"
		mkdir -p "$CONTAINER_CLAUDE"/{sessions,projects,file-history,shell-snapshots,cache,backups,telemetry,plans,tasks,paste-cache}
		ok "$CONTAINER_CLAUDE inicializado ($(du -sh "$CONTAINER_CLAUDE" | cut -f1))"
	else
		ok "$CONTAINER_CLAUDE ya existe ($(du -sh "$CONTAINER_CLAUDE" | cut -f1))"
	fi

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

	note "Done. Next: 'drydock build' (if image not built) and then 'drydock' from inside a project."
}

# Per-project setup. Creates `.claude/settings.json` baseline in the target
# directory. Same mental model as `git init` — once per project.
# With --update: merges new template deny entries into an existing file.
cmd_init() {
	# drydock init [DIR] [--update]
	local project_dir_arg="" do_update=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--update | -u) do_update=1 ;;
		-*) err "drydock init: opción desconocida: $1 (usá --update)" ;;
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
		sed "s|__HOME__|$HOME|g" "$DEFAULT_SETTINGS_TEMPLATE" >"$settings"
		ok "$settings creado con baseline de denies"
	elif [ "$do_update" -eq 1 ]; then
		command -v jq >/dev/null || err "drydock init --update necesita jq"
		jq empty "$settings" 2>/dev/null || err "$settings no es JSON válido — arreglalo a mano o borralo y re-corré drydock init"
		local rendered merged
		rendered="$(sed "s|__HOME__|$HOME|g" "$DEFAULT_SETTINGS_TEMPLATE")"
		merged="$(jq -n --argjson existing "$(cat "$settings")" --argjson template "$rendered" '
			($existing.permissions.deny // []) as $ed
			| ($template.permissions.deny // []) as $td
			| $existing
			| .permissions.deny = ($ed + ($td | map(select(. as $x | ($ed | index($x)) == null))))
		')"
		if [ "$(printf '%s' "$merged" | jq -c '.permissions.deny')" = "$(jq -c '.permissions.deny' "$settings")" ]; then
			ok "$settings ya tiene todas las deny entries del template — sin cambios"
		else
			printf '%s\n' "$merged" >"$settings.tmp.$$" && mv "$settings.tmp.$$" "$settings"
			ok "$settings actualizado — deny entries del template fusionadas (customizaciones preservadas)"
		fi
	else
		warn "$settings ya existe — no lo sobrescribo (usá 'drydock init --update' para fusionar las deny entries nuevas del template)"
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
		${_engram_exclude:+"$_engram_exclude"} \
		/src/ /dst/
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
	ok "Sync done"
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
	local project_dir
	project_dir="$(resolve_project_dir "$project_dir_arg")"

	note "Launching Claude in $project_dir"
	export_compose_env "$project_dir"

	local compose_args=()
	while IFS= read -r arg; do compose_args+=("$arg"); done < <(compose_files "$project_dir")

	exec "$DOCKER" compose "${compose_args[@]}" run --rm drydock claude "${passthrough[@]}"
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
	local project_dir
	project_dir="$(resolve_project_dir "$project_dir_arg")"

	note "Bash shell in container, mounted at $project_dir"
	export_compose_env "$project_dir"

	local compose_args=()
	while IFS= read -r arg; do compose_args+=("$arg"); done < <(compose_files "$project_dir")

	if [ "${#passthrough[@]}" -gt 0 ]; then
		exec "$DOCKER" compose "${compose_args[@]}" run --rm drydock "${passthrough[@]}"
	else
		exec "$DOCKER" compose "${compose_args[@]}" run --rm drydock bash
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
	printf '── current dir context ──\n'
	printf '  pwd:              %s\n' "$PWD"
	if [ -d "$PWD/.claude" ]; then
		if [ -f "$PWD/.claude/settings.json" ]; then
			local deny_count
			deny_count="$(jq -r '.permissions.deny // [] | length' "$PWD/.claude/settings.json" 2>/dev/null || echo '?')"
			printf '  .claude/settings.json: \033[32mfound\033[0m (%s deny entries)\n' "$deny_count"
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
