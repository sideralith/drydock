#!/usr/bin/env bats
# test/passthrough.bats — cmd_run / cmd_shell passthrough args tests
#
# Tests the [-- ARGS] passthrough for cmd_run and cmd_shell, and the
# top-level `drydock -- ARGS` shorthand routed via main().
# Uses DOCKER=echo so exec prints the docker command line without
# actually running Docker.

load "helpers/load"

# ── helpers ────────────────────────────────────────────────────────────────────

# Source bin/drydock and stub the heavy prereq functions, then run cmd_run.
# $@ forwarded to cmd_run.
_run_cmd_run() {
  run bash -c '
    drydock_home="$1"; shift
    source "$drydock_home/bin/drydock"
    ensure_prereqs()    { :; }
    ensure_runtime_dirs() { :; }
    ensure_image()      { :; }
    ensure_synced()     { :; }
    export_compose_env() {
      PROJECT_NAME="$(sanitize_project_name "$(basename "$1")")"
      export DRYDOCK_DISCRIMINATOR="ab12"
      export DRYDOCK_SESSION_NAME="drydock-${PROJECT_NAME}-ab12"
    }
    compose_files()     { printf "%s\n" "-f" "/tmp/x.yml"; }
    _drydock_has_tty()  { return 0; }
    DOCKER=echo
    cmd_run "$@"
  ' -- "$DRYDOCK_HOME" "$@"
}

# Source bin/drydock and stub the heavy prereq functions, then run cmd_shell.
# $@ forwarded to cmd_shell.
_run_cmd_shell() {
  run bash -c '
    drydock_home="$1"; shift
    source "$drydock_home/bin/drydock"
    ensure_prereqs()    { :; }
    ensure_runtime_dirs() { :; }
    ensure_image()      { :; }
    ensure_synced()     { :; }
    export_compose_env() {
      PROJECT_NAME="$(sanitize_project_name "$(basename "$1")")"
      export DRYDOCK_SESSION_NAME="drydock-${PROJECT_NAME}-test"
    }
    compose_files()     { printf "%s\n" "-f" "/tmp/x.yml"; }
    DOCKER=echo
    cmd_shell "$@"
  ' -- "$DRYDOCK_HOME" "$@"
}

# Source bin/drydock and stub the heavy prereq functions, then run main().
# $@ forwarded to main.
_run_main() {
  run bash -c '
    drydock_home="$1"; shift
    source "$drydock_home/bin/drydock"
    ensure_prereqs()    { :; }
    ensure_runtime_dirs() { :; }
    ensure_image()      { :; }
    ensure_synced()     { :; }
    export_compose_env() {
      PROJECT_NAME="$(sanitize_project_name "$(basename "$1")")"
      export DRYDOCK_DISCRIMINATOR="ab12"
      export DRYDOCK_SESSION_NAME="drydock-${PROJECT_NAME}-ab12"
    }
    compose_files()     { printf "%s\n" "-f" "/tmp/x.yml"; }
    _drydock_has_tty()  { return 0; }
    DOCKER=echo
    main "$@"
  ' -- "$DRYDOCK_HOME" "$@"
}

# ── cmd_run tests ──────────────────────────────────────────────────────────────

@test "cmd_run: no extra args -> runs claude with no passthrough" {
  # New persistent model: compose up -d then exec -it drydock claude.
  # DOCKER=echo means ps returns nothing (0 sessions) → non-nested → launch new.
  # Note: lifecycle helper also emits 'rm -f <name>' after exec returns,
  # so we match the exec line specifically. Since #131 P4, launch sites pass
  # --session-id <uuid> so the claude invocation is 'drydock claude --session-id <uuid>'.
  # We assert 'exec' is present and 'drydock claude' is invoked (no spurious passthrough).
  _run_cmd_run "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  # Must call claude with --session-id (uuid pre-assigned at launch, D-4).
  grep -qE ' drydock claude --session-id ' <<<"$output"
  # Must NOT have any passthrough args after --session-id <uuid>.
  ! grep -qE ' drydock claude --session-id [^ ]+ .+' <<<"$output"
}

@test "cmd_run: DIR -- --resume foo -> passes --resume foo clean (no injected --session-id)" {
  # User supplied --resume: drydock must NOT inject --session-id, pass through clean.
  _run_cmd_run "$BATS_TEST_TMPDIR" -- --resume foo
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  # Bare --resume foo must be present in the claude invocation.
  grep -qE ' drydock claude --resume foo$' <<<"$output"
  # --session-id must NOT appear — injecting it would conflict with user --resume.
  ! grep -q -- '--session-id' <<<"$output"
}

@test "cmd_run: -- --resume foo (no DIR) -> passes --resume foo clean (no injected --session-id)" {
  _run_cmd_run -- --resume foo
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  grep -qE ' drydock claude --resume foo$' <<<"$output"
  ! grep -q -- '--session-id' <<<"$output"
}

@test "cmd_run: -- --model opus (non-session passthrough) -> still injects --session-id" {
  # Non-session passthrough must NOT suppress drydock's session-id injection.
  _run_cmd_run "$BATS_TEST_TMPDIR" -- --model opus
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  grep -qE ' drydock claude --session-id [^ ]+ --model opus' <<<"$output"
}

# ── cmd_shell tests ────────────────────────────────────────────────────────────

@test "cmd_shell: no passthrough -> runs bash" {
  _run_cmd_shell "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run --rm --name drydock-"* ]]
  [[ "$output" == *"-shell "* ]]
  [[ "$output" == *" drydock bash" ]]
}

@test "cmd_shell: DIR -- ls -la -> runs ls -la, not bash" {
  _run_cmd_shell "$BATS_TEST_TMPDIR" -- ls -la
  [ "$status" -eq 0 ]
  [[ "$output" == *"run --rm --name drydock-"* ]]
  [[ "$output" == *"-shell "* ]]
  [[ "$output" == *" drydock ls -la" ]]
  [[ "$output" != *"drydock bash"* ]]
}

# ── main() dispatch tests ──────────────────────────────────────────────────────

@test "main -- --resume foo -> routes to cmd_run with passthrough (no injected --session-id)" {
  _run_main -- --resume foo
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  # User supplied --resume: drydock must pass through clean.
  grep -qE ' drydock claude --resume foo$' <<<"$output"
  ! grep -q -- '--session-id' <<<"$output"
}

@test "main run -- --resume foo -> routes to cmd_run with passthrough (no injected --session-id)" {
  _run_main run -- --resume foo
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  grep -qE ' drydock claude --resume foo$' <<<"$output"
  ! grep -q -- '--session-id' <<<"$output"
}

# ── short-flag / --continue passthrough tests ─────────────────────────────────
# -r, -c, and --continue are documented session-establishing flags equivalent to
# --resume / --session-id. When present, drydock must NOT inject --session-id
# and must NOT write a session marker.

@test "cmd_run: -- -r foo -> passes -r foo clean (no injected --session-id)" {
  _run_cmd_run "$BATS_TEST_TMPDIR" -- -r foo
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  grep -qE ' drydock claude -r foo$' <<<"$output"
  ! grep -q -- '--session-id' <<<"$output"
}

@test "cmd_run: -- -c -> passes -c clean (no injected --session-id)" {
  _run_cmd_run "$BATS_TEST_TMPDIR" -- -c
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  grep -qE ' drydock claude -c$' <<<"$output"
  ! grep -q -- '--session-id' <<<"$output"
}

@test "cmd_run: -- --continue -> passes --continue clean (no injected --session-id)" {
  _run_cmd_run "$BATS_TEST_TMPDIR" -- --continue
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  grep -qE ' drydock claude --continue$' <<<"$output"
  ! grep -q -- '--session-id' <<<"$output"
}

@test "main -- -r foo -> routes to cmd_run with passthrough (no injected --session-id)" {
  _run_main -- -r foo
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  grep -qE ' drydock claude -r foo$' <<<"$output"
  ! grep -q -- '--session-id' <<<"$output"
}

@test "main -- --continue -> routes to cmd_run with passthrough (no injected --session-id)" {
  _run_main -- --continue
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  grep -qE ' drydock claude --continue$' <<<"$output"
  ! grep -q -- '--session-id' <<<"$output"
}

# ── --from-pr passthrough test ────────────────────────────────────────────────
# --from-pr is a session-establishing flag (resume by PR number/URL) — same
# class as --resume / --continue. When present, drydock must NOT inject
# --session-id and must pass the invocation through clean.

@test "cmd_run: -- --from-pr 123 -> passes --from-pr 123 clean (no injected --session-id)" {
  _run_cmd_run "$BATS_TEST_TMPDIR" -- --from-pr 123
  [ "$status" -eq 0 ]
  [[ "$output" == *" exec "* ]]
  grep -qE ' drydock claude --from-pr 123$' <<<"$output"
  ! grep -q -- '--session-id' <<<"$output"
}
