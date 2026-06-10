#!/usr/bin/env bats
# test/egress_smoke.bats — unit tests for the egress-smoke.sh (G2) helpers.
#
# Sources scripts/egress-smoke.sh via the source-guard so the helpers
# (_write_filter, _check_preconditions, _cleanup) can be exercised without
# touching the real Docker daemon: every test that reaches a docker call stubs
# `docker` with a shell function (shell functions win over PATH lookup) that
# logs its arguments to a file and fakes the minimal responses the helper needs.

load "helpers/load"

setup() {
	# Source the smoke script. The source-guard ensures main() is not invoked.
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/scripts/egress-smoke.sh"
}

# ── source-guard ──────────────────────────────────────────────────────────────

@test "egress-smoke: sourcing produces zero output and registers no EXIT trap" {
	# A top-level `trap _cleanup EXIT` would fire on every sourcing shell's exit
	# and run `docker rm -f` against the live daemon — the trap must be owned by
	# main() so sourcing for tests is side-effect-free.
	run bash -c '
		source "$1/scripts/egress-smoke.sh"
		trap -p EXIT
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "egress-smoke: helpers are defined after sourcing" {
	declare -f _write_filter >/dev/null
	declare -f _check_preconditions >/dev/null
	declare -f _cleanup >/dev/null
}

# ── _write_filter (C1: sidecar must be able to read the filter) ───────────────

@test "_write_filter: generated filter file is world-readable (mode 644)" {
	# The filter is RO bind-mounted into the sidecar where tinyproxy runs as a
	# non-root uid with cap_drop ALL (no DAC_OVERRIDE). mktemp creates 0600 —
	# without an explicit chmod the proxy cannot read its own filter and the
	# smoke sidecar never becomes healthy.
	run bash -c '
		source "$1/scripts/egress-smoke.sh"
		f="$(_write_filter)"
		stat -c "%a" "$f"
		rm -f "$f"
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "644" ]
}
