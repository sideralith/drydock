#!/usr/bin/env bash
# lib/commands.sh — usage() and all cmd_* command implementations
#
# Sourced by bin/drydock (the thin dispatcher). Never sourced directly by
# lib/*.sh siblings — let the dispatcher control the source order.
# Requires: lib/common.sh (DRYDOCK_VERSION, err, warn, note, ok),
#           lib/paths.sh (resolve_project_dir, path constants),
#           lib/compose.sh (image_exists, ensure_*, compose_files, DOCKER).

# ── CLAUDE_BIN seam ───────────────────────────────────────────────────────────
# Override in tests: export CLAUDE_BIN=/path/to/fake-claude before sourcing.
# Matches the DOCKER/UNAME/DRYDOCK_DISCRIMINATOR_FN seam idiom.
: "${CLAUDE_BIN:=claude}"

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
	# Source the rendering helpers from the doctor/status layout so help shares
	# the same visual language (CAPS sections, dim descriptions, TTY-aware
	# colors). When run via `drydock help`, lib/compose.sh has already been
	# sourced — the helpers are defined.
	_dr_init_style

	# ── Title — bold name + dim tagline on the same line ──
	printf '\n  %s─ drydock %s%s%s — containerized Claude Code sandbox%s\n' \
		"$_DR_BOLD" "$DRYDOCK_VERSION" "$_DR_RESET" \
		"$_DR_DIM" "$_DR_RESET"

	# ── USAGE ──
	_dr_section "USAGE"
	printf '   drydock [COMMAND] [ARGS]\n'

	# ── COMMANDS ──
	_dr_section "COMMANDS"
	local _DR_LABEL_WIDTH=28
	_dr_help_row "(no args)" "Default — launch Claude in current directory's project"
	_dr_help_row "run [DIR] [-- ARGS]" "Launch Claude in DIR (or cwd); ARGS after -- go to claude"
	_dr_help_row "shell [DIR] [-- CMD]" "Bash shell in container; with -- CMD, run CMD instead"
	_dr_help_row "build" "Build / rebuild the drydock image"
	_dr_help_row "sync" "Sync host ~/.claude/ → ~/.claude-container/"
	_dr_help_row "status" "Short health snapshot"
	_dr_help_row "doctor" "Detailed diagnostics + current-project context"
	_dr_help_row "setup" "(advanced) One-time host setup — auto-runs when needed"
	_dr_help_row "setup-token" "(advanced) Generate a 1-year Claude OAuth token for container auth"
	_dr_help_row "revoke-token" "Delete the local OAuth token file (server-side: claude.ai settings)"
	_dr_help_row "link [--rw] PATH [TGT]" "Mount a sibling project inside the container"
	_dr_help_row "unlink [--rw] PATH" "Remove a sibling mount from the project list"
	_dr_help_row "links" "Show all linked siblings for the current project"
	_dr_help_row "version" "Show drydock version"
	_dr_help_row "help" "Show this help"

	# ── EXAMPLES ──
	_dr_section "EXAMPLES"
	_DR_LABEL_WIDTH=42
	_dr_help_row "cd ~/git/myproject && drydock" "launch claude there"
	_dr_help_row "drydock run ~/git/otherproject" "explicit dir"
	_dr_help_row 'drydock run -- --resume "my-session"' "resume a session"
	_dr_help_row "drydock build" "rebuild image"
	_dr_help_row "drydock link ~/git/shared-lib" "mount sibling read-only"
	_dr_help_row "drydock link --rw ~/git/shared-lib" "RW + per-sibling deploy key"
	_dr_help_row "drydock link ~/git/shared-lib /opt/lib" "mount at custom path"
	_dr_help_row "drydock unlink ~/git/shared-lib" "remove sibling"
	_dr_help_row "drydock links" "list current project's siblings"

	# ── ENV ──
	_dr_section "ENV"
	_DR_LABEL_WIDTH=18
	_dr_help_row "DRYDOCK_HOME" "$DRYDOCK_HOME"
	printf '\n'
}

# _dr_help_row LABEL DESCRIPTION — help-table row.
# Two columns: bold-ish label + dim description. No status icon (help is not
# a status check). Label width is set per section via _DR_LABEL_WIDTH.
# Defined here near usage() so the help styling lives close to its consumer.
_dr_help_row() {
	local label="$1" desc="${2:-}"
	local width="${_DR_LABEL_WIDTH:-28}"
	if [ -n "$desc" ]; then
		printf '   %-*s %s%s%s\n' "$width" "$label" "$_DR_DIM" "$desc" "$_DR_RESET"
	else
		printf '   %s\n' "$label"
	fi
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
					ok "$CONTAINER_ENGRAM initialized as copy of $HOST_ENGRAM ($(du -sh "$CONTAINER_ENGRAM" | cut -f1))"
				else
					mkdir -p "$CONTAINER_ENGRAM"
					ok "$CONTAINER_ENGRAM created empty ($HOST_ENGRAM did not exist to copy from)"
				fi
			else
				ok "$CONTAINER_ENGRAM already exists ($(du -sh "$CONTAINER_ENGRAM" | cut -f1))"
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
		note "Copying $HOST_CLAUDE → $CONTAINER_CLAUDE (excluding session state)..."
		cp -a "$HOST_CLAUDE" "$CONTAINER_CLAUDE"
		# Purge immediately — closes the credential window between cp -a and the
		# deferred unconditional purge below (which covers the upgrade path).
		rm -f "${CONTAINER_CLAUDE:?}/.credentials.json"
		for excluded in sessions projects file-history shell-snapshots paste-cache cache backups telemetry ide session-env downloads uploads plans tasks themes; do
			rm -rf "${CONTAINER_CLAUDE:?}/$excluded"
		done
		rm -f "$CONTAINER_CLAUDE/.last-cleanup" "$CONTAINER_CLAUDE/scheduled_tasks.lock"
		mkdir -p "$CONTAINER_CLAUDE"/{sessions,projects,file-history,shell-snapshots,cache,backups,telemetry,plans,tasks,paste-cache}
		ok "$CONTAINER_CLAUDE initialized ($(du -sh "$CONTAINER_CLAUDE" | cut -f1))"
	else
		ok "$CONTAINER_CLAUDE already exists ($(du -sh "$CONTAINER_CLAUDE" | cut -f1))"
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
			ok "$CONTAINER_CLAUDE_JSON initialized as copy of $HOST_CLAUDE_JSON ($(stat -c '%s bytes' "$CONTAINER_CLAUDE_JSON"))"
		else
			echo '{}' >"$CONTAINER_CLAUDE_JSON"
			ok "$CONTAINER_CLAUDE_JSON created minimal ($HOST_CLAUDE_JSON did not exist to copy from)"
		fi
	else
		ok "$CONTAINER_CLAUDE_JSON already exists ($(stat -c '%s bytes' "$CONTAINER_CLAUDE_JSON"))"
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

# NOTE: `drydock init` (cmd_init) was removed in v0.2.1. Pre-v0.2.0 it seeded
# `.claude/settings.json` with drydock's full policy (deny rules + SessionStart
# hook). Post-v0.2.0 the policy moved to image-baked managed-settings (INV-3),
# leaving init as a vestigial empty-stub creator with no load-bearing role.
# Claude Code creates `.claude/settings.json` on its own when the user adds
# MCP servers, hooks, or permissions through normal commands — so a dedicated
# drydock init command no longer adds value. Removed cleanly: no deprecation
# stub kept (drydock is pre-1.0 and no users depend on it yet).

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
	note "Sync $HOST_CLAUDE → $CONTAINER_CLAUDE (excluding session state)"
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

# ── doctor/status rendering helpers ──────────────────────────────────────────
# Modern, hierarchical layout: title bar → uppercase section headers → indented
# items with status-icon prefix. No Nerd-Font glyphs (Unicode-standard symbols
# only: ✓ · ⚠ ✗) so it renders identically on any UTF-8 terminal. Color and
# bold are applied ONLY when stdout is a TTY — piped/captured output is plain
# text so logs, screenshots-via-cat, and CI capture remain readable.

# _dr_init_style — populate ANSI escape vars (or empty strings if non-TTY).
# Idempotent; safe to call from each entry point.
_dr_init_style() {
	if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
		_DR_BOLD=$'\033[1m'
		_DR_DIM=$'\033[2m'
		_DR_RESET=$'\033[0m'
		_DR_GREEN=$'\033[32m'
		_DR_YELLOW=$'\033[33m'
		_DR_RED=$'\033[31m'
		_DR_GRAY=$'\033[90m'
		_DR_CYAN=$'\033[36m'
	else
		_DR_BOLD="" _DR_DIM="" _DR_RESET=""
		_DR_GREEN="" _DR_YELLOW="" _DR_RED=""
		_DR_GRAY="" _DR_CYAN=""
	fi
}

# _dr_title — top banner. "─ drydock <ver>" in bold, leading blank line for
# breathing room when running back-to-back commands in the same terminal.
_dr_title() {
	printf '\n  %s─ drydock %s%s\n' "$_DR_BOLD" "$DRYDOCK_VERSION" "$_DR_RESET"
}

# _dr_section TITLE [SUBTITLE] — section header. CAPS title (bold), optional
# dim subtitle joined by an em dash. Always preceded by a blank line to make
# sections scannable.
_dr_section() {
	local title="$1" subtitle="${2:-}"
	printf '\n  %s%s%s' "$_DR_BOLD" "$title" "$_DR_RESET"
	if [ -n "$subtitle" ]; then
		printf '%s — %s%s' "$_DR_DIM" "$subtitle" "$_DR_RESET"
	fi
	printf '\n'
}

# _dr_item ICON LABEL VALUE [METADATA] — item row.
# ICON: ✓ (green ok), · (gray info), ⚠ (yellow warn), ✗ (red error)
# Label is left-padded to a fixed width so columns align within a section.
# METADATA (optional) is appended in dim style, prefixed by " · " when there
# is a value to separate from. When VALUE is empty, METADATA renders inline
# in dim — no orphan "·" marker. Section-level override of the label width
# is available via _DR_LABEL_WIDTH (defaults to 24); useful for sections with
# longer labels (e.g. compose overlay filenames).
_dr_item() {
	local icon="$1" label="$2" value="${3:-}" meta="${4:-}"
	local color=""
	case "$icon" in
	"✓") color="$_DR_GREEN" ;;
	"⚠") color="$_DR_YELLOW" ;;
	"✗") color="$_DR_RED" ;;
	"·") color="$_DR_GRAY" ;;
	esac
	local width="${_DR_LABEL_WIDTH:-24}"
	if [ -n "$value" ]; then
		printf '   %s%s%s %-*s %s' "$color" "$icon" "$_DR_RESET" "$width" "$label" "$value"
		if [ -n "$meta" ]; then
			printf ' %s· %s%s' "$_DR_DIM" "$meta" "$_DR_RESET"
		fi
	elif [ -n "$meta" ]; then
		# No value but meta present — render meta inline in dim, no orphan "·".
		printf '   %s%s%s %-*s %s%s%s' "$color" "$icon" "$_DR_RESET" "$width" "$label" "$_DR_DIM" "$meta" "$_DR_RESET"
	else
		# No value, no meta — bare label, no trailing whitespace.
		printf '   %s%s%s %s' "$color" "$icon" "$_DR_RESET" "$label"
	fi
	printf '\n'
}

cmd_status() {
	_dr_init_style
	_dr_title

	_dr_section "SYSTEM"
	_dr_item "·" "DRYDOCK_HOME" "$DRYDOCK_HOME"
	if image_exists; then
		_dr_item "✓" "image" "$IMAGE" "present"
	else
		_dr_item "✗" "image" "$IMAGE" "missing → drydock build"
	fi
	if [ -S /var/run/docker.sock ]; then
		_dr_item "✓" "docker.sock" "ok" "GID $(stat -c '%g' /var/run/docker.sock)"
	else
		_dr_item "✗" "docker.sock" "missing"
	fi

	_dr_section "STATE"
	# .claude-container directory (the prototype seeded from host ~/.claude/)
	if [ -e "$CONTAINER_CLAUDE" ]; then
		_dr_item "✓" "$(basename "$CONTAINER_CLAUDE")" \
			"$(du -sh "$CONTAINER_CLAUDE" 2>/dev/null | cut -f1)"
	else
		_dr_item "✗" "$(basename "$CONTAINER_CLAUDE")" "missing" "drydock setup"
	fi
	# .claude-container.json (the prototype's sibling JSON config)
	if [ -f "$CONTAINER_CLAUDE_JSON" ]; then
		_dr_item "✓" "$(basename "$CONTAINER_CLAUDE_JSON")" \
			"$(stat -c '%s bytes' "$CONTAINER_CLAUDE_JSON" 2>/dev/null)"
	else
		_dr_item "✗" "$(basename "$CONTAINER_CLAUDE_JSON")" "missing" "drydock setup"
	fi
	# Engram status: re-derive mode inline (no call to export_compose_env —
	# cmd_status has no project-dir arg and must NOT call export_compose_env).
	# Deliberate duplication per design — the two callers have different inputs.
	if engram_usable; then
		local _status_sentinel="$HOME/.config/drydock/engram-shared"
		if [ -f "$_status_sentinel" ]; then
			if host_fs_locks_unreliable && [ "${DRYDOCK_ENGRAM_SHARED:-}" != "force" ]; then
				_dr_item "⚠" "engram" "shared requested → forced isolated" \
					"unreliable bind-mount locks; set DRYDOCK_ENGRAM_SHARED=force to override"
			else
				_dr_item "✓" "engram" "shared (~/.engram)"
			fi
		else
			local _engram_size=""
			[ -d "$CONTAINER_ENGRAM" ] && _engram_size="$(du -sh "$CONTAINER_ENGRAM" 2>/dev/null | cut -f1)"
			# Tilde-literal is intentional — display text shown to the user
			# (e.g. "isolated · ~/.engram-container · 53M"), not a path the
			# shell needs to expand. The single-quote workaround does not
			# suppress SC2088, so disable directly per shellcheck conventions.
			# shellcheck disable=SC2088
			_dr_item "✓" "engram" "isolated" \
				"~/.engram-container${_engram_size:+ · $_engram_size}"
		fi
	else
		_dr_item "·" "engram" "not detected" "opt-in — see docs/engram.md"
	fi
}

cmd_doctor() {
	cmd_status

	# ── VERSIONS ────────────────────────────────────────────────────────────────
	# Deliberately call the real docker binary (not $DOCKER) — these are
	# diagnostic probes, not routed operations.
	_dr_section "VERSIONS"
	local _docker_ver _compose_ver
	_docker_ver="$(docker --version 2>/dev/null | sed 's/^Docker version //; s/, build .*//')"
	_compose_ver="$(docker compose version --short 2>/dev/null)"
	_dr_item "${_docker_ver:+✓}" "docker" "${_docker_ver:-MISSING}"
	_dr_item "${_compose_ver:+✓}" "docker compose" "${_compose_ver:-MISSING}"
	if image_exists; then
		_dr_item "✓" "drydock image" "$(docker image inspect "$IMAGE" --format '{{.Created}}' 2>/dev/null | cut -d'T' -f1)" "built"
	fi

	# ── POLICY ─────────────────────────────────────────────────────────────────
	_dr_section "POLICY"
	local _policy_count=0
	for _f in "$DRYDOCK_HOME/templates/managed-settings.d/"*.json; do
		[ -f "$_f" ] || continue
		local _n
		_n="$(jq '(.permissions.deny // []) | length' "$_f" 2>/dev/null || echo 0)"
		_policy_count=$((_policy_count + _n))
	done
	_dr_item "✓" "managed-settings" "${_policy_count} deny rules" "image-baked, always active"

	# ── PROJECT ────────────────────────────────────────────────────────────────
	# .claude/ is OPTIONAL post-v0.2.0 — drydock's safety policy lives in the
	# image-baked managed-settings layer (INV-3), not in per-project settings.
	# Claude Code creates .claude/settings.json on its own when the user adds
	# MCP servers, hooks, or permissions. Doctor reports presence as info, not
	# a warning — its absence is the common, expected case.
	_dr_section "PROJECT" "$PWD"
	if [ -d "$PWD/.claude" ]; then
		if [ -f "$PWD/.claude/settings.json" ]; then
			_dr_item "✓" ".claude/settings.json" "found" "project customization"
		else
			_dr_item "·" ".claude/" "present" "no settings.json yet"
		fi
	else
		_dr_item "·" ".claude/" "(none)" "no project customization"
	fi

	# ── SUB-MOUNTS ─────────────────────────────────────────────────────────────
	_dr_section "SUB-MOUNTS" "under $PWD"
	local _detected
	# Do NOT suppress stderr — warnings from generate_submount_overlay
	# (linux-native fallback miss, exotic class) are diagnostic signal.
	_detected=$(detect_submounts "$PWD") || true
	if [ -z "$_detected" ]; then
		_dr_item "·" "(none detected)" ""
	else
		local _docker_src _mount_pt _class
		while IFS='|' read -r _docker_src _mount_pt _class; do
			case "$_class" in
			drvfs)
				_dr_item "✓" "$_mount_pt" "→ $_docker_src" "drvfs auto-translated"
				;;
			linux-native)
				if [ -z "$_docker_src" ]; then
					_dr_item "⚠" "$_mount_pt" "(source FS root not found)" "will be skipped"
				else
					_dr_item "✓" "$_mount_pt" "→ $_docker_src" "Linux-native bind"
				fi
				;;
			exotic:*)
				_dr_item "⚠" "$_mount_pt" "→ $_docker_src" "${_class#exotic:}, may not propagate"
				;;
			esac
		done <<<"$_detected"
	fi

	# ── LINKED SIBLINGS ────────────────────────────────────────────────────────
	# Reads the same per-project list file as `drydock links`
	# (~/.config/drydock/links/<project>.list).
	_dr_section "LINKED SIBLINGS"
	local _links_file _links_host _links_target _links_flags _links_mode
	_links_file="$(_links_list_file)"
	if [ ! -s "$_links_file" ]; then
		_dr_item "·" "(none linked)" "" 'drydock link <path> to add'
	else
		while IFS='|' read -r _links_host _links_target _links_flags; do
			[ -z "$_links_host" ] && continue
			if [ "${_links_flags:-}" = "rw" ]; then
				_links_mode="rw"
			else
				_links_mode="ro"
			fi
			_dr_item "✓" "$_links_host" "→ $_links_target" "$_links_mode"
		done <"$_links_file"
	fi

	# ── ACTIVE SESSIONS ────────────────────────────────────────────────────────
	# Lists running drydock containers scoped to the current project. Includes both
	# run sessions (drydock-<proj>-<disc>) and shell companions (-<disc>-shell).
	# Awareness signal for concurrent-sessions (INV-2) — never refuses, info-only.
	_dr_section "ACTIVE SESSIONS" "this project"
	local _proj_name _sess_lines _sess_name _sess_status
	_proj_name="$(_current_project_name)"
	_sess_lines="$("$DOCKER" ps \
		--filter "name=^drydock-${_proj_name}-[0-9a-f]+(-shell)?\$" \
		--format '{{.Names}}|{{.Status}}' 2>/dev/null || true)"
	# Some Docker versions don't fully honor anchored ERE in --filter; post-filter
	# defensively so cross-project containers can never leak in.
	_sess_lines="$(printf '%s\n' "$_sess_lines" | grep -E "^drydock-${_proj_name}-[0-9a-f]+(-shell)?\|" || true)"
	if [ -z "$_sess_lines" ]; then
		_dr_item "·" "(none running)" ""
	else
		while IFS='|' read -r _sess_name _sess_status; do
			[ -z "$_sess_name" ] && continue
			_dr_item "✓" "$_sess_name" "$_sess_status"
		done <<<"$_sess_lines"
	fi

	# ── COMPOSE OVERLAYS ───────────────────────────────────────────────────────
	# Mirrors the conditions in compose_files() WITHOUT calling it — compose_files
	# writes temp overlay files as a side effect, which doctor must not do.
	# Wider label column for this section — compose filenames run up to 31 chars.
	_dr_section "COMPOSE OVERLAYS" "what would activate now"
	local _DR_LABEL_WIDTH=32
	_dr_item "✓" "docker-compose.yml" "" "base"
	if [ "${DRYDOCK_NO_HARDENING:-0}" != "1" ]; then
		_dr_item "✓" "docker-compose.hardening.yml" "" "INV-8: cap_drop, no-new-privileges, tmpfs cap"
	else
		_dr_item "⚠" "hardening overlay" "DISABLED" "DRYDOCK_NO_HARDENING=1"
	fi
	# Sub-mounts: detect-only probe; no overlay file generated.
	if [ -n "$(detect_submounts "$PWD" 2>/dev/null || true)" ]; then
		_dr_item "✓" "docker-compose.submounts-*.yml" "" "sub-mounts detected"
	fi
	# Links: cheap file check; no generation.
	if [ -s "$_links_file" ]; then
		_dr_item "✓" "docker-compose.links-*.yml" "" "linked siblings present"
	fi
	# SSH overlay: any deploy key file under ~/.config/drydock/keys/ triggers it.
	local _keys_dir="$HOME/.config/drydock/keys"
	if [ -d "$_keys_dir" ] && compgen -G "$_keys_dir/*_deploy" >/dev/null 2>&1; then
		_dr_item "✓" "docker-compose.ssh.yml" "" "deploy keys present"
	fi
	# GPG overlay: requires signing config dir on host.
	if [ -d "$HOME/.config/drydock/signing" ]; then
		_dr_item "✓" "docker-compose.gpg.yml" "" "signing config present"
	fi
	# Engram overlay: engram_usable() is the same predicate compose_files() uses.
	if engram_usable; then
		_dr_item "✓" "docker-compose.engram.yml" "" "engram on PATH"
	fi
	# OAuth token overlay: a non-empty first line (after whitespace stripping)
	# drives inclusion — matches the export_compose_env / compose_files
	# activation gate (head -1 | tr -d '[:space:]'). Both zero-byte AND
	# whitespace-only token files must NOT be reported as active here.
	if [ -n "$(head -1 "$DRYDOCK_OAUTH_TOKEN" 2>/dev/null | tr -d '[:space:]')" ]; then
		_dr_item "✓" "docker-compose.oauth.yml" "" "OAuth token present"
	fi
	# Optional user-config opt-in overlays (auto-detected from host directories).
	# Tilde-literals in the meta column are display text (not paths to expand);
	# disable SC2088 explicitly for the two affected calls.
	if [ -d "$HOME/.mcp-auth" ]; then
		# shellcheck disable=SC2088
		_dr_item "✓" "docker-compose.mcp-auth.yml" "" "~/.mcp-auth present"
	fi
	if [ -d "$HOME/.config/ccstatusline" ]; then
		# shellcheck disable=SC2088
		_dr_item "✓" "docker-compose.ccstatusline.yml" "" "~/.config/ccstatusline present"
	fi
	unset _DR_LABEL_WIDTH

	# ── ENV FLAGS ──────────────────────────────────────────────────────────────
	# Shows DRYDOCK_* env vars only when they BEHAVIORALLY differ from the default.
	# Inert values (e.g. DRYDOCK_SKIP_AUTOSYNC=0 — same as unset) are silent to
	# avoid noise. Each flag's "triggering value" matches the literal documented
	# in lib/compose.sh; values outside that set are surfaced as ⚠ "set but inert"
	# so a malformed value (typo, wrong case) is still visible to the operator.
	_dr_section "ENV FLAGS" "non-default"
	local _flag_count=0
	case "${DRYDOCK_NO_HARDENING:-}" in
	"") ;;
	"1")
		_dr_item "⚠" "DRYDOCK_NO_HARDENING" "=1" "INV-8 hardening overlay disabled"
		_flag_count=$((_flag_count + 1))
		;;
	*)
		_dr_item "⚠" "DRYDOCK_NO_HARDENING" "=$DRYDOCK_NO_HARDENING" 'set but inert — only literal "1" disables'
		_flag_count=$((_flag_count + 1))
		;;
	esac
	if [ -n "${DRYDOCK_TMPFS_SIZE:-}" ]; then
		_dr_item "✓" "DRYDOCK_TMPFS_SIZE" "=$DRYDOCK_TMPFS_SIZE" "tmpfs /tmp size override"
		_flag_count=$((_flag_count + 1))
	fi
	case "${DRYDOCK_ENGRAM_SHARED:-}" in
	"") ;;
	"force")
		_dr_item "⚠" "DRYDOCK_ENGRAM_SHARED" "=force" "INV-5 fcntl-lock safety override"
		_flag_count=$((_flag_count + 1))
		;;
	*)
		_dr_item "⚠" "DRYDOCK_ENGRAM_SHARED" "=$DRYDOCK_ENGRAM_SHARED" 'set but inert — only literal "force" overrides'
		_flag_count=$((_flag_count + 1))
		;;
	esac
	case "${DRYDOCK_SKIP_AUTOSYNC:-}" in
	"" | "0") ;;
	"1")
		_dr_item "⚠" "DRYDOCK_SKIP_AUTOSYNC" "=1" "host→container auto-sync disabled"
		_flag_count=$((_flag_count + 1))
		;;
	*)
		_dr_item "⚠" "DRYDOCK_SKIP_AUTOSYNC" "=$DRYDOCK_SKIP_AUTOSYNC" 'set but inert — only literal "1" disables'
		_flag_count=$((_flag_count + 1))
		;;
	esac
	if [ "$_flag_count" -eq 0 ]; then
		_dr_item "·" "(none — defaults active)" ""
	fi

	# ── RUNTIME CONTEXT ────────────────────────────────────────────────────────
	_dr_section "RUNTIME CONTEXT" "for compose"
	_dr_item "·" "USER_UID" "$(id -u)"
	_dr_item "·" "USER_GID" "$(id -g)"
	_dr_item "·" "HOST_DOCKER_GID" "$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo '?')"
	printf '\n'
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

# _check_path_metachar — reject a path string that would corrupt the
# pipe-delimited list file, break the Docker Compose volume spec, or break YAML.
# Args: <path> <label>   (label is used verbatim in the error message)
_check_path_metachar() {
	local _p="$1" _label="$2"
	if [[ "$_p" == *'|'* ]]; then
		err "rejected: $_label contains '|' which would corrupt the link list file"
	fi
	if [[ "$_p" == *':'* ]]; then
		err "rejected: $_label contains ':' which would break the Docker Compose volume spec"
	fi
	if [[ "$_p" == *'"'* ]]; then
		err "rejected: $_label contains '\"' which would break YAML formatting"
	fi
	if [[ "$_p" == *$'\\'* ]]; then
		err "rejected: $_label contains a backslash which would produce an invalid escape in the YAML volume string"
	fi
	if [[ "$_p" =~ [[:cntrl:]] ]]; then
		err "rejected: $_label contains a control character (including newline)"
	fi
}

# ── cmd_setup_token ───────────────────────────────────────────────────────────

# cmd_setup_token [--force]
# Runs `claude setup-token` interactively on the host (user sees the browser
# flow and the printed token), then prompts the user to paste the token.
# Validates it and writes it atomically to DRYDOCK_OAUTH_TOKEN (0600).
# Refuses to overwrite an existing token without --force.
cmd_setup_token() {
	local force=0

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--force)
			force=1
			shift
			;;
		-*)
			err "unknown option: $1"
			;;
		*)
			err "unexpected argument: $1"
			;;
		esac
	done

	# SR-1: fail early with install guidance if the claude binary is not on PATH.
	command -v "$CLAUDE_BIN" >/dev/null 2>&1 || err "claude (Claude Code CLI) not found — install Claude Code CLI before running 'drydock setup-token'"

	# Ensure the target directory exists before attempting mktemp inside it.
	# FIX 4: create with 0700 so a fresh directory is not world-readable.
	# mkdir -p is a no-op (and does not change mode) when the directory already
	# exists — acceptable; this only tightens fresh creation.
	(
		umask 077
		mkdir -p "$(dirname "$DRYDOCK_OAUTH_TOKEN")"
	) || err "failed to create token directory $(dirname "$DRYDOCK_OAUTH_TOKEN") — check permissions"

	# Overwrite guard: refuse without --force when file already exists (SR-5a).
	# Print the file's age in days so the user knows whether the token is stale.
	if [ -f "$DRYDOCK_OAUTH_TOKEN" ] && [ "$force" -eq 0 ]; then
		local _mtime _now _age_days
		_mtime="$(stat -c %Y "$DRYDOCK_OAUTH_TOKEN")"
		_now="$(date +%s)"
		_age_days=$(((_now - _mtime) / 86400))
		err "token file already exists at $DRYDOCK_OAUTH_TOKEN (${_age_days} day(s) old) — pass --force to overwrite"
	fi

	# Run claude setup-token fully unredirected: the user sees the authorization
	# URL, completes the browser flow, and sees the token printed by claude.
	# Capture only the exit code; do not capture stdout or stderr.
	local _rc=0
	"$CLAUDE_BIN" setup-token || _rc=$?
	if [ "$_rc" -ne 0 ]; then
		err "claude setup-token exited with status $_rc — token not saved"
	fi

	# Prompt the user to paste the token claude just printed above.
	# Explicit EOF guard: if stdin is closed (Ctrl-D / non-interactive invocation),
	# read returns non-zero. Catch it and emit a clear diagnostic rather than
	# falling silently into the regex check with an empty string.
	local _token
	IFS= read -s -r -p "Paste the token printed above: " _token ||
		err "no token pasted (EOF / Ctrl-D) — re-run 'drydock setup-token' and paste the token when prompted"
	printf '\n' >&2

	# Validate: token must match the sk-ant- prefix format.
	# [:graph:] matches printable non-whitespace characters (POSIX) — accepts
	# '.', '+', '/', '=' (base64/JWT-style tokens) while still rejecting any
	# embedded whitespace. [:print:] would include space and must NOT be used.
	if [[ ! "$_token" =~ ^sk-ant-[[:graph:]]{20,}$ ]]; then
		err "pasted value does not look like a valid Claude OAuth token (expected sk-ant- prefix) — retry 'drydock setup-token'"
	fi

	# Atomic 0600 write: umask is set before mktemp so the temp file is created
	# 0600 by intent. Inline cleanup on each failure path removes the temp file
	# before calling err — no shell-level EXIT trap is touched (see convention at
	# lib/commands.sh comment near cmd_unlink: EXIT trap persists process-wide and
	# fires after the function returns, which can confuse callers; inline cleanup
	# is the documented pattern for this file).
	local _tmp
	_tmp="$(
		umask 077
		mktemp "$(dirname "$DRYDOCK_OAUTH_TOKEN")/.oauth-XXXXXX"
	)" || err "failed to create a temporary file in $(dirname "$DRYDOCK_OAUTH_TOKEN") — check disk space and permissions"
	if ! printf '%s\n' "$_token" >"$_tmp"; then
		rm -f "$_tmp"
		err "failed to write token to temporary file"
	fi
	if ! mv -f "$_tmp" "$DRYDOCK_OAUTH_TOKEN"; then
		rm -f "$_tmp"
		err "failed to save token to $DRYDOCK_OAUTH_TOKEN — token not written"
	fi

	ok "OAuth token saved to $DRYDOCK_OAUTH_TOKEN"
	note "This token is valid for approximately 1 year. To refresh: drydock setup-token --force"
	note "To fully revoke: run 'drydock revoke-token', then visit claude.ai → Settings to revoke server-side"
}

# ── cmd_revoke_token ──────────────────────────────────────────────────────────

# cmd_revoke_token
# Removes the local OAuth token file (idempotent). Prints a mandatory notice
# that server-side revocation requires claude.ai → Settings (SR-7).
cmd_revoke_token() {
	if [ -f "$DRYDOCK_OAUTH_TOKEN" ]; then
		rm -f "$DRYDOCK_OAUTH_TOKEN"
		ok "Local OAuth token removed from $DRYDOCK_OAUTH_TOKEN"
	else
		note "No local token file to remove (already absent)"
	fi
	note "IMPORTANT: drydock cannot revoke the token server-side. To fully revoke, visit claude.ai → Settings and revoke the token there."
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

	[ -n "$src" ] || err "usage: drydock link <host-path> [container-target]"

	# D7: canonicalize BEFORE all guards
	local canonical
	canonical="$(realpath "$src" 2>/dev/null)" || err "path does not exist: $src"

	# R4-FIX-4: reject non-directory sources early with a clean error.
	# realpath succeeds for regular files too, so without this check a file
	# source makes it through all guards and produces a cryptic Docker engine
	# error at compose-up time.
	[ -d "$canonical" ] || err "rejected: '$canonical' is not a directory"

	# FIX #5: metacharacter validation — reject paths that would corrupt the
	# pipe-delimited list file, break the Docker Compose volume string, or
	# break YAML. Applied to canonical (already realpath-resolved) and to
	# target_arg (user-supplied, validated before use).
	_check_path_metachar "$canonical" "host path '$canonical'"
	[ -z "$target_arg" ] || _check_path_metachar "$target_arg" "container target '$target_arg'"

	# SP-6: host-source rejection guard
	# Reject $HOME itself, ancestors of $HOME, and sensitive subdirs.
	# Use [[ ]] for prefix matching; handle root "/" specially.
	#
	# R2-FIX-6: resolve $HOME itself via realpath once, so that a symlinked
	# $HOME (e.g. $HOME -> /actual/home) does not allow a path under the real
	# home to bypass prefix guards.  The resolved $canonical is already a
	# realpath, so all comparisons must be realpath-vs-realpath.
	local _real_home
	_real_home="$(realpath "$HOME" 2>/dev/null || printf '%s' "$HOME")"
	if [ "$canonical" = "$_real_home" ]; then
		err "rejected: '$canonical' is \$HOME"
	fi
	# Ancestor check: canonical is an ancestor of HOME when HOME starts with canonical/
	# Special-case root "/" which would produce a double-slash in pattern.
	if [ "$canonical" = "/" ] || [[ "$_real_home/" == "$canonical/"* ]]; then
		err "rejected: '$canonical' is an ancestor of \$HOME"
	fi
	# Sensitive subdir check: prefix comparison on realpath-resolved canonical
	# vs realpath-resolved $HOME. Covers drydock-managed dirs AND credential
	# dirs (INV-1 defense-in-depth: FIX #6 adds ~/.ssh, ~/.aws, ~/.gnupg,
	# ~/.kube, ~/.docker).
	# R4-FIX-2: For the five credential dirs (.ssh, .aws, .gnupg, .kube,
	# .docker) use separator-anchored patterns — match the exact dir OR anything
	# strictly under it. The old `"$_real_home/.ssh"*` glob matched ~/.ssh-backup,
	# ~/.dockerfiles, etc. as false positives.
	# .claude*, .engram*, .config/drydock* keep their wildcards — load-bearing for
	# per-session directories per INV-2 (e.g. .claude-container-<disc>).
	if [[ "$canonical/" == "$_real_home/.claude"* ]] ||
		[[ "$canonical/" == "$_real_home/.engram"* ]] ||
		[[ "$canonical/" == "$_real_home/.config/drydock"* ]] ||
		[ "$canonical" = "$_real_home/.ssh" ] || [[ "$canonical/" == "$_real_home/.ssh/"* ]] ||
		[ "$canonical" = "$_real_home/.aws" ] || [[ "$canonical/" == "$_real_home/.aws/"* ]] ||
		[ "$canonical" = "$_real_home/.gnupg" ] || [[ "$canonical/" == "$_real_home/.gnupg/"* ]] ||
		[ "$canonical" = "$_real_home/.kube" ] || [[ "$canonical/" == "$_real_home/.kube/"* ]] ||
		[ "$canonical" = "$_real_home/.docker" ] || [[ "$canonical/" == "$_real_home/.docker/"* ]]; then
		err "rejected: '$canonical' is under a protected path (credentials or drydock state)"
	fi

	# Reject the project's own directory.
	# R3-FIX-2: resolve_project_dir returns logical pwd (symlink path). If CWD
	# is a symlink, the logical path differs from canonical (realpath-resolved).
	# Normalize project_dir to its realpath so a symlinked CWD cannot bypass
	# this guard. Do NOT modify resolve_project_dir — it is used elsewhere with
	# pwd-style expectations; only this comparison needs realpath normalization.
	local project_dir
	project_dir="$(realpath "$(resolve_project_dir "")" 2>/dev/null || resolve_project_dir "")"
	if [ "$canonical" = "$project_dir" ]; then
		err "rejected: '$canonical' is the current project directory (already mounted at /workspace)"
	fi

	# Derive <name> = basename of canonical host path
	local name
	name="$(basename "$canonical")"

	# Compute container target (default or custom)
	local container_target
	if [ -n "$target_arg" ]; then
		# R3-FIX-3: strip trailing slash before ALL validation. Docker treats
		# /foo and /foo/ as the same mount target; storing them as different
		# strings causes the collision check to miss entries that mount to the
		# same effective path. A single root "/" is exempt — removing its slash
		# yields "" which is wrong; the root-reject check (b) fires first anyway.
		container_target="${target_arg%/}"
		[ -z "$container_target" ] && container_target="/"
		# SP-7: custom target rejection guard (FIX #2 — replaces incomplete denylist).
		# (a) Must be an absolute path.
		if [[ "$container_target" != /* ]]; then
			err "rejected: container target '$container_target' must be an absolute path"
		fi
		# (b) Reject root /.
		if [ "$container_target" = "/" ]; then
			err "rejected: container target '/' is the filesystem root"
		fi
		# R4-FIX-1: reject targets starting with // (double-slash).
		# On Linux the kernel normalizes //foo → /foo at mount time, which means
		# //etc/foo mounts at /etc/foo while bypassing every single-slash guard:
		# the first-component extractor strips one slash leaving /etc/foo, the
		# %%/* trim then yields empty-string so the denylist case falls through.
		if [[ "$container_target" == //* ]]; then
			err "rejected: container target '$container_target' starts with '//' which normalizes to a different path"
		fi
		# R3-FIX-4: reject any target containing a '..' path component. Docker
		# normalizes /workspace-siblings/../etc/foo to /etc/foo at mount time,
		# which would shadow a system directory while bypassing all guards.
		# Regex: any /.. followed by / or end-of-string → a .. path component.
		if [[ "$container_target" =~ /\.\.(/|$) ]]; then
			err "rejected: container target '$container_target' contains '..' which would normalize to a different path"
		fi
		# R3-FIX-5: reject any target containing a '.' path component (single dot).
		# /workspace-siblings/. normalizes to /workspace-siblings and bypasses
		# the exact-string guard (g) because the guard compares the literal string.
		# Regex: any /. followed by / or end-of-string → a single-dot component.
		# This is safe: /.hidden, /.claude etc. have a non-/ char after the dot.
		if [[ "$container_target" =~ /\.(/|$) ]]; then
			err "rejected: container target '$container_target' contains '.' component which would normalize to a different path"
		fi
		# (d) Explicitly reject the RO hooks mount path (INV-3): /opt/drydock/hooks.
		# Checked BEFORE the generic /opt system-dir reject so the error message
		# names INV-3 specifically. Bind-mounted :ro per docker-compose.yml line 84;
		# a shadowing sibling mount would silently bypass the read-only guardrail.
		if [[ "$container_target/" == "/opt/drydock/hooks/"* ]] || [ "$container_target" = "/opt/drydock/hooks" ]; then
			err "rejected: container target '$container_target' shadows the drydock hooks RO mount (INV-3)"
		fi
		# (c) Reject targets whose first path component is a system directory.
		# NOTE: 'home' is intentionally NOT in this list — /home/<user>/git/foo is
		# the host-path-mirror use case; ancestor-of-$HOME is handled by (f) below.
		local _first_comp
		_first_comp="${container_target#/}"
		_first_comp="${_first_comp%%/*}"
		case "$_first_comp" in
		etc | bin | sbin | usr | lib | lib32 | lib64 | boot | root | opt | proc | sys | dev | run | var | tmp)
			err "rejected: container target '$container_target' is under a system directory (/$_first_comp)"
			;;
		esac
		# (e) Reject paths that shadow /workspace or drydock-managed home dirs.
		# Append trailing / so "/workspace" and "/workspace/sub" both match.
		# R3-FIX-6: use $_real_home (realpath-resolved, computed earlier in
		# cmd_link) instead of raw $HOME so that a symlinked $HOME cannot bypass
		# these guards. Consistent with the host-source guard above which also
		# uses $_real_home via realpath-resolved canonical.
		case "$container_target/" in
		"/workspace/"*)
			err "rejected: container target '$container_target' shadows /workspace"
			;;
		"$_real_home/.claude"*)
			err "rejected: container target '$container_target' shadows container state"
			;;
		"$_real_home/.engram"*)
			err "rejected: container target '$container_target' shadows container state"
			;;
		"$_real_home/.config/drydock"*)
			err "rejected: container target '$container_target' shadows drydock config"
			;;
		esac
		# (f) Reject $HOME itself and ancestors of $HOME as custom target.
		# A mount over $HOME or /home shadows the entire home directory.
		# NOTE: targets under $HOME (e.g. /home/<user>/git/foo) are NOT rejected —
		# that is the host-path-mirror use case.
		# R3-FIX-6: use $_real_home for consistency with (e) and with the
		# host-source guards above.
		if [ "$container_target" = "$_real_home" ] || [[ "$_real_home/" == "$container_target/"* ]]; then
			err "rejected: container target '$container_target' shadows \$HOME or an ancestor of \$HOME"
		fi
		# (g) Reject /workspace-siblings bare parent — a mount over it would shadow
		# all default-target siblings. A target under it (e.g. /workspace-siblings/foo)
		# is acceptable (functionally equivalent to a default target).
		# R4-FIX-3: the second clause `= "/workspace-siblings/"` is unreachable —
		# R3-FIX-3 strips the trailing slash at the top of the custom-target branch.
		if [ "$container_target" = "/workspace-siblings" ]; then
			err "rejected: container target '$container_target' shadows the /workspace-siblings parent directory"
		fi
	else
		# R3-FIX-3: no trailing slash — consistent with normalized custom targets.
		container_target="/workspace-siblings/$name"
	fi

	# ADR-5: basename collision check + container-target uniqueness check
	local list_file
	list_file="$(_links_list_file)"
	# JD1-AB: track whether this exact host+target+flags combo was already linked.
	# Set to 1 inside the loop instead of returning 0 so the RW self-heal path
	# can still run (idempotent helpers re-apply any missing mutations).
	local _already_linked=0
	# New entry's flag for mode-mismatch comparison.
	local _new_flag=""
	[ "$rw" -eq 1 ] && _new_flag="rw"
	if [ -f "$list_file" ]; then
		local existing_host existing_target existing_flags existing_name existing_target_norm
		while IFS='|' read -r existing_host existing_target existing_flags; do
			[ -z "$existing_host" ] && continue
			existing_name="$(basename "$existing_host")"
			if [ "$existing_name" = "$name" ] && [ "$existing_host" != "$canonical" ]; then
				err "basename collision: '$name' is already used by '$existing_host'; cannot also link '$canonical'"
			fi
			# Idempotent: same host path already present.
			# R4-FIX-5: also compare the normalized existing target against the
			# new container_target. If they differ the user is trying to change
			# the mount point — that requires unlink first.
			if [ "$existing_host" = "$canonical" ]; then
				local _existing_norm="${existing_target%/}"
				if [ "$_existing_norm" = "$container_target" ]; then
					# JD1-AB: compare flags — mode mismatch → actionable error.
					local _existing_flag="${existing_flags:-}"
					if [ "$_existing_flag" != "$_new_flag" ]; then
						err "already linked as '${_existing_flag:-ro}'; run 'drydock unlink $canonical' first to re-link as '${_new_flag:-ro}'"
					fi
					# Same mode: mark for self-heal / idempotent no-op; continue scanning.
					_already_linked=1
					continue
				fi
				err "already linked with a different container target '$_existing_norm' — run 'drydock unlink $canonical' first"
			fi
			# FIX #3: container target uniqueness — two entries sharing the same
			# container target would cause Docker Compose to silently keep only one.
			# R3-FIX-3: normalize existing_target by stripping trailing slash so
			# that old entries written with a slash still collide correctly.
			existing_target_norm="${existing_target%/}"
			if [ -n "$existing_target_norm" ] && [ "$existing_target_norm" = "$container_target" ]; then
				err "container target collision: '$container_target' is already used by '$existing_host'"
			fi
		done <"$list_file"
	fi

	# Append entry and perform post-link actions.
	mkdir -p "$(dirname "$list_file")"

	if [ "$rw" -eq 1 ]; then
		# RW branch: key-gen + SSH config + URL rewrite (SR-1, SR-2, SR-3, SR-4).
		# JD1-AB: when _already_linked=1 the .list entry already exists — skip
		# appending to avoid duplication. All helpers are idempotent so they still
		# run to self-heal any partial state (step 4/5 failures on prior run).
		local _sanitized
		_sanitized="$(sanitize_project_name "$name")"
		local _project_name
		_project_name="$(sanitize_project_name "$(basename "$(pwd)")")"

		# Layer-2: key-file ownership collision check (defense-in-depth).
		# Layer-1 basename collision already handled by the loop above.
		# Run before appending to .list so .list stays clean on error.
		_check_sibling_basename_collision_rw "$canonical" "$_sanitized" "$list_file"

		if [ -d "${canonical}/.git" ]; then
			# FIX-1: validate URL FIRST (read-only); then perform mutations so a
			# mid-flow failure cannot leave the sibling's .git/config pointing at
			# an alias whose key file + SSH config Host block do not yet exist.
			# Order: validate → key-gen → .list append → SSH config regen →
			# URL rewrite. URL mutation is the LAST step; if anything earlier
			# fails, the sibling .git/config is untouched.
			_validate_sibling_remote_url "$canonical" "$_sanitized"

			# Key-gen (idempotent — reuses existing key)
			local _key_path
			_key_path="$(_generate_sibling_deploy_key "$_sanitized")"

			# Append .list entry only when not already present — must happen
			# BEFORE SSH config regen so _regenerate_managed_ssh_config emits
			# the alias block for it.
			if [ "$_already_linked" -eq 0 ]; then
				printf '%s|%s|rw\n' "$canonical" "$container_target" >>"$list_file"
			fi

			# Regenerate managed SSH config (alias block now part of the list)
			_regenerate_managed_ssh_config "$_project_name" "$list_file" >/dev/null

			# URL rewrite — final mutation. _validate_sibling_remote_url already
			# accepted the current URL, so _rewrite re-runs the same validation
			# idempotently and then performs the single `git remote set-url`.
			_rewrite_sibling_remote_url "$canonical" "$_sanitized"

			# Print pubkey + GitHub instructions
			local _pubkey
			_pubkey="$(cat "${_key_path}.pub")"
			ok "linked: $canonical → $container_target (rw)"
			printf '\nDeploy key for %s:\n\n%s\n\n' "$canonical" "$_pubkey" >&2
			printf 'Add this key to GitHub:\n' >&2
			printf '  gh repo deploy-key add %s.pub --repo <owner>/%s --title "drydock-%s" --allow-write\n' \
				"$_key_path" "$name" "$_sanitized" >&2
			printf '\nOr visit: https://github.com/<owner>/%s/settings/keys/new\n' "$name" >&2
		else
			# No .git/ — mount RW but skip SSH sub-flow (SR-2 / D10)
			if [ "$_already_linked" -eq 0 ]; then
				printf '%s|%s|rw\n' "$canonical" "$container_target" >>"$list_file"
			fi
			_regenerate_managed_ssh_config "$_project_name" "$list_file" >/dev/null
			ok "linked: $canonical → $container_target (rw)"
			note "no .git/ found in $canonical — deploy-key and SSH config alias skipped; re-run 'drydock link --rw $src' after git init to enable git push"
		fi
	else
		# RO branch: no helpers to re-run, so _already_linked → immediate no-op.
		if [ "$_already_linked" -eq 1 ]; then
			note "already linked: $canonical"
			return 0
		fi
		printf '%s|%s|\n' "$canonical" "$container_target" >>"$list_file"
		ok "linked: $canonical → $container_target (ro)"
	fi
}

# ── cmd_unlink ────────────────────────────────────────────────────────────────

# cmd_unlink [--rw] <host-path>
# Removes the matching entry from the project list file.
# --rw is accepted and ignored; the .list entry's flags field is authoritative
# for determining cleanup behavior (SR-6).
# Exits non-zero when the path is not found in the list.
cmd_unlink() {
	# Parse --rw flag (accepted and ignored per SR-6)
	case "${1:-}" in
	--rw) shift ;;
	esac

	local src="${1:-}"
	[ -n "$src" ] || err "usage: drydock unlink <host-path>"

	# Canonicalize input for consistent comparison
	local canonical
	canonical="$(realpath "$src" 2>/dev/null || printf '%s' "$src")"

	local list_file
	list_file="$(_links_list_file)"

	# R3-FIX-7(b): opportunistically remove any stale .tmp* files left by a
	# previous cmd_unlink that was SIGKILL'd or hit set -e before cleanup.
	# 2>/dev/null || true: silently no-op when no stale files exist.
	# Glob '.tmp*' (rather than '.tmp[0-9]*') matches both the current PID-suffix
	# pattern (.tmp$$) and any future temp-naming variant (mktemp-style, etc.).
	rm -f "${list_file}".tmp* 2>/dev/null || true

	# Existence check anchored to first field: $1 == canonical (awk -F'|').
	# grep -F "${canonical}|" would match the literal string anywhere on the
	# line, including inside the target column — silent deletion of the wrong
	# entry. awk field-equality is exact.
	if [ ! -f "$list_file" ] || ! awk -F'|' -v c="$canonical" '$1==c{f=1} END{exit !f}' "$list_file"; then
		err "not linked: $canonical"
	fi

	# Read the entry's flags BEFORE removing it — needed for RW cleanup.
	local _removed_flags
	_removed_flags="$(awk -F'|' -v c="$canonical" '$1==c{print $3}' "$list_file")"

	# Remove lines whose first field equals canonical (anchored to host column).
	# awk exits 0 even when no output lines remain — set -e safe.
	# R3-FIX-1: RETURN trap does NOT fire when set -e triggers a function exit
	# (verified empirically). Use explicit error-path cleanup instead: if mv
	# fails, rm the .tmp and call err. No shell-level EXIT trap is touched.
	local tmp_file
	tmp_file="${list_file}.tmp$$"
	# R4-FIX-6: wrap awk in an explicit error path. set -euo pipefail aborts on
	# awk failure (rare under resource pressure) leaving tmp_file on disk.
	# Mirror the mv-failure pattern: rm the tmp and call err.
	if ! awk -F'|' -v c="$canonical" '$1!=c' "$list_file" >"$tmp_file"; then
		rm -f "$tmp_file"
		err "awk failed while rewriting link list"
	fi
	if ! mv "$tmp_file" "$list_file"; then
		rm -f "$tmp_file"
		err "failed to rewrite link list after unlink"
	fi

	ok "unlinked: $canonical"

	# RW cleanup: regenerate SSH config (removing alias block) + restore URL.
	if [ "${_removed_flags:-}" = "rw" ]; then
		local _project_name
		_project_name="$(sanitize_project_name "$(basename "$(pwd)")")"
		local _sanitized
		_sanitized="$(sanitize_project_name "$(basename "$canonical")")"
		local _key_path
		_key_path="$(_sibling_deploy_key_path "$_sanitized")"

		# Regenerate managed SSH config without the removed sibling's alias block.
		_regenerate_managed_ssh_config "$_project_name" "$list_file" >/dev/null

		# Restore sibling's git remote URL to canonical form (D6).
		_restore_canonical_remote_url "$canonical" "$_sanitized"

		# Dual-sided hint (D6, SR-5): local key path + GitHub-side revocation.
		printf '\nKey files left on disk (not deleted — remove manually when done):\n' >&2
		printf '  %s\n' "$_key_path" >&2
		printf '  %s.pub\n' "$_key_path" >&2
		printf 'To delete them: rm -f %s %s.pub\n\n' "$_key_path" "$_key_path" >&2
		printf 'GitHub deploy key revocation (drydock cannot do this automatically):\n' >&2
		printf '  Visit: https://github.com/<owner>/%s/settings/keys\n' "$(basename "$canonical")" >&2
		printf '  Or run: gh repo deploy-key list --repo <owner>/%s\n' "$(basename "$canonical")" >&2
		printf '  Then:   gh repo deploy-key delete <id> --repo <owner>/%s\n' "$(basename "$canonical")" >&2
	fi
}

# ── cmd_links ─────────────────────────────────────────────────────────────────

# cmd_links
# Prints all sibling entries for the current project, one per line.
# Empty list: silent exit 0.
cmd_links() {
	local list_file
	list_file="$(_links_list_file)"

	[ -f "$list_file" ] || return 0

	local host target _flags _mode
	while IFS='|' read -r host target _flags; do
		[ -z "$host" ] && continue
		# Display mount mode per entry (SR-7, OQ-rw-3 inline suffix).
		if [ "${_flags:-}" = "rw" ]; then
			_mode="rw"
		else
			_mode="ro"
		fi
		printf '%s -> %s (%s)\n' "$host" "$target" "$_mode"
	done <"$list_file"
}
