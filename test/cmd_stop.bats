#!/usr/bin/env bats
# test/cmd_stop.bats — unit tests for cmd_stop in lib/commands.sh
#
# REQ-N7, REQ-7-M: drydock stop [name] executes docker rm -f <container>.
# Disambiguation follows the same 4 sub-scenarios as cmd_attach:
# (a) explicit name → direct stop; (b) no arg + 1 session → direct stop;
# (c) no arg + N>1 + TTY → menu; (d) no arg + N>1 + no-TTY → list + exit 2.

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

	# DOCKER seam.
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	# Default PROJECT_NAME.
	export PROJECT_NAME="myproj"

	local tmpdir="$BATS_TEST_TMPDIR/myproj"
	mkdir -p "$tmpdir"
	cd "$tmpdir"
}

# ── Helper: build a docker stub returning N sessions ─────────────────────────

make_docker_stub_with_sessions() {
	local stub_dir="$BATS_TEST_TMPDIR/docker-stub-stop-$$-$RANDOM"
	mkdir -p "$stub_dir"
	local sessions_output="$1"
	local call_log="${DOCKER_CALL_LOG}"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
if [ "\${1:-}" = "ps" ]; then
	printf '%s\n' "${sessions_output}"
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	printf '%s' "$stub_dir/docker"
}

# make_docker_stub_split: distinguish running vs all (running + exited).
# $1 = output for plain "docker ps" (running sessions)
# $2 = output for "docker ps --all" (running + exited sessions)
make_docker_stub_split() {
	local stub_dir="$BATS_TEST_TMPDIR/docker-stub-split-$$-$RANDOM"
	mkdir -p "$stub_dir"
	local running_output="$1"
	local all_output="$2"
	local call_log="${DOCKER_CALL_LOG}"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
if [ "\${1:-}" = "ps" ]; then
	if printf '%s' "\$*" | grep -q -- "--all"; then
		printf '%s\n' "${all_output}"
	else
		printf '%s\n' "${running_output}"
	fi
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	printf '%s' "$stub_dir/docker"
}

# ── Scenario (a): explicit disc/name → direct docker rm -f ───────────────────

@test "cmd_stop: explicit disc arg → invokes docker rm -f on the container (REQ-N7)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop "ab12"
	[ "$status" -eq 0 ]
	grep -q "rm" "$DOCKER_CALL_LOG"
}

@test "cmd_stop: explicit disc arg → rm -f uses the full container name (REQ-N7)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop "ab12"
	[ "$status" -eq 0 ]
	grep -q "drydock-myproj-ab12" "$DOCKER_CALL_LOG"
}

@test "cmd_stop: explicit full container name also works (REQ-N7 — _resolve_session_name)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop "drydock-myproj-ab12"
	[ "$status" -eq 0 ]
	grep -q "drydock-myproj-ab12" "$DOCKER_CALL_LOG"
}

@test "cmd_stop: Phase 2 — also rm -f's the -egress sidecar (two-name teardown)" {
	# The per-session egress sidecar must be torn down alongside the agent. The
	# sidecar rm is guarded (2>/dev/null || true) so a stop in dood mode (no sidecar)
	# does NOT fail; here we assert the -egress rm is issued for a contained session.
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop "ab12"
	[ "$status" -eq 0 ]
	grep -q "rm -f drydock-myproj-ab12-egress" "$DOCKER_CALL_LOG"
}

# ── Scenario (b): no arg + exactly 1 live session → direct stop ──────────────

@test "cmd_stop: no arg + 1 live session → stops it directly without menu (REQ-7-M sub-scenario b)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop
	[ "$status" -eq 0 ]
	grep -q "rm" "$DOCKER_CALL_LOG"
	grep -q "drydock-myproj-ab12" "$DOCKER_CALL_LOG"
	# No menu shown
	[[ "$output" != *"[1]"* ]]
}

# ── Scenario (d): no arg + N>1 + no-TTY → list + exit 2 ─────────────────────

@test "cmd_stop: no arg + N>1 sessions + no-TTY → exit 2 (REQ-7-M sub-scenario d)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12
drydock-myproj-ef56")"
	export DOCKER="$stub"

	run cmd_stop
	[ "$status" -eq 2 ]
}

@test "cmd_stop: no arg + N>1 sessions + no-TTY → does NOT invoke rm -f (REQ-7-M sub-scenario d)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12
drydock-myproj-ef56")"
	export DOCKER="$stub"

	run cmd_stop
	# Must exit 2 and NOT have removed a container
	[ "$status" -eq 2 ]
	# rm should NOT appear in call log for no-TTY multi-session
	! grep -q "^rm " "$DOCKER_CALL_LOG"
}

# ── No sessions → error + exit non-zero ──────────────────────────────────────

@test "cmd_stop: no arg + 0 live sessions → exits non-zero (nothing to stop)" {
	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"

	run cmd_stop
	[ "$status" -ne 0 ]
}

# ── Scenario (a): validation — cross-project / nonexistent name → error ──────

@test "cmd_stop: explicit cross-project container name → exits non-zero (FIX-3)" {
	# drydock-otherproject-abc1 does not belong to myproj; must be rejected.
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop "drydock-otherproject-abc1"
	[ "$status" -ne 0 ]
}

@test "cmd_stop: explicit cross-project container name → friendly error message (FIX-3, #102)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop "drydock-otherproject-abc1" 2>&1
	# #102: post-FIX-4 cmd_stop validates via _all_sessions (includes Exited containers).
	# The error must reflect that scope — "no live" misled users who expected the
	# message to mean "no running" and silently masked Exited containers.
	[[ "$output" == *"no session (running or exited)"* ]]
}

@test "cmd_stop: explicit nonexistent disc → exits non-zero (FIX-3)" {
	# No session with disc deadbeef.
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop "deadbeef"
	[ "$status" -ne 0 ]
}

@test "cmd_stop: explicit nonexistent disc → does NOT invoke docker rm -f (FIX-3)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop "deadbeef"
	[ "$status" -ne 0 ]
	# rm must NOT have been called since the target is not a live session.
	! grep -q "^rm " "$DOCKER_CALL_LOG"
}

# ── Stop is docker rm -f, not docker stop ────────────────────────────────────

@test "cmd_stop: uses 'rm' (docker rm -f), not 'stop' docker subcommand (REQ-N7)" {
	# The spec says docker rm -f, not docker stop.
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop "ab12"
	[ "$status" -eq 0 ]
	# Must have 'rm' in the log
	grep -q "rm" "$DOCKER_CALL_LOG"
	# Must NOT use 'docker stop'
	! grep -qE "^stop " "$DOCKER_CALL_LOG"
}

# ── FIX-4: explicit name targets Exited containers too ───────────────────────

@test "cmd_stop: explicit disc of Exited container → succeeds (FIX-4)" {
	# drydock list shows [Exited] sessions; users must be able to stop them by name.
	# Split stub: ps (running) returns nothing; ps --all returns the Exited container.
	local stub
	stub="$(make_docker_stub_split "" "drydock-myproj-dead")"
	export DOCKER="$stub"

	run cmd_stop "dead"
	[ "$status" -eq 0 ]
	grep -q "drydock-myproj-dead" "$DOCKER_CALL_LOG"
}

@test "cmd_stop: explicit disc of Exited container → invokes docker rm -f (FIX-4)" {
	local stub
	stub="$(make_docker_stub_split "" "drydock-myproj-dead")"
	export DOCKER="$stub"

	run cmd_stop "dead"
	[ "$status" -eq 0 ]
	grep -q "rm" "$DOCKER_CALL_LOG"
}

@test "cmd_stop: explicit disc not in running or exited → still rejected (FIX-4)" {
	# Existing rejection behaviour must hold: a name absent from ALL containers is an error.
	local stub
	stub="$(make_docker_stub_split "drydock-myproj-ab12" "drydock-myproj-ab12")"
	export DOCKER="$stub"

	run cmd_stop "deadbeef"
	[ "$status" -ne 0 ]
}

# ── Audit batch 2: inherited PROJECT_NAME poisoning ───────────────────────────
# At the cmd_stop entry point drydock has not set PROJECT_NAME, so any
# pre-existing value is the caller's environment export and flowed unsanitized
# into the session regexes: PROJECT_NAME='.*' made `drydock stop` target every
# project's sessions. Entry points and the session helpers must derive the
# project from the cwd unconditionally.

@test "cmd_stop: inherited PROJECT_NAME='.*' cannot target other projects' sessions (audit batch 2)" {
	export PROJECT_NAME='.*'
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12
drydock-otherproj-cd34")"
	export DOCKER="$stub"

	run cmd_stop
	# cwd is .../myproj — exactly ONE session for the real project: direct stop.
	[ "$status" -eq 0 ]
	grep -q "rm -f drydock-myproj-ab12" "$DOCKER_CALL_LOG"
	# The foreign project's session is never targeted.
	run grep "rm -f drydock-otherproj-cd34" "$DOCKER_CALL_LOG"
	[ "$status" -ne 0 ]
}

@test "_live_sessions: ignores inherited PROJECT_NAME, derives from cwd (audit batch 2)" {
	export PROJECT_NAME='.*'
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12
drydock-otherproj-cd34")"
	export DOCKER="$stub"

	run _live_sessions
	[ "$status" -eq 0 ]
	[[ "$output" == *"drydock-myproj-ab12"* ]]
	[[ "$output" != *"drydock-otherproj-cd34"* ]]
}
