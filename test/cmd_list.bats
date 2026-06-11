#!/usr/bin/env bats
# test/cmd_list.bats — unit tests for cmd_list in lib/commands.sh
#
# REQ-N6, SR-NEW-1: drydock list filters by project prefix and outputs parseable
# format: NAME / STATUS / AGE columns. Exited sessions show [Exited] marker.

load "helpers/load"

setup() {
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/commands.sh"

	ensure_prereqs() { :; }
	ensure_image() { :; }

	# Default PROJECT_NAME.
	export PROJECT_NAME="myproj"

	local tmpdir="$BATS_TEST_TMPDIR/myproj"
	mkdir -p "$tmpdir"
	cd "$tmpdir"
}

# ── Helper: build docker stub returning given ps output ──────────────────────

make_docker_ps_stub() {
	local stub_dir="$BATS_TEST_TMPDIR/docker-stub-list-$$-$RANDOM"
	mkdir -p "$stub_dir"
	local ps_output="$1"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "ps" ]; then
	printf '%s\n' "${ps_output}"
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	printf '%s' "$stub_dir/docker"
}

# ── REQ-N6: parseable output with name, status, age ─────────────────────────

@test "cmd_list: outputs the container name for a live session (REQ-N6)" {
	local stub
	stub="$(make_docker_ps_stub "drydock-myproj-ab12|Up 5 minutes|2026-05-25 10:00:00")"
	export DOCKER="$stub"

	run cmd_list
	[ "$status" -eq 0 ]
	[[ "$output" == *"drydock-myproj-ab12"* ]]
}

@test "cmd_list: outputs status for a live session (REQ-N6)" {
	local stub
	stub="$(make_docker_ps_stub "drydock-myproj-ab12|Up 5 minutes|2026-05-25 10:00:00")"
	export DOCKER="$stub"

	run cmd_list
	[ "$status" -eq 0 ]
	[[ "$output" == *"Up"* ]] || [[ "$output" == *"5 minutes"* ]]
}

@test "cmd_list: exits 0 with no sessions (REQ-N6 — empty list is valid)" {
	local stub
	stub="$(make_docker_ps_stub "")"
	export DOCKER="$stub"

	run cmd_list
	[ "$status" -eq 0 ]
}

@test "cmd_list: lists multiple sessions (REQ-N6 — parseable multi-row)" {
	local stub
	stub="$(make_docker_ps_stub "drydock-myproj-ab12|Up 5 minutes|2026-05-25 10:00:00
drydock-myproj-ef56|Up 2 minutes|2026-05-25 10:03:00")"
	export DOCKER="$stub"

	run cmd_list
	[ "$status" -eq 0 ]
	[[ "$output" == *"drydock-myproj-ab12"* ]]
	[[ "$output" == *"drydock-myproj-ef56"* ]]
}

# ── [Exited] marker (OQ-T5) ──────────────────────────────────────────────────

@test "cmd_list: shows [Exited] marker for an exited session (OQ-T5)" {
	# An exited container should be displayed with a distinct marker.
	local stub
	stub="$(make_docker_ps_stub "drydock-myproj-ab12|Exited (0) 2 minutes ago|2026-05-25 09:58:00")"
	export DOCKER="$stub"

	run cmd_list
	[ "$status" -eq 0 ]
	[[ "$output" == *"[Exited]"* ]]
}

# ── SR-NEW-1: per-project filter only ────────────────────────────────────────

@test "cmd_list: passes project-name filter to docker ps (SR-NEW-1)" {
	# The docker ps call must include a filter scoped to the current project.
	local stub_dir="$BATS_TEST_TMPDIR/docker-stub-filter-$$"
	mkdir -p "$stub_dir"
	local call_log="$BATS_TEST_TMPDIR/docker-list-filter.log"
	touch "$call_log"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
exit 0
STUB
	chmod +x "$stub_dir/docker"
	export DOCKER="$stub_dir/docker"

	run cmd_list
	# The docker ps invocation must include the project name in the filter.
	grep -q "myproj" "$call_log"
}

@test "cmd_list: passes --all to docker ps so exited containers are included (OQ-T5)" {
	# Without --all, docker ps only shows running containers; exited sessions are invisible.
	local stub_dir="$BATS_TEST_TMPDIR/docker-stub-all-$$"
	mkdir -p "$stub_dir"
	local call_log="$BATS_TEST_TMPDIR/docker-list-all.log"
	touch "$call_log"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
exit 0
STUB
	chmod +x "$stub_dir/docker"
	export DOCKER="$stub_dir/docker"

	run cmd_list
	# The docker ps invocation must include --all.
	grep -q -- "--all" "$call_log"
}

# ── Audit batch 2: inherited PROJECT_NAME poisoning + cross-project leak ──────
# PROJECT_NAME is a common CI/tooling export. At the cmd_list entry point
# drydock has not set it (export_compose_env never ran), so any pre-existing
# value comes from the caller's environment and flows UNSANITIZED into the
# docker --filter and grep regexes — PROJECT_NAME='.*' listed every project's
# sessions. Entry points must derive the project from the cwd unconditionally.

@test "cmd_list: inherited PROJECT_NAME='.*' does not widen the listing (audit batch 2)" {
	export PROJECT_NAME='.*'
	local stub
	stub="$(make_docker_ps_stub "drydock-myproj-ab12|Up 5 minutes|2026-06-10 10:00:00
drydock-otherproj-cd34|Up 2 minutes|2026-06-10 10:03:00")"
	export DOCKER="$stub"

	run cmd_list
	[ "$status" -eq 0 ]
	# cwd is .../myproj — only that project's sessions may appear.
	[[ "$output" == *"drydock-myproj-ab12"* ]]
	[[ "$output" != *"drydock-otherproj-cd34"* ]]
}

@test "cmd_list: same-prefix sibling project rows are excluded, -shell rows kept (audit batch 2)" {
	# Project 'api' must not list project 'api-docs' sessions: the bare
	# ^drydock-api- prefix filter matched both. The disc-anchored post-filter
	# keeps run sessions AND their -shell companions (intended in list).
	local tmpdir="$BATS_TEST_TMPDIR/api"
	mkdir -p "$tmpdir"
	cd "$tmpdir"
	export PROJECT_NAME="api"
	local stub
	stub="$(make_docker_ps_stub "drydock-api-ab12|Up 5 minutes|2026-06-10 10:00:00
drydock-api-ab12-shell|Up 5 minutes|2026-06-10 10:00:01
drydock-api-docs-cd34|Up 2 minutes|2026-06-10 10:03:00")"
	export DOCKER="$stub"

	run cmd_list
	[ "$status" -eq 0 ]
	[[ "$output" == *"drydock-api-ab12"* ]]
	[[ "$output" == *"drydock-api-ab12-shell"* ]]
	[[ "$output" != *"drydock-api-docs-cd34"* ]]
}
