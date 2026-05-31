#!/usr/bin/env bats
# test/cmd_marker.bats — unit tests for _write_session_marker and the
# uuid/marker/reap/--session-id/--resume wiring in launch and attach sites.
#
# D-4, D-5, D-6, REQ-6: drydock writes a uuid to
# $HOME/.claude-container-<disc>/session-id at launch AND at attach (idempotent).
# Attach sites derive disc from ${target_name##*-}, NEVER from $DRYDOCK_DISCRIMINATOR.

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

	# Isolate HOME so marker writes go to a temp directory (MEMORY.md rule).
	export HOME="$BATS_TEST_TMPDIR/fake-home"
	mkdir -p "$HOME"

	# DOCKER seam.
	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-calls.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	# Default stubs for cmd_attach / launch helpers.
	ensure_prereqs() { :; }
	ensure_image() { :; }
	ensure_runtime_dirs() { :; }
	ensure_synced() { :; }
	export PROJECT_NAME="myproj"
}

# ── T4.1: _write_session_marker writes uuid to the correct path ──────────────

@test "_write_session_marker: writes uuid to \$HOME/.claude-container-<disc>/session-id (D-5)" {
	# GIVEN a disc and a uuid
	# WHEN _write_session_marker is called
	# THEN the uuid is written to $HOME/.claude-container-<disc>/session-id
	mkdir -p "$HOME/.claude-container-ab12"
	_write_session_marker "ab12" "550e8400-e29b-41d4-a716-446655440000"
	local written
	written="$(cat "$HOME/.claude-container-ab12/session-id")"
	[ "$written" = "550e8400-e29b-41d4-a716-446655440000" ]
}

# ── T4.2: marker write is idempotent ────────────────────────────────────────

@test "_write_session_marker: idempotent — second write with same uuid overwrites cleanly (D-5)" {
	# GIVEN a disc and two writes with the same uuid
	# WHEN _write_session_marker is called twice
	# THEN the file contains the uuid exactly once (no duplication)
	mkdir -p "$HOME/.claude-container-ab12"
	_write_session_marker "ab12" "550e8400-e29b-41d4-a716-446655440000"
	_write_session_marker "ab12" "550e8400-e29b-41d4-a716-446655440000"
	local line_count
	line_count="$(wc -l < "$HOME/.claude-container-ab12/session-id")"
	[ "$line_count" -eq 1 ]
	local written
	written="$(cat "$HOME/.claude-container-ab12/session-id")"
	[ "$written" = "550e8400-e29b-41d4-a716-446655440000" ]
}

# ── T4.3: marker written on launch path (_launch_new) ───────────────────────

@test "_launch_new: session marker written after container start (D-5, refinement #3)" {
	# GIVEN _launch_new is called with a TTY
	# WHEN the launch completes
	# THEN the session-id marker file exists under the correct session dir
	_drydock_has_tty() { return 0; }
	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}
	export_compose_env
	mkdir -p "$HOME/.claude-container-ab12"
	compose_files() { printf ''; }
	local compose_args=()

	run _launch_new "." compose_args
	[ "$status" -eq 0 ]
	[ -f "$HOME/.claude-container-ab12/session-id" ]
	# The marker must contain a non-empty uuid
	local uuid
	uuid="$(cat "$HOME/.claude-container-ab12/session-id")"
	[ -n "$uuid" ]
}

# ── T4.3b: claude invoked with --session-id on launch path ──────────────────

@test "_launch_new: passes --session-id <uuid> to claude (D-4)" {
	# GIVEN _launch_new is called
	# WHEN the docker call log is examined
	# THEN claude was invoked with --session-id <uuid>
	_drydock_has_tty() { return 0; }
	export_compose_env() {
		export PROJECT_NAME="myproj"
		export DRYDOCK_DISCRIMINATOR="ab12"
		export DRYDOCK_SESSION_NAME="drydock-myproj-ab12"
		export COMPOSE_PROJECT_NAME="drydock-myproj-ab12"
	}
	export_compose_env
	mkdir -p "$HOME/.claude-container-ab12"
	compose_files() { printf ''; }
	local compose_args=()

	run _launch_new "." compose_args
	[ "$status" -eq 0 ]
	grep -q -- "--session-id" "$DOCKER_CALL_LOG"
}

# ── T4.4: disc derived from target_name##*-, NOT from $DRYDOCK_DISCRIMINATOR ──

@test "cmd_attach: disc derived from target_name suffix, NOT \$DRYDOCK_DISCRIMINATOR (D-6, CRITICAL)" {
	# GIVEN DRYDOCK_DISCRIMINATOR is set to a WRONG (but valid-hex) value
	# AND the live container is drydock-myproj-cc99
	# WHEN cmd_attach is called for cc99
	# THEN the marker is read/written using disc=cc99 (from the target name),
	#   NOT disc=ff00 (the WRONG $DRYDOCK_DISCRIMINATOR)
	# This test catches the bug where cmd_run's attach branch calls export_compose_env,
	# which clobbers $DRYDOCK_DISCRIMINATOR with a fresh random value (D-6, CRITICAL).
	export DRYDOCK_DISCRIMINATOR="ff00"  # WRONG — should not be used for disc derivation

	local stub_dir="$BATS_TEST_TMPDIR/disc-stub"
	mkdir -p "$stub_dir"
	# Track all docker calls in the log; respond to ps with the live container name.
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${DOCKER_CALL_LOG}"
if [ "\${1:-}" = "ps" ]; then
    printf 'drydock-myproj-cc99\n'
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	export DOCKER="$stub_dir/docker"
	_drydock_has_tty() { return 0; }

	# Create the marker dir for the CORRECT disc (cc99), not the ff00 one.
	mkdir -p "$HOME/.claude-container-cc99"
	printf '550e8400-e29b-41d4-a716-446655440000\n' > "$HOME/.claude-container-cc99/session-id"

	run cmd_attach "cc99"
	[ "$status" -eq 0 ]

	# The marker for the CORRECT disc must have been (re)written.
	[ -f "$HOME/.claude-container-cc99/session-id" ]
	# The WRONG disc (ff00) must NOT have a marker file created by accident.
	[ ! -f "$HOME/.claude-container-ff00/session-id" ]
	# The docker call log must contain the specific uuid from the cc99 marker.
	# A buggy disc=ff00 path would emit bare --resume (no uuid) and fail this.
	grep -q -- "--resume 550e8400-e29b-41d4-a716-446655440000" "$DOCKER_CALL_LOG"
}

# ── T4.7: cmd_attach reads marker and passes --resume <uuid> ─────────────────

@test "cmd_attach: marker present → passes --resume <uuid> to claude (D-6, REQ-6)" {
	# GIVEN a live container with a session-id marker
	# WHEN cmd_attach is called
	# THEN docker compose exec is called with claude --resume <uuid>
	local stub_dir="$BATS_TEST_TMPDIR/resume-stub"
	mkdir -p "$stub_dir"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${DOCKER_CALL_LOG}"
if [ "\${1:-}" = "ps" ]; then
    printf 'drydock-myproj-ab12\n'
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	export DOCKER="$stub_dir/docker"
	_drydock_has_tty() { return 0; }

	mkdir -p "$HOME/.claude-container-ab12"
	printf '550e8400-e29b-41d4-a716-446655440000\n' > "$HOME/.claude-container-ab12/session-id"

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	# Must pass the specific uuid
	grep -q -- "--resume 550e8400-e29b-41d4-a716-446655440000" "$DOCKER_CALL_LOG"
}

# ── T4.7b: cmd_attach without marker → bare --resume (picker fallback) ───────

@test "cmd_attach: no marker → falls back to bare --resume (picker) (D-6, REQ-6)" {
	# GIVEN a live container but NO session-id marker file
	# WHEN cmd_attach is called
	# THEN docker compose exec is called with claude --resume (no specific uuid)
	local stub_dir="$BATS_TEST_TMPDIR/noresume-stub"
	mkdir -p "$stub_dir"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${DOCKER_CALL_LOG}"
if [ "\${1:-}" = "ps" ]; then
    printf 'drydock-myproj-ab12\n'
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	export DOCKER="$stub_dir/docker"
	_drydock_has_tty() { return 0; }

	# Ensure no marker file exists for ab12
	mkdir -p "$HOME/.claude-container-ab12"
	rm -f "$HOME/.claude-container-ab12/session-id"

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]
	# Must still invoke --resume (bare, no uuid after it)
	grep -q -- "--resume" "$DOCKER_CALL_LOG"
}

# ── T4.7c: cmd_attach calls reap before resume ──────────────────────────────

@test "cmd_attach: calls _reap_orphan_claude (docker exec pkill) before compose exec (D-7, REQ-5)" {
	# GIVEN a live container with a marker
	# WHEN cmd_attach is called
	# THEN docker exec <name> pkill appears BEFORE docker compose exec in the log
	local stub_dir="$BATS_TEST_TMPDIR/reap-order-stub"
	mkdir -p "$stub_dir"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${DOCKER_CALL_LOG}"
if [ "\${1:-}" = "ps" ]; then
    printf 'drydock-myproj-ab12\n'
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	export DOCKER="$stub_dir/docker"
	_drydock_has_tty() { return 0; }

	mkdir -p "$HOME/.claude-container-ab12"
	printf '550e8400-e29b-41d4-a716-446655440000\n' > "$HOME/.claude-container-ab12/session-id"

	run cmd_attach "ab12"
	[ "$status" -eq 0 ]

	# Both pkill and compose exec must appear in the log
	grep -q "pkill" "$DOCKER_CALL_LOG"
	grep -q "compose" "$DOCKER_CALL_LOG"

	# pkill must appear BEFORE compose exec (reap first, then attach)
	local pkill_line compose_line
	pkill_line="$(grep -n "pkill" "$DOCKER_CALL_LOG" | head -1 | cut -d: -f1)"
	compose_line="$(grep -n "compose" "$DOCKER_CALL_LOG" | tail -1 | cut -d: -f1)"
	[ "$pkill_line" -lt "$compose_line" ]
}
