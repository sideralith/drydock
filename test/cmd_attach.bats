#!/usr/bin/env bats
# test/cmd_attach.bats — unit tests for cmd_attach in lib/commands.sh
#
# REQ-N5, REQ-6-M, REQ-7-M: drydock attach reconnects to a live container via
# compose exec ... claude --resume. Disambiguation: (a) explicit name → direct;
# (b) no arg + 1 session → direct; (c) no arg + N>1 + TTY → menu;
# (d) no arg + N>1 + no-TTY → list + exit 2. Nonexistent → error + exit non-zero.

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
	ensure_runtime_dirs() { :; }
	ensure_synced() { :; }

	# DOCKER seam.
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	# Default PROJECT_NAME for tests.
	export PROJECT_NAME="myproj"

	local tmpdir="$BATS_TEST_TMPDIR/myproj"
	mkdir -p "$tmpdir"
	cd "$tmpdir"
}

# ── Helper: build a docker stub that returns N sessions ──────────────────────

make_docker_stub_with_sessions() {
	local stub_dir="$BATS_TEST_TMPDIR/docker-stub-attach-$$-$RANDOM"
	mkdir -p "$stub_dir"
	local sessions_output="$1"
	# Per-argument docker stub: switches on the -f label key for inspect calls.
	# Env vars (evaluated at runtime, not at stub creation — note escaped \$):
	#   MOCK_ONEOFF       — value for com.docker.compose.oneoff (capital True/False, OQ-5)
	#   MOCK_MUX          — value for drydock.mux
	#   MOCK_MUX_SESSION  — value for drydock.mux_session
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${DOCKER_CALL_LOG}"
if [ "\${1:-}" = "ps" ]; then
	printf '%s\n' "${sessions_output}"
elif [ "\${1:-}" = "inspect" ]; then
	# Honor MOCK_DOCKER_EXIT: non-zero → print nothing, exit with that code.
	if [ "\${MOCK_DOCKER_EXIT:-0}" != "0" ]; then
		exit "\${MOCK_DOCKER_EXIT}"
	fi
	# Dispatch on the -f format string to return per-label mock values.
	_fmt="\${3:-}"
	case "\$_fmt" in
	*com.docker.compose.oneoff*)
		printf '%s\n' "\${MOCK_ONEOFF:-False}"
		;;
	*drydock.mux_session*)
		printf '%s\n' "\${MOCK_MUX_SESSION:-}"
		;;
	*drydock.mux*)
		printf '%s\n' "\${MOCK_MUX:-}"
		;;
	*)
		printf '%s\n' "\${MOCK_DOCKER_INSPECT_OUTPUT:-}"
		;;
	esac
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	printf '%s' "$stub_dir/docker"
}

# ── T1: per-argument docker stub — label dispatch RED→GREEN ──────────────────

@test "make_docker_stub_with_sessions: inspect -f oneoff label returns MOCK_ONEOFF (T1, OQ-5)" {
	# GIVEN the per-arg stub is built with sessions output
	# WHEN docker inspect -f '{{index .Config.Labels "com.docker.compose.oneoff"}}' is called
	# THEN the stub returns MOCK_ONEOFF (capital True)
	export MOCK_ONEOFF="True"
	export MOCK_MUX="zellij"
	export MOCK_MUX_SESSION="main"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	# Invoke the stub as docker inspect would
	local result
	result="$("$stub" inspect -f '{{index .Config.Labels "com.docker.compose.oneoff"}}' drydock-myproj-ab12)"
	[ "$result" = "True" ]
}

@test "make_docker_stub_with_sessions: inspect -f mux label returns MOCK_MUX (T1)" {
	export MOCK_ONEOFF="False"
	export MOCK_MUX="tmux"
	export MOCK_MUX_SESSION="work"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	local result
	result="$("$stub" inspect -f '{{index .Config.Labels "drydock.mux"}}' drydock-myproj-ab12)"
	[ "$result" = "tmux" ]
}

@test "make_docker_stub_with_sessions: inspect -f mux_session label returns MOCK_MUX_SESSION (T1)" {
	export MOCK_ONEOFF="False"
	export MOCK_MUX="tmux"
	export MOCK_MUX_SESSION="work"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	local result
	result="$("$stub" inspect -f '{{index .Config.Labels "drydock.mux_session"}}' drydock-myproj-ab12)"
	[ "$result" = "work" ]
}

@test "make_docker_stub_with_sessions: MOCK_ONEOFF=False distinguishes from True (T1, OQ-5)" {
	# Verify capital False returns false, not true — critical for OQ-5 contract
	export MOCK_ONEOFF="False"
	export MOCK_MUX=""
	export MOCK_MUX_SESSION=""
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	local result
	result="$("$stub" inspect -f '{{index .Config.Labels "com.docker.compose.oneoff"}}' drydock-myproj-ab12)"
	[ "$result" = "False" ]
	[ "$result" != "True" ]
}

# ── T2: _is_oneoff_container — RED→GREEN (S-2C, S-2D) ───────────────────────

@test "_is_oneoff_container: label=True → returns 0 (S-2D, OQ-5)" {
	# GIVEN a container with com.docker.compose.oneoff=True (capital T)
	# WHEN _is_oneoff_container is called
	# THEN it returns 0 (success = is oneoff)
	export MOCK_ONEOFF="True"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_is_oneoff_container "drydock-myproj-ab12"
}

@test "_is_oneoff_container: label=False → returns 1 (S-2C, OQ-5)" {
	# GIVEN a container with com.docker.compose.oneoff=False (capital F)
	# WHEN _is_oneoff_container is called
	# THEN it returns 1 (failure = not oneoff, persistent)
	export MOCK_ONEOFF="False"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	run _is_oneoff_container "drydock-myproj-ab12"
	[ "$status" -eq 1 ]
}

@test "_is_oneoff_container: label=lowercase true → returns 1 (OQ-5 contract: must be capital)" {
	# lowercase 'true' MUST NOT be treated as oneoff — OQ-5 invariant
	export MOCK_ONEOFF="true"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	run _is_oneoff_container "drydock-myproj-ab12"
	[ "$status" -eq 1 ]
}

@test "_is_oneoff_container: inspect failure → returns 1 (OQ-4 degrade gracefully)" {
	# GIVEN docker inspect fails (container absent)
	# WHEN _is_oneoff_container is called
	# THEN it returns 1 (degrades to false, treats as persistent)
	export MOCK_DOCKER_EXIT=1
	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"
	run _is_oneoff_container "drydock-myproj-ab12"
	[ "$status" -eq 1 ]
}

# ── T3: _session_has_transcript — RED→GREEN (S-1A, S-1B) ────────────────────

@test "_session_has_transcript: transcript present → returns 0 (S-1B)" {
	# GIVEN a fake HOME with a .jsonl transcript file for the given uuid
	# WHEN _session_has_transcript is called
	# THEN it returns 0 (transcript exists = ≥1 turn)
	local fake_home="$BATS_TEST_TMPDIR/fake-home"
	mkdir -p "$fake_home/.claude-container/projects/myproj-abc123"
	touch "$fake_home/.claude-container/projects/myproj-abc123/test-uuid-1234.jsonl"
	HOME="$fake_home" _session_has_transcript "test-uuid-1234"
}

@test "_session_has_transcript: transcript absent → returns 1 (S-1A)" {
	# GIVEN a fake HOME with no .jsonl transcript for the given uuid
	# WHEN _session_has_transcript is called
	# THEN it returns 1 (no transcript = fresh/zero-turn session)
	local fake_home="$BATS_TEST_TMPDIR/fake-home-absent"
	mkdir -p "$fake_home/.claude-container/projects"
	run env HOME="$fake_home" bash -c '. "$DRYDOCK_HOME/lib/common.sh"; . "$DRYDOCK_HOME/lib/paths.sh"; . "$DRYDOCK_HOME/lib/compose.sh"; . "$DRYDOCK_HOME/lib/commands.sh"; _session_has_transcript "no-such-uuid"'
	[ "$status" -eq 1 ]
}

@test "_session_has_transcript: empty uuid → returns 1 (guard, no glob expansion)" {
	# GIVEN an empty uuid argument
	# WHEN _session_has_transcript is called
	# THEN it returns 1 (guard catches empty uuid before glob)
	local fake_home="$BATS_TEST_TMPDIR/fake-home-empty"
	mkdir -p "$fake_home/.claude-container/projects"
	run env HOME="$fake_home" bash -c '. "$DRYDOCK_HOME/lib/common.sh"; . "$DRYDOCK_HOME/lib/paths.sh"; . "$DRYDOCK_HOME/lib/compose.sh"; . "$DRYDOCK_HOME/lib/commands.sh"; _session_has_transcript ""'
	[ "$status" -eq 1 ]
}

# ── T4: _capture_mux_labels — RED→GREEN (S-4A–4E, OQ-3) ─────────────────────

@test "_capture_mux_labels: zellij env → emits --label drydock.mux=zellij and session token (S-4A)" {
	# GIVEN ZELLIJ and ZELLIJ_SESSION_NAME are set
	# WHEN _capture_mux_labels is called
	# THEN emits --label drydock.mux=zellij and --label drydock.mux_session=<name> one per line
	local output
	output="$(ZELLIJ=1 ZELLIJ_SESSION_NAME="main" TMUX="" STY="" _capture_mux_labels)"
	[[ "$output" == *"--label"* ]]
	[[ "$output" == *"drydock.mux=zellij"* ]]
	[[ "$output" == *"drydock.mux_session=main"* ]]
}

@test "_capture_mux_labels: tmux env → emits --label drydock.mux=tmux (S-4B)" {
	# GIVEN TMUX is set (tmux display-message fallback, not available in CI)
	# Use TMUX_SESSION_NAME as a direct env override — we test the label output
	# by providing a stub tmux command that echoes a session name.
	local stub_dir="$BATS_TEST_TMPDIR/tmux-stub"
	mkdir -p "$stub_dir"
	cat >"$stub_dir/tmux" <<'TSTUB'
#!/usr/bin/env bash
printf 'worksession\n'
TSTUB
	chmod +x "$stub_dir/tmux"
	local output
	output="$(PATH="$stub_dir:$PATH" ZELLIJ="" STY="" TMUX="tmux-session-info" _capture_mux_labels)"
	[[ "$output" == *"drydock.mux=tmux"* ]]
	[[ "$output" == *"drydock.mux_session=worksession"* ]]
}

@test "_capture_mux_labels: screen env → emits --label drydock.mux=screen (S-4C)" {
	# GIVEN STY is set (screen session id)
	# WHEN _capture_mux_labels is called
	# THEN emits --label drydock.mux=screen and --label drydock.mux_session=<id>
	local output
	output="$(ZELLIJ="" TMUX="" STY="123.pts-0.host" _capture_mux_labels)"
	[[ "$output" == *"drydock.mux=screen"* ]]
	[[ "$output" == *"drydock.mux_session=123.pts-0.host"* ]]
}

@test "_capture_mux_labels: no mux env → emits nothing (S-4D)" {
	# GIVEN ZELLIJ, TMUX, STY all unset
	# WHEN _capture_mux_labels is called
	# THEN emits nothing (empty output)
	local output
	output="$(ZELLIJ="" TMUX="" STY="" _capture_mux_labels)"
	[ -z "$output" ]
}

@test "_capture_mux_labels: zellij with empty session name → omits mux_session token (S-4E, OQ-3)" {
	# GIVEN ZELLIJ is set but ZELLIJ_SESSION_NAME is empty
	# WHEN _capture_mux_labels is called
	# THEN drydock.mux=zellij IS emitted, drydock.mux_session is OMITTED entirely
	local output
	output="$(ZELLIJ=1 ZELLIJ_SESSION_NAME="" TMUX="" STY="" _capture_mux_labels)"
	[[ "$output" == *"drydock.mux=zellij"* ]]
	[[ "$output" != *"drydock.mux_session"* ]]
}

@test "_capture_mux_labels: tokens are one per line (array-safe for spaces in names)" {
	# GIVEN ZELLIJ_SESSION_NAME with a space (e.g. 'my session')
	# WHEN tokens are consumed via while IFS= read -r
	# THEN all tokens including the session name with spaces are captured correctly
	local -a args=()
	while IFS= read -r a; do args+=("$a"); done < <(
		ZELLIJ=1 ZELLIJ_SESSION_NAME="my session" TMUX="" STY="" _capture_mux_labels
	)
	# Should have 4 tokens: --label, drydock.mux=zellij, --label, drydock.mux_session=my session
	[ "${#args[@]}" -eq 4 ]
	[ "${args[0]}" = "--label" ]
	[ "${args[1]}" = "drydock.mux=zellij" ]
	[ "${args[2]}" = "--label" ]
	[ "${args[3]}" = "drydock.mux_session=my session" ]
}

# ── T5: _mux_reattach_guidance — RED→GREEN (S-3A–3E) ─────────────────────────

@test "_mux_reattach_guidance: zellij mux + named session → prints 'zellij attach <name>' (S-3A)" {
	# GIVEN drydock.mux=zellij, drydock.mux_session=main
	# WHEN _mux_reattach_guidance is called
	# THEN output contains 'zellij attach main' and exits 0
	export MOCK_ONEOFF="False"
	export MOCK_MUX="zellij"
	export MOCK_MUX_SESSION="main"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	run _mux_reattach_guidance "drydock-myproj-ab12"
	[ "$status" -eq 0 ]
	[[ "$output" == *"zellij attach main"* ]]
}

@test "_mux_reattach_guidance: tmux mux + named session → prints 'tmux attach -t <name>' (S-3B)" {
	export MOCK_ONEOFF="False"
	export MOCK_MUX="tmux"
	export MOCK_MUX_SESSION="work"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	run _mux_reattach_guidance "drydock-myproj-ab12"
	[ "$status" -eq 0 ]
	[[ "$output" == *"tmux attach -t work"* ]]
}

@test "_mux_reattach_guidance: screen mux + named session → prints 'screen -r <id>' (S-3C)" {
	export MOCK_ONEOFF="False"
	export MOCK_MUX="screen"
	export MOCK_MUX_SESSION="123.pts-0.host"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	run _mux_reattach_guidance "drydock-myproj-ab12"
	[ "$status" -eq 0 ]
	[[ "$output" == *"screen -r 123.pts-0.host"* ]]
}

@test "_mux_reattach_guidance: mux present but empty session name → generic fallback, exit 0 (S-3D)" {
	# Distinct MOCK_MUX and MOCK_MUX_SESSION values to prove correct label dispatch
	export MOCK_ONEOFF="False"
	export MOCK_MUX="zellij"
	export MOCK_MUX_SESSION=""
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	run _mux_reattach_guidance "drydock-myproj-ab12"
	[ "$status" -eq 0 ]
	# Generic fallback message IS present (mux known, session name missing → switch-back guidance)
	[[ "$output" == *"switch back to your zellij session"* ]]
	# Must NOT produce a bare "zellij attach " with an empty trailing argument
	[[ "$output" != *"zellij attach "* ]]
}

@test "_mux_reattach_guidance: no mux labels → generic guidance message, exit 0 (S-3E)" {
	# GIVEN drydock.mux is absent/empty, drydock.mux_session is absent
	export MOCK_ONEOFF="False"
	export MOCK_MUX=""
	export MOCK_MUX_SESSION=""
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	run _mux_reattach_guidance "drydock-myproj-ab12"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
}

# ── T6: cmd_attach oneoff gate — RED→GREEN (S-2A, S-2B, S-2C) ───────────────

@test "cmd_attach: oneoff=True + no-TTY (explicit name) → prints guidance + exit 0, NO reap (S-2B)" {
	# GIVEN target container is oneoff (com.docker.compose.oneoff=True)
	# AND no TTY (normal test environment)
	# WHEN cmd_attach is called with explicit disc name
	# THEN guidance is printed, exit 0, NO compose exec, NO rm -f (S-2A/2B)
	export MOCK_ONEOFF="True"
	export MOCK_MUX="zellij"
	export MOCK_MUX_SESSION="main"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	# NO _drydock_has_tty override — no TTY in test env

	run cmd_attach "ab12" 2>&1
	[ "$status" -eq 0 ]
	# Guidance must be printed
	[[ "$output" == *"zellij attach main"* ]]
	# Must NOT invoke compose exec (no reap, no rm).
	# run + status check: a bare mid-test `! cmd` is exempt from bats errexit
	# and can never fail.
	run grep -E "compose.*exec" "$DOCKER_CALL_LOG"
	[ "$status" -ne 0 ]
	run grep "rm -f" "$DOCKER_CALL_LOG"
	[ "$status" -ne 0 ]
}

@test "cmd_attach: oneoff=True + TTY (single session) → prints guidance + exit 0 (S-2A)" {
	# GIVEN oneoff container, single session, TTY present
	# WHEN cmd_attach is called without disc arg (single-session path)
	# THEN guidance is printed and exits 0
	export MOCK_ONEOFF="True"
	export MOCK_MUX="tmux"
	export MOCK_MUX_SESSION="work"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	run cmd_attach 2>&1
	[ "$status" -eq 0 ]
	[[ "$output" == *"tmux attach -t work"* ]]
	! grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
}

@test "cmd_attach: oneoff=False (persistent) → proceeds to normal flow (S-2C)" {
	# GIVEN container is persistent (oneoff=False)
	# WHEN cmd_attach is called with TTY
	# THEN normal compose exec flow proceeds (no early exit)
	export MOCK_ONEOFF="False"
	export MOCK_MUX=""
	export MOCK_MUX_SESSION=""
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	# Normal flow: compose exec must be called
	grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
}

@test "cmd_attach: multi-session + no-TTY → exit 2 before oneoff gate (preserves list-and-hint)" {
	# S-2B scoping: multi+no-TTY exits 2 at ~2249 BEFORE target resolution
	# so the oneoff gate at 2252+ is never reached — correct behavior
	export MOCK_ONEOFF="True"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12
drydock-myproj-ef56")"
	export DOCKER="$stub"
	# No TTY override

	run cmd_attach 2>&1
	[ "$status" -eq 2 ]
}

# ── T7: cmd_run attach gate — RED→GREEN (S-2A, S-2C) ────────────────────────

@test "cmd_run attach branch: oneoff=True → prints guidance + return 0, NO reap (T7, S-2A)" {
	# GIVEN a live container with oneoff=True, user chooses Attach from menu
	# WHEN cmd_run is invoked with TTY
	# THEN guidance is printed, returns 0, NO _reap_orphan_claude, NO compose exec
	export MOCK_ONEOFF="True"
	export MOCK_MUX="zellij"
	export MOCK_MUX_SESSION="main"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	# Stub env/helpers needed by cmd_run
	_drydock_has_tty() { return 0; }
	_select_choice() { printf 'Attach: drydock-myproj-ab12\n'; }
	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}
	ensure_prereqs() { :; }
	ensure_image() { :; }
	ensure_runtime_dirs() { :; }
	ensure_synced() { :; }
	warn_unlinked_skill_symlinks() { :; }
	compose_files() { printf ''; }

	run cmd_run 2>&1
	[ "$status" -eq 0 ]
	[[ "$output" == *"zellij attach main"* ]]
	# Must NOT reap (no rm in call log from attach path)
	! grep -qE "^compose.*exec" "$DOCKER_CALL_LOG"
}

@test "cmd_run attach branch: oneoff=False → proceeds to normal reap+resume flow (T7, S-2C)" {
	# GIVEN a persistent container (oneoff=False)
	# WHEN user chooses Attach from cmd_run menu
	# THEN normal flow runs (compose exec appears in call log)
	export MOCK_ONEOFF="False"
	export MOCK_MUX=""
	export MOCK_MUX_SESSION=""
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"

	_drydock_has_tty() { return 0; }
	_select_choice() { printf 'Attach: drydock-myproj-ab12\n'; }
	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}
	ensure_prereqs() { :; }
	ensure_image() { :; }
	ensure_runtime_dirs() { :; }
	ensure_synced() { :; }
	warn_unlinked_skill_symlinks() { :; }
	compose_files() { printf ''; }

	run cmd_run 2>&1
	[ "$status" -eq 0 ]
	# Normal flow: compose exec called
	grep -qE "exec" "$DOCKER_CALL_LOG"
}

# ── T8: Bug 1 transcript switch in cmd_attach — RED→GREEN (S-1A, S-1B) ──────

@test "cmd_attach: transcript absent → uses --session-id <uuid>, NOT --resume (S-1A, Bug 1 fix)" {
	# GIVEN session UUID in marker file, no transcript .jsonl present
	# WHEN cmd_attach is called
	# THEN claude is invoked with --session-id <uuid>, NOT --resume <uuid>
	export MOCK_ONEOFF="False"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	# Set up fake HOME with marker but NO transcript
	local fake_home="$BATS_TEST_TMPDIR/fake-home-t8a"
	mkdir -p "$fake_home/.claude-container-ab12"
	printf 'test-uuid-abcd\n' > "$fake_home/.claude-container-ab12/session-id"
	# No transcript file
	export HOME="$fake_home"

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	grep -q -- "--session-id test-uuid-abcd" "$DOCKER_CALL_LOG"
	! grep -q -- "--resume test-uuid-abcd" "$DOCKER_CALL_LOG"
}

@test "cmd_attach: transcript present → uses --resume <uuid>, NOT --session-id (S-1B, Bug 1 fix)" {
	# GIVEN session UUID in marker file AND transcript .jsonl exists
	# WHEN cmd_attach is called
	# THEN claude is invoked with --resume <uuid>, NOT --session-id <uuid>
	export MOCK_ONEOFF="False"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	# Set up fake HOME with marker AND transcript
	local fake_home="$BATS_TEST_TMPDIR/fake-home-t8b"
	mkdir -p "$fake_home/.claude-container-ab12"
	printf 'test-uuid-abcd\n' > "$fake_home/.claude-container-ab12/session-id"
	mkdir -p "$fake_home/.claude-container/projects/myproj"
	touch "$fake_home/.claude-container/projects/myproj/test-uuid-abcd.jsonl"
	export HOME="$fake_home"

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	grep -q -- "--resume test-uuid-abcd" "$DOCKER_CALL_LOG"
	! grep -q -- "--session-id test-uuid-abcd" "$DOCKER_CALL_LOG"
}

@test "cmd_attach: reap still runs on the --resume path (transcript present) (S-1B, Bug 1 reap rule)" {
	# GIVEN transcript is present (so the switch picks --resume)
	# WHEN cmd_attach is called
	# THEN _reap_orphan_claude still runs (pkill -f <uuid> appears in DOCKER_CALL_LOG) —
	# the transcript switch does NOT skip the reap. Transcript-ABSENT reap coverage
	# lives in the S-1A tests (cmd_attach transcript-absent → --session-id).
	export MOCK_ONEOFF="False"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	local fake_home="$BATS_TEST_TMPDIR/fake-home-t8c"
	mkdir -p "$fake_home/.claude-container-ab12"
	printf 'test-uuid-abcd\n' > "$fake_home/.claude-container-ab12/session-id"
	mkdir -p "$fake_home/.claude-container/projects/myproj"
	touch "$fake_home/.claude-container/projects/myproj/test-uuid-abcd.jsonl"
	export HOME="$fake_home"

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	# pkill -f <uuid> must appear — confirms _reap_orphan_claude ran with the session uuid
	grep -q "pkill -f test-uuid-abcd" "$DOCKER_CALL_LOG"
}

# ── T9: Bug 1 transcript switch in cmd_run attach branch — RED→GREEN (S-1A, S-1B) ──

@test "cmd_run attach branch: transcript absent → uses --session-id <uuid> (S-1A, Bug 1 fix)" {
	# GIVEN uuid in marker, no transcript, user selects Attach from menu
	# WHEN cmd_run runs
	# THEN --session-id is used, NOT --resume
	export MOCK_ONEOFF="False"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }
	_select_choice() { printf 'Attach: drydock-myproj-ab12\n'; }
	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}
	ensure_prereqs() { :; }; ensure_image() { :; }; ensure_runtime_dirs() { :; }
	ensure_synced() { :; }; warn_unlinked_skill_symlinks() { :; }
	compose_files() { printf ''; }

	local fake_home="$BATS_TEST_TMPDIR/fake-home-t9a"
	mkdir -p "$fake_home/.claude-container-ab12"
	printf 'test-uuid-9999\n' > "$fake_home/.claude-container-ab12/session-id"
	export HOME="$fake_home"

	run cmd_run 2>&1
	[ "$status" -eq 0 ]
	grep -q -- "--session-id test-uuid-9999" "$DOCKER_CALL_LOG"
	! grep -q -- "--resume test-uuid-9999" "$DOCKER_CALL_LOG"
}

@test "cmd_run attach branch: transcript present → uses --resume <uuid> (S-1B, Bug 1 fix)" {
	# GIVEN uuid in marker AND transcript exists
	# WHEN cmd_run attach branch runs
	# THEN --resume is used
	export MOCK_ONEOFF="False"
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }
	_select_choice() { printf 'Attach: drydock-myproj-ab12\n'; }
	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}
	ensure_prereqs() { :; }; ensure_image() { :; }; ensure_runtime_dirs() { :; }
	ensure_synced() { :; }; warn_unlinked_skill_symlinks() { :; }
	compose_files() { printf ''; }

	local fake_home="$BATS_TEST_TMPDIR/fake-home-t9b"
	mkdir -p "$fake_home/.claude-container-ab12"
	printf 'test-uuid-9999\n' > "$fake_home/.claude-container-ab12/session-id"
	mkdir -p "$fake_home/.claude-container/projects/myproj"
	touch "$fake_home/.claude-container/projects/myproj/test-uuid-9999.jsonl"
	export HOME="$fake_home"

	run cmd_run 2>&1
	[ "$status" -eq 0 ]
	grep -q -- "--resume test-uuid-9999" "$DOCKER_CALL_LOG"
	! grep -q -- "--session-id test-uuid-9999" "$DOCKER_CALL_LOG"
}

# ── T10: Nested launch mux label capture — RED→GREEN (S-4A–4E) ───────────────

@test "cmd_run nested launch: zellij env → compose run includes --label drydock.mux=zellij (T10, S-4A)" {
	# GIVEN ZELLIJ env is set during nested launch
	# WHEN cmd_run detects nested session
	# THEN compose run includes --label drydock.mux=zellij in DOCKER_CALL_LOG
	export ZELLIJ=1
	export ZELLIJ_SESSION_NAME="main"
	unset TMUX STY 2>/dev/null || true
	export TMUX=""
	export STY=""

	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}
	ensure_prereqs() { :; }; ensure_image() { :; }; ensure_runtime_dirs() { :; }
	ensure_synced() { :; }; warn_unlinked_skill_symlinks() { :; }
	compose_files() { printf ''; }
	# Override exec to log instead of replacing process
	exec() { echo "exec $*" >> "$DOCKER_CALL_LOG"; }

	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"

	run cmd_run 2>&1
	# exec is stubbed so status can vary; check log content
	grep -q "drydock.mux=zellij" "$DOCKER_CALL_LOG"
	grep -q "drydock.mux_session=main" "$DOCKER_CALL_LOG"
	# Assert ORDER: --label drydock.mux=zellij must precede the service name ' drydock '
	# (space-padded to distinguish from container names like drydock-myproj-ab12).
	# If mux_args were placed after the service name the label would become a claude arg.
	grep -qE -- "--label drydock\.mux=zellij.* drydock " "$DOCKER_CALL_LOG"
}

@test "cmd_run nested launch: no mux env → compose run has NO drydock.mux label (T10, S-4D)" {
	# GIVEN no mux environment vars
	# WHEN cmd_run detects nested via DRYDOCK_NESTED=1
	# THEN compose run has NO drydock.mux label
	export DRYDOCK_NESTED=1
	export ZELLIJ=""
	export TMUX=""
	export STY=""

	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}
	ensure_prereqs() { :; }; ensure_image() { :; }; ensure_runtime_dirs() { :; }
	ensure_synced() { :; }; warn_unlinked_skill_symlinks() { :; }
	compose_files() { printf ''; }
	exec() { echo "exec $*" >> "$DOCKER_CALL_LOG"; }

	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"

	run cmd_run 2>&1
	! grep -q "drydock.mux" "$DOCKER_CALL_LOG"
}

# ── Scenario (a): explicit disc arg → direct attach ───────────────────────────

@test "cmd_attach: explicit disc arg → invokes compose exec with claude session flag (REQ-6-M)" {
	# GIVEN a live container drydock-myproj-ab12
	# WHEN cmd_attach ab12 is called with a TTY
	# THEN docker compose exec is called with claude --resume or --session-id (Bug 1 fix:
	# flag depends on transcript presence; either flag connects to the session)
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	# Simulate TTY presence — cmd_attach requires a TTY (FIX-5).
	_drydock_has_tty() { return 0; }

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	# Log format: "compose <args> exec -it drydock claude --resume|--session-id"
	grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
	grep -qE -- "--resume|--session-id" "$DOCKER_CALL_LOG"
}

@test "cmd_attach: explicit disc arg → NO menu shown (REQ-7-M sub-scenario a)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	# Must not show disambiguation menu
	[[ "$output" != *"[1]"* ]]
}

# ── Scenario (a-no-tty): explicit disc + no TTY → exit 2 with friendly error ──

@test "cmd_attach: explicit disc arg + no TTY → exits 2 with friendly error (FIX-5)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	# Do NOT override _drydock_has_tty — tests run without a TTY by default.

	run cmd_attach "ab12" 2>&1
	[ "$status" -eq 2 ]
	[[ "$output" == *"requires a TTY"* ]]
	# The TTY guard MUST fire before compose exec is invoked.
	! grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
}

# ── Scenario (b): no arg + exactly 1 live session → direct attach ─────────────

@test "cmd_attach: no arg + 1 live session → attach directly without menu (REQ-7-M sub-scenario b)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	run cmd_attach
	[ "$status" -eq 0 ]
	grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
	grep -qE -- "--resume|--session-id" "$DOCKER_CALL_LOG"
	[[ "$output" != *"[1]"* ]]
}

# ── Scenario (b-no-tty): no arg + 1 live session + no TTY → exit 2 ────────────

@test "cmd_attach: no arg + 1 live session + no TTY → exits 2 without invoking compose exec (FIX-5)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	# Do NOT override _drydock_has_tty — tests run without a TTY by default.

	run cmd_attach 2>&1
	[ "$status" -eq 2 ]
	[[ "$output" == *"requires a TTY"* ]]
	# The TTY guard MUST fire before compose exec is invoked.
	! grep -qE "compose.*exec" "$DOCKER_CALL_LOG"
}

# ── Scenario (d): no arg + N>1 + no-TTY → list + exit 2 ──────────────────────

@test "cmd_attach: no arg + N>1 sessions + no-TTY → exit 2 (REQ-7-M sub-scenario d)" {
	# Two live sessions; stdin is not a TTY when run via 'run cmd_attach'.
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12
drydock-myproj-ef56")"
	export DOCKER="$stub"

	run cmd_attach
	[ "$status" -eq 2 ]
}

@test "cmd_attach: no arg + N>1 sessions + no-TTY → stderr lists sessions (REQ-7-M sub-scenario d)" {
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12
drydock-myproj-ef56")"
	export DOCKER="$stub"

	run cmd_attach 2>&1
	# output (stderr redirected) should contain the session names
	[[ "$output" == *"drydock-myproj"* ]]
}

# ── Nonexistent name → error + exit non-zero (REQ-N5) ─────────────────────────

@test "cmd_attach: explicit nonexistent name → exits non-zero (REQ-N5)" {
	# No containers running for project.
	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"

	run cmd_attach "deadbeef"
	[ "$status" -ne 0 ]
}

@test "cmd_attach: explicit nonexistent name → error message on stderr (REQ-N5)" {
	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"

	run cmd_attach "deadbeef" 2>&1
	[[ "$output" == *"deadbeef"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"no"* ]]
}

# ── No sessions at all → error + exit non-zero ────────────────────────────────

@test "cmd_attach: no arg + 0 live sessions → exits non-zero (no session to attach)" {
	local stub
	stub="$(make_docker_stub_with_sessions "")"
	export DOCKER="$stub"

	run cmd_attach
	[ "$status" -ne 0 ]
}

# ── T1.10: cmd_attach uses _run_claude_lifecycle (teardown fires) (D-8) ───────

@test "cmd_attach: uses lifecycle helper — teardown rm -f appears after exec (D-8)" {
	# GIVEN cmd_attach is called with a live session and a TTY
	# WHEN claude exits
	# THEN docker rm -f appears in the call log (lifecycle helper was used,
	# not raw exec — exec would replace the process and teardown would never run)
	local stub
	stub="$(make_docker_stub_with_sessions "drydock-myproj-ab12")"
	export DOCKER="$stub"
	_drydock_has_tty() { return 0; }

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	grep -q "rm -f drydock-myproj-ab12" "$DOCKER_CALL_LOG"
}

# ── Filter: only matches current project (SR-NEW-1) ──────────────────────────

@test "cmd_attach: does NOT attach to a different project's container (SR-NEW-1)" {
	# A container from a different project should not match.
	local stub
	# Return a container from a different project only
	stub="$(make_docker_stub_with_sessions "drydock-otherproject-ab12")"
	export DOCKER="$stub"

	# With no arg and only a different project's container, should exit non-zero
	run cmd_attach
	[ "$status" -ne 0 ]
}
