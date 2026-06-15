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

# ── network lifecycle (C2: smoke must not poison the prod fixed-name nets) ────
#
# The production compose stack owns drydock_internal / drydock_egress: networks
# pre-created by `docker network create` lack the com.docker.compose.network
# label and make every subsequent contained `docker compose up` fail fatally
# ("incorrect label ... set to ''"). The smoke run must therefore remove exactly
# the networks IT created — and never touch pre-existing ones.

# _docker_stub_prelude <log> <network-inspect-rc>
# Emits a `docker` shell-function stub (functions win over PATH lookup) that
# logs every call and answers: image inspect → ok, network inspect → $2
# (0 = network pre-exists, 1 = absent), leftover-container inspect → absent.
_docker_stub_prelude() {
	cat <<STUB
docker() {
	echo "docker \$*" >>'$1'
	case "\$1 \${2:-}" in
	"network inspect") return $2 ;;
	"inspect \$SMOKE_CONTAINER") return 1 ;;
	esac
	return 0
}
STUB
}

@test "_check_preconditions: tracks the networks it creates" {
	local log="$BATS_TEST_TMPDIR/docker-c2-track.log"
	: >"$log"
	run bash -c '
		source "$1/scripts/egress-smoke.sh"
		eval "$2"
		_check_preconditions >/dev/null
		printf "%s\n" "${SMOKE_CREATED_NETWORKS[@]}"
	' -- "$DRYDOCK_HOME" "$(_docker_stub_prelude "$log" 1)"
	[ "$status" -eq 0 ]
	[[ "$output" == *"drydock_internal"* ]]
	[[ "$output" == *"drydock_egress"* ]]
	grep -q '^docker network create --internal drydock_internal$' "$log"
	grep -q '^docker network create drydock_egress$' "$log"
}

@test "_cleanup: removes exactly the networks the smoke run created" {
	local log="$BATS_TEST_TMPDIR/docker-c2-rm.log"
	: >"$log"
	run bash -c '
		source "$1/scripts/egress-smoke.sh"
		eval "$2"
		SMOKE_CREATED_NETWORKS=(drydock_internal drydock_egress)
		_cleanup >/dev/null
	' -- "$DRYDOCK_HOME" "$(_docker_stub_prelude "$log" 1)"
	[ "$status" -eq 0 ]
	grep -q '^docker network rm drydock_internal$' "$log"
	grep -q '^docker network rm drydock_egress$' "$log"
}

@test "_cleanup: pre-existing networks are NOT removed" {
	local log="$BATS_TEST_TMPDIR/docker-c2-preexist.log"
	: >"$log"
	run bash -c '
		source "$1/scripts/egress-smoke.sh"
		eval "$2"
		_check_preconditions >/dev/null
		_cleanup >/dev/null
	' -- "$DRYDOCK_HOME" "$(_docker_stub_prelude "$log" 0)"
	[ "$status" -eq 0 ]
	# Networks pre-existed (inspect rc=0): none created, none removed.
	# run + status check: a bare mid-test `! cmd` is exempt from bats errexit
	# and can never fail.
	run grep 'network create' "$log"
	[ "$status" -ne 0 ]
	run grep 'network rm' "$log"
	[ "$status" -ne 0 ]
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
