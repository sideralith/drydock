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
  run [DIR]           Launch Claude in DIR (or cwd)
  shell [DIR]         Bash shell in container, mounted at DIR
  init [DIR]          Initialize a project — creates .claude/settings.json baseline
                        (per-project, like \`git init\`)
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
  drydock init ~/git/newproject                # baseline for a new project
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
	if [ ! -f "$CONTAINER_CLAUDE_JSON" ]; then
		if [ -f "$HOST_CLAUDE_JSON" ]; then
			cp -a "$HOST_CLAUDE_JSON" "$CONTAINER_CLAUDE_JSON"
			ok "$CONTAINER_CLAUDE_JSON inicializado como copia de $HOST_CLAUDE_JSON ($(stat -c '%s bytes' "$CONTAINER_CLAUDE_JSON"))"
		else
			echo '{}' >"$CONTAINER_CLAUDE_JSON"
			ok "$CONTAINER_CLAUDE_JSON creado mínimo (no había $HOST_CLAUDE_JSON para copiar)"
		fi
	else
		ok "$CONTAINER_CLAUDE_JSON ya existe ($(stat -c '%s bytes' "$CONTAINER_CLAUDE_JSON"))"
	fi

	note "Done. Next: 'drydock build' (if image not built) and then 'drydock' from inside a project."
}

# Per-project setup. Creates `.claude/settings.json` baseline in the target
# directory. Same mental model as `git init` — once per project.
cmd_init() {
	local project_dir
	project_dir="$(resolve_project_dir "${1:-}")"
	note "Initializing project at $project_dir"

	mkdir -p "$project_dir/.claude"

	if [ -f "$project_dir/.claude/settings.json" ]; then
		warn "$project_dir/.claude/settings.json ya existe — no lo sobrescribo"
		note "Template baseline disponible en: $DEFAULT_SETTINGS_TEMPLATE"
	else
		sed "s|__HOME__|$HOME|g" "$DEFAULT_SETTINGS_TEMPLATE" >"$project_dir/.claude/settings.json"
		ok "$project_dir/.claude/settings.json creado con baseline de denies"
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
		/src/ /dst/
	# Also refresh ~/.claude.json (project list, onboarding flags, MCP servers).
	# Plain file copy — small (~40KB). The container's copy gets host's current
	# state. Note: this overwrites any project-list changes made inside the
	# container; that's acceptable (host is the canonical project registry).
	if [ -f "$HOST_CLAUDE_JSON" ]; then
		cp -a "$HOST_CLAUDE_JSON" "$CONTAINER_CLAUDE_JSON"
		ok "$CONTAINER_CLAUDE_JSON refreshed from host"
	fi
	ok "Sync done"
}

cmd_run() {
	ensure_prereqs
	ensure_runtime_dirs
	ensure_image
	local project_dir
	project_dir="$(resolve_project_dir "${1:-}")"

	note "Launching Claude in $project_dir"
	export_compose_env "$project_dir"

	local compose_args=()
	while IFS= read -r arg; do compose_args+=("$arg"); done < <(compose_files "$project_dir")

	exec "$DOCKER" compose "${compose_args[@]}" run --rm drydock
}

cmd_shell() {
	ensure_prereqs
	ensure_runtime_dirs
	ensure_image
	local project_dir
	project_dir="$(resolve_project_dir "${1:-}")"

	note "Bash shell in container, mounted at $project_dir"
	export_compose_env "$project_dir"

	local compose_args=()
	while IFS= read -r arg; do compose_args+=("$arg"); done < <(compose_files "$project_dir")

	exec "$DOCKER" compose "${compose_args[@]}" run --rm drydock bash
}

cmd_status() {
	printf '── drydock %s ──\n' "$DRYDOCK_VERSION"
	printf '  DRYDOCK_HOME:       %s\n' "$DRYDOCK_HOME"
	printf '  image %-15s ' "$IMAGE"
	if image_exists; then printf '\033[32mpresent\033[0m\n'; else printf '\033[31mmissing\033[0m → drydock build\n'; fi

	for p in "$CONTAINER_CLAUDE" "$CONTAINER_ENGRAM"; do
		printf '  %-20s ' "$(basename "$p"):"
		if [ -e "$p" ]; then
			printf '\033[32m%s\033[0m\n' "$(du -sh "$p" 2>/dev/null | cut -f1)"
		else
			printf '\033[31mmissing\033[0m → drydock setup\n'
		fi
	done
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
	if [ -d "$PWD/docs" ]; then
		if is_separate_mount "$PWD/docs"; then
			printf '  docs/:            \033[33mseparate mount (9P or similar)\033[0m → docs overlay activates\n'
		else
			printf '  docs/:            \033[32mlocal\033[0m\n'
		fi
	else
		printf '  docs/:            not present (no overlay needed)\n'
	fi
	echo
	printf '── runtime context (for compose) ──\n'
	printf '  USER_UID:         %s\n' "$(id -u)"
	printf '  USER_GID:         %s\n' "$(id -g)"
	printf '  HOST_DOCKER_GID:  %s\n' "$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo '?')"
}
