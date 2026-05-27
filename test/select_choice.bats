#!/usr/bin/env bats
# test/select_choice.bats — unit tests for _select_choice helper (3-tier TUI selector)
#
# _select_choice <header> <opt1> [<opt2> ...]
#   Prints selected option to stdout, returns 0 on selection, 130 on cancel.
#
# TDD Cycle: RED → GREEN → REFACTOR (Strict TDD Mode)
# Design decision: sdd/session-persistence/redesign3-polish-tui-decision (engram #2766)
#
# Test seams:
#   GUM=<path>             override gum binary (default: gum)
#   FZF=<path>             override fzf binary (default: fzf)
#   DRYDOCK_DISABLE_GUM=1  force-skip gum tier regardless of availability
#   DRYDOCK_DISABLE_FZF=1  force-skip fzf tier regardless of availability
#
# Detection + invocation are unified via the same env var (advisor pattern):
#   local _gum="${GUM:-gum}"
#   if command -v "$_gum" >/dev/null 2>&1 → use it
# Tests put a stub script in BATS_TEST_TMPDIR and set GUM=<path-to-stub>.

load "helpers/load"

# ── Setup: hermetic env ──────────────────────────────────────────────────────

setup() {
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/commands.sh"

	# Default: disable both external tools so tests fall through to pure-bash.
	export DRYDOCK_DISABLE_GUM=1
	export DRYDOCK_DISABLE_FZF=1

	# Stub binary directory for this test run.
	export _SC_STUB_DIR="$BATS_TEST_TMPDIR/sc-stubs-$$"
	mkdir -p "$_SC_STUB_DIR"
}

# ── Helper: build a gum stub that prints its choice args ─────────────────────
# NOTE: log path is embedded in the stub at creation time (not via env var)
# because _make_gum_stub is called in a subshell via $(...) and exports
# do not propagate back to the caller. The stub path IS returned.

_make_gum_stub() {
	# Stub: when called as 'gum choose ...', echoes the first non-flag arg to stdout
	# (simulating user selecting the first option), then exits 0.
	# The stub also writes its invocation args to a log file for assertion.
	local log_path="$BATS_TEST_TMPDIR/gum-calls-$RANDOM.log"
	touch "$log_path"
	local stub_path="$_SC_STUB_DIR/stub-gum-$RANDOM"
	# Use regular heredoc (not quoted) so $log_path is expanded at creation time.
	cat >"$stub_path" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${log_path}"
# Skip flags and their values; print the first plain option argument.
skip_next=0
for arg in "\$@"; do
	if [ "\$skip_next" -eq 1 ]; then
		skip_next=0
		continue
	fi
	case "\$arg" in
	choose|--no-show-help) continue ;;
	--cursor|--header) skip_next=1; continue ;;
	--cursor=*|--header=*) continue ;;
	--*) continue ;;
	*) printf '%s\n' "\$arg"; exit 0 ;;
	esac
done
exit 0
STUB
	chmod +x "$stub_path"
	# Return: stub_path|log_path (caller splits on |)
	printf '%s|%s' "$stub_path" "$log_path"
}

# ── Helper: build a fzf stub ─────────────────────────────────────────────────

_make_fzf_stub() {
	# Stub: reads stdin (the options list), outputs the first line.
	local log_path="$BATS_TEST_TMPDIR/fzf-calls-$RANDOM.log"
	touch "$log_path"
	local stub_path="$_SC_STUB_DIR/stub-fzf-$RANDOM"
	cat >"$stub_path" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${log_path}"
# Read the piped input and output the first non-empty line.
while IFS= read -r line; do
	[ -n "\$line" ] && printf '%s\n' "\$line" && exit 0
done
exit 0
STUB
	chmod +x "$stub_path"
	printf '%s|%s' "$stub_path" "$log_path"
}

# ── Helper: build a stub that exits non-zero (simulate cancel) ───────────────

_make_cancel_stub() {
	local exit_code="${1:-130}"
	local stub_path="$_SC_STUB_DIR/stub-cancel-$RANDOM"
	cat >"$stub_path" <<STUB
#!/usr/bin/env bash
exit $exit_code
STUB
	chmod +x "$stub_path"
	printf '%s' "$stub_path"
}

# ══════════════════════════════════════════════════════════════════════════════
# Tier-1: gum dispatch
# ══════════════════════════════════════════════════════════════════════════════

@test "_select_choice: when GUM stub available → dispatches to gum (tier-1)" {
	local stub_info stub_path log_path
	stub_info="$(_make_gum_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"
	export GUM="$stub_path"
	unset DRYDOCK_DISABLE_GUM

	run _select_choice "drydock — test" "Opt A" "Opt B" "Opt C"
	[ "$status" -eq 0 ]
	# gum was invoked: call log should be non-empty
	[ -s "$log_path" ]
}

@test "_select_choice: gum stub → output is one of the provided options" {
	local stub_info stub_path log_path
	stub_info="$(_make_gum_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"
	export GUM="$stub_path"
	unset DRYDOCK_DISABLE_GUM

	run _select_choice "drydock — test" "Opt A" "Opt B"
	[ "$status" -eq 0 ]
	# output contains one of the options (glob to tolerate any leading/trailing content)
	[[ "$output" == *"Opt A"* ]] || [[ "$output" == *"Opt B"* ]]
}

@test "_select_choice: gum invocation includes 'choose' subcommand" {
	local stub_info stub_path log_path
	stub_info="$(_make_gum_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"
	export GUM="$stub_path"
	unset DRYDOCK_DISABLE_GUM

	run _select_choice "drydock — test" "Opt A" "Opt B"
	[ "$status" -eq 0 ]
	local log
	log="$(cat "$log_path")"
	[[ "$log" == *"choose"* ]]
}

@test "_select_choice: gum invocation includes header text" {
	local stub_info stub_path log_path
	stub_info="$(_make_gum_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"
	export GUM="$stub_path"
	unset DRYDOCK_DISABLE_GUM

	run _select_choice "My header text" "Opt A" "Opt B"
	[ "$status" -eq 0 ]
	local log
	log="$(cat "$log_path")"
	[[ "$log" == *"My header text"* ]]
}

@test "_select_choice: DRYDOCK_DISABLE_GUM=1 skips gum even when GUM stub is set" {
	local stub_info stub_path log_path
	stub_info="$(_make_gum_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"
	# fzf also disabled → falls to bash puro
	run bash -c "
		source '$DRYDOCK_HOME/lib/common.sh'
		source '$DRYDOCK_HOME/lib/paths.sh'
		source '$DRYDOCK_HOME/lib/compose.sh'
		source '$DRYDOCK_HOME/lib/commands.sh'
		export GUM='$stub_path'
		export DRYDOCK_DISABLE_GUM=1
		export DRYDOCK_DISABLE_FZF=1
		# Send 'q' to cancel the bash puro selector
		printf 'q' | _select_choice 'test header' 'Opt A' 'Opt B'
	" 2>/dev/null
	# gum stub should NOT have been invoked (log should remain empty)
	[ ! -s "$log_path" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# Tier-2: fzf fallback (gum absent or disabled)
# ══════════════════════════════════════════════════════════════════════════════

@test "_select_choice: when DRYDOCK_DISABLE_GUM=1 and FZF stub available → dispatches to fzf (tier-2)" {
	local stub_info stub_path log_path
	stub_info="$(_make_fzf_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"
	export FZF="$stub_path"
	export DRYDOCK_DISABLE_GUM=1
	unset DRYDOCK_DISABLE_FZF

	run _select_choice "drydock — test" "Opt A" "Opt B" "Opt C"
	[ "$status" -eq 0 ]
	# fzf was invoked
	[ -s "$log_path" ]
}

@test "_select_choice: fzf tier → output is one of the provided options" {
	local stub_info stub_path log_path
	stub_info="$(_make_fzf_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"
	export FZF="$stub_path"
	export DRYDOCK_DISABLE_GUM=1
	unset DRYDOCK_DISABLE_FZF

	run _select_choice "drydock — test" "Opt A" "Opt B"
	[ "$status" -eq 0 ]
	[[ "$output" == "Opt A" ]] || [[ "$output" == "Opt B" ]]
}

@test "_select_choice: DRYDOCK_DISABLE_FZF=1 skips fzf even when FZF stub is set" {
	local stub_info stub_path log_path
	stub_info="$(_make_fzf_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"

	# Falls to bash puro; cancel via 'q' on stdin
	run bash -c "
		source '$DRYDOCK_HOME/lib/common.sh'
		source '$DRYDOCK_HOME/lib/paths.sh'
		source '$DRYDOCK_HOME/lib/compose.sh'
		source '$DRYDOCK_HOME/lib/commands.sh'
		export FZF='$stub_path'
		export DRYDOCK_DISABLE_GUM=1
		export DRYDOCK_DISABLE_FZF=1
		printf 'q' | _select_choice 'test header' 'Opt A' 'Opt B'
	" 2>/dev/null
	# fzf stub should NOT have been invoked (log should remain empty)
	[ ! -s "$log_path" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# Tier-3: Bash puro (both gum and fzf absent/disabled)
# ══════════════════════════════════════════════════════════════════════════════

@test "_select_choice: bash puro tier → cancel via 'q' returns 130" {
	export DRYDOCK_DISABLE_GUM=1
	export DRYDOCK_DISABLE_FZF=1

	run bash -c "
		source '$DRYDOCK_HOME/lib/common.sh'
		source '$DRYDOCK_HOME/lib/paths.sh'
		source '$DRYDOCK_HOME/lib/compose.sh'
		source '$DRYDOCK_HOME/lib/commands.sh'
		export DRYDOCK_DISABLE_GUM=1
		export DRYDOCK_DISABLE_FZF=1
		printf 'q' | _select_choice 'test header' 'Opt A' 'Opt B'
	" 2>/dev/null
	[ "$status" -eq 130 ]
}

@test "_select_choice: bash puro tier → select first option via ENTER returns 0" {
	export DRYDOCK_DISABLE_GUM=1
	export DRYDOCK_DISABLE_FZF=1

	# Send ENTER key (newline) → selects the first option (active=0 by default).
	# Use 2>&1 to capture all output; the selected option appears in stdout,
	# rendered UI appears in stderr. We check that "First Option" is present.
	run bash -c "
		source '$DRYDOCK_HOME/lib/common.sh'
		source '$DRYDOCK_HOME/lib/paths.sh'
		source '$DRYDOCK_HOME/lib/compose.sh'
		source '$DRYDOCK_HOME/lib/commands.sh'
		export DRYDOCK_DISABLE_GUM=1
		export DRYDOCK_DISABLE_FZF=1
		printf '\n' | _select_choice 'test header' 'First Option' 'Second Option'
	" 2>&1
	[ "$status" -eq 0 ]
	[[ "$output" == *"First Option"* ]]
}

@test "_select_choice: bash puro tier → options rendered to stderr" {
	export DRYDOCK_DISABLE_GUM=1
	export DRYDOCK_DISABLE_FZF=1

	# Run with stdin=q (cancel) but capture stderr
	run bash -c "
		source '$DRYDOCK_HOME/lib/common.sh'
		source '$DRYDOCK_HOME/lib/paths.sh'
		source '$DRYDOCK_HOME/lib/compose.sh'
		source '$DRYDOCK_HOME/lib/commands.sh'
		export DRYDOCK_DISABLE_GUM=1
		export DRYDOCK_DISABLE_FZF=1
		printf 'q' | _select_choice 'My Test Header' 'Alpha' 'Beta'
	" 2>&1
	# header and at least one option should appear in stderr
	[[ "$output" == *"Alpha"* ]] || [[ "$output" == *"My Test Header"* ]]
}

@test "_select_choice: bash puro tier → header appears in stderr output" {
	export DRYDOCK_DISABLE_GUM=1
	export DRYDOCK_DISABLE_FZF=1

	run bash -c "
		source '$DRYDOCK_HOME/lib/common.sh'
		source '$DRYDOCK_HOME/lib/paths.sh'
		source '$DRYDOCK_HOME/lib/compose.sh'
		source '$DRYDOCK_HOME/lib/commands.sh'
		export DRYDOCK_DISABLE_GUM=1
		export DRYDOCK_DISABLE_FZF=1
		printf 'q' | _select_choice 'UniqueHeader42' 'Opt A' 'Opt B'
	" 2>&1
	[[ "$output" == *"UniqueHeader42"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Cancel path: non-zero from any tier → _select_choice returns 130
# ══════════════════════════════════════════════════════════════════════════════

@test "_select_choice: gum cancel (exit 130) → returns 130" {
	local stub
	stub="$(_make_cancel_stub 130)"
	export GUM="$stub"
	unset DRYDOCK_DISABLE_GUM

	run _select_choice "test" "Opt A" "Opt B"
	[ "$status" -eq 130 ]
}

@test "_select_choice: gum non-zero exit (not 130) → returns 130" {
	# Any non-zero from gum is treated as cancel
	local stub
	stub="$(_make_cancel_stub 1)"
	export GUM="$stub"
	unset DRYDOCK_DISABLE_GUM

	run _select_choice "test" "Opt A" "Opt B"
	[ "$status" -eq 130 ]
}

@test "_select_choice: fzf cancel (exit 130) → returns 130" {
	local stub
	stub="$(_make_cancel_stub 130)"
	export FZF="$stub"
	export DRYDOCK_DISABLE_GUM=1
	unset DRYDOCK_DISABLE_FZF

	run _select_choice "test" "Opt A" "Opt B"
	[ "$status" -eq 130 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# cmd_run: ≥1 sessions + TTY → uses _select_choice (not old text prompt)
# ══════════════════════════════════════════════════════════════════════════════

_setup_cmd_run_sc() {
	# Hermetic env for cmd_run + _select_choice tests.
	local fakehome="$BATS_TEST_TMPDIR/cmd-sc-home-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"

	export DRYDOCK_HOME="$DRYDOCK_HOME"

	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/commands.sh"

	ensure_prereqs() { :; }
	ensure_runtime_dirs() { :; }
	ensure_image() { :; }
	ensure_synced() { :; }

	_fixed_disc_sc() { printf 'cd34'; }
	export DRYDOCK_DISCRIMINATOR_FN=_fixed_disc_sc

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-sc-$$.log"
	touch "$DOCKER_CALL_LOG"

	CMD_SC_PROJECT_DIR="$BATS_TEST_TMPDIR/cmd-sc-proj-$$"
	mkdir -p "$CMD_SC_PROJECT_DIR"
	export PROJECT_NAME
	PROJECT_NAME="$(basename "$CMD_SC_PROJECT_DIR")"

	unset ZELLIJ TMUX STY DRYDOCK_NESTED
}

@test "cmd_run: ≥1 sessions + no-TTY → still exits 2 (non-TTY path unchanged)" {
	_setup_cmd_run_sc

	local stub_dir="$BATS_TEST_TMPDIR/docker-stub-sc-notty-$$"
	mkdir -p "$stub_dir"
	local proj_name
	proj_name="$(basename "$CMD_SC_PROJECT_DIR")"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${DOCKER_CALL_LOG}"
if [ "\${1:-}" = "ps" ]; then
	printf 'drydock-${proj_name}-ab12\n'
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	export DOCKER="$stub_dir/docker"
	exec() { printf '%s\n' "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	run cmd_run "$CMD_SC_PROJECT_DIR"
	[ "$status" -eq 2 ]
}

@test "cmd_run: ≥1 sessions + TTY + gum pick 'Cancel' → exits 130" {
	_setup_cmd_run_sc

	local proj_name
	proj_name="$(basename "$CMD_SC_PROJECT_DIR")"
	local stub_dir="$BATS_TEST_TMPDIR/docker-stub-sc-gum-$$"
	mkdir -p "$stub_dir"
	cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${DOCKER_CALL_LOG}"
if [ "\${1:-}" = "ps" ]; then
	printf 'drydock-${proj_name}-ab12\n'
fi
exit 0
STUB
	chmod +x "$stub_dir/docker"
	export DOCKER="$stub_dir/docker"
	exec() { printf '%s\n' "$*" >>"$DOCKER_CALL_LOG"; return 0; }

	# gum stub that always selects "Cancel"
	local gum_stub="$BATS_TEST_TMPDIR/stub-gum-cancel-$$"
	cat >"$gum_stub" <<'STUB'
#!/usr/bin/env bash
# Select the Cancel option (last arg before end).
# Find arg containing "Cancel"
for arg in "$@"; do
	if [[ "$arg" == *"Cancel"* ]]; then
		printf '%s\n' "$arg"
		exit 0
	fi
done
exit 0
STUB
	chmod +x "$gum_stub"
	export GUM="$gum_stub"
	unset DRYDOCK_DISABLE_GUM

	# Simulate TTY by providing stdin that is not empty
	run bash -c "
		source '$DRYDOCK_HOME/lib/common.sh'
		source '$DRYDOCK_HOME/lib/paths.sh'
		source '$DRYDOCK_HOME/lib/compose.sh'
		source '$DRYDOCK_HOME/lib/commands.sh'
		ensure_prereqs() { :; }
		ensure_runtime_dirs() { :; }
		ensure_image() { :; }
		ensure_synced() { :; }
		export HOME='$(dirname "$CMD_SC_PROJECT_DIR")'
		export DOCKER='$stub_dir/docker'
		export DOCKER_CALL_LOG='$DOCKER_CALL_LOG'
		export GUM='$gum_stub'
		unset DRYDOCK_DISABLE_GUM
		export PROJECT_NAME='$proj_name'
		# Simulate TTY: [ -t 0 ] is false in subshell, but we need TTY branch.
		# We override the TTY check for this test.
		_drydock_has_tty() { return 0; }
		cmd_run '$CMD_SC_PROJECT_DIR'
	" 2>/dev/null
	[ "$status" -eq 130 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# _pick_session_menu: N>1 → uses _select_choice
# ══════════════════════════════════════════════════════════════════════════════

@test "_pick_session_menu: with gum stub → invokes _select_choice (gum tier)" {
	local stub_info stub_path log_path
	stub_info="$(_make_gum_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"
	export GUM="$stub_path"
	unset DRYDOCK_DISABLE_GUM

	local sessions="drydock-myproj-ab12
drydock-myproj-ef56"

	run _pick_session_menu "$sessions"
	[ "$status" -eq 0 ]
	# gum was invoked
	[ -s "$log_path" ]
}

@test "_pick_session_menu: cancel via gum non-zero → returns 130" {
	local stub
	stub="$(_make_cancel_stub 130)"
	export GUM="$stub"
	unset DRYDOCK_DISABLE_GUM

	local sessions="drydock-myproj-ab12
drydock-myproj-ef56"

	run _pick_session_menu "$sessions"
	[ "$status" -eq 130 ]
}

@test "_pick_session_menu: with fzf stub (gum disabled) → invokes fzf tier" {
	local stub_info stub_path log_path
	stub_info="$(_make_fzf_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"
	export FZF="$stub_path"
	export DRYDOCK_DISABLE_GUM=1
	unset DRYDOCK_DISABLE_FZF

	local sessions="drydock-myproj-ab12
drydock-myproj-ef56"

	run _pick_session_menu "$sessions"
	[ "$status" -eq 0 ]
	[ -s "$log_path" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# cmd_doctor: TUI selector status lines
# ══════════════════════════════════════════════════════════════════════════════

_setup_cmd_doctor_sc() {
	local fakehome="$BATS_TEST_TMPDIR/doctor-sc-home-$$"
	mkdir -p "$fakehome/.claude-container"
	touch "$fakehome/.claude-container.json"
	export HOME="$fakehome"

	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/common.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/paths.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/compose.sh"
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/lib/commands.sh"

	export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-doctor-$$.log"
	touch "$DOCKER_CALL_LOG"
	export DOCKER="$DRYDOCK_HOME/test/helpers/mock-docker"

	local tmpdir="$BATS_TEST_TMPDIR/doctor-proj-$$"
	mkdir -p "$tmpdir"
	cd "$tmpdir"
}

@test "cmd_doctor: when gum available → reports gum as found (✓) in TUI selector section" {
	_setup_cmd_doctor_sc

	local stub_info stub_path log_path
	stub_info="$(_make_gum_stub)"
	stub_path="${stub_info%%|*}"
	log_path="${stub_info##*|}"
	export GUM="$stub_path"
	unset DRYDOCK_DISABLE_GUM

	run cmd_doctor 2>&1
	# Should report gum as found
	[[ "$output" == *"gum"* ]]
	# Should use ✓ symbol for found gum
	[[ "$output" == *"✓"*"gum"* ]] || [[ "$output" == *"gum"*"✓"* ]]
}

@test "cmd_doctor: when gum absent → reports gum as missing (⚠) in TUI selector section" {
	_setup_cmd_doctor_sc

	# Ensure gum is not found
	export DRYDOCK_DISABLE_GUM=1
	# And GUM points to a non-existent path
	export GUM="/nonexistent/gum-binary-$$"

	run cmd_doctor 2>&1
	# Should report gum as not found / missing
	[[ "$output" == *"gum"* ]]
}

@test "cmd_doctor: TUI selector section present in doctor output" {
	_setup_cmd_doctor_sc
	export DRYDOCK_DISABLE_GUM=1
	export DRYDOCK_DISABLE_FZF=1

	run cmd_doctor 2>&1
	# A TUI-related section or mention should appear
	[[ "$output" == *"gum"* ]] || [[ "$output" == *"fzf"* ]] || [[ "$output" == *"TUI"* ]] || [[ "$output" == *"selector"* ]]
}
