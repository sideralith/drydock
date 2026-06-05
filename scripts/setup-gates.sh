#!/usr/bin/env bash
# scripts/setup-gates.sh — bootstrap and run the v0.4.0 egress-jail release gates
# (G1 empirical capture, G2 runtime double-gate smoke) on a BARE-LINUX host.
#
# Intended for a WSL2 distro running NATIVE Docker Engine (docker-ce), NOT Docker
# Desktop. Docker Desktop's network VM (vpnkit) distorts the reachability gate;
# the deny-by-default BLOCK gates still hold there, the reachability gate may give
# a false negative. Run from anywhere inside the drydock repo:
#
#   ./scripts/setup-gates.sh          # preflight -> build -> G2 smoke -> G1 recipe
#   ./scripts/setup-gates.sh --help
#
# NOT for CI. The pure helper _is_docker_desktop is unit-tested
# (test/setup_gates.bats). G3 (the v0.4.0 release) is a separate maintainer step,
# done only AFTER G1 finalizes the baseline and G2 confirms enforcement.

set -euo pipefail

# ── Pure helper (unit-tested) ─────────────────────────────────────────────────

# _is_docker_desktop <os_string> — return 0 (true) when the `docker info`
# OperatingSystem string indicates Docker Desktop, 1 otherwise.
_is_docker_desktop() {
	case "$1" in
	*"Docker Desktop"*) return 0 ;;
	*) return 1 ;;
	esac
}

# ── Internal helpers ──────────────────────────────────────────────────────────

_repo_root() {
	cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

log() { printf '[setup-gates] %s\n' "$*"; }
warn() { printf '[setup-gates] WARN: %s\n' "$*" >&2; }
die() {
	printf '[setup-gates] FATAL: %s\n' "$*" >&2
	exit 1
}

_docker_server_os() {
	docker info --format '{{.OperatingSystem}}' 2>/dev/null || printf ''
}

# ── Preflight ─────────────────────────────────────────────────────────────────

_preflight() {
	local root os
	root="$(_repo_root)"

	command -v docker >/dev/null 2>&1 ||
		die "docker not found on PATH. Install Docker Engine (docker-ce) first."
	docker info >/dev/null 2>&1 ||
		die "cannot reach the Docker daemon. Start it (e.g. 'sudo service docker start')."
	[ -f "$root/Dockerfile.egress" ] ||
		die "not in the drydock repo (Dockerfile.egress missing under $root)."
	[ -f "$root/scripts/egress-smoke.sh" ] ||
		die "scripts/egress-smoke.sh missing — incomplete checkout?"

	os="$(_docker_server_os)"
	log "Docker daemon OS: ${os:-unknown}"
	if _is_docker_desktop "$os"; then
		warn "This is Docker Desktop. The BLOCK gates (403) are reliable here, but the"
		warn "REACHABILITY gate (api.anthropic.com -> 200) may give a FALSE NEGATIVE due"
		warn "to the Docker Desktop network VM. For canonical results, run this inside a"
		warn "WSL2 distro with NATIVE docker-ce (e.g. a 'debian-gates' distro)."
	else
		log "Native Docker Engine detected — canonical bare-Linux behavior."
	fi
}

# ── Build the sidecar image ───────────────────────────────────────────────────

_build_image() {
	local root
	root="$(_repo_root)"
	log "Building drydock-egress:latest (docker build -f Dockerfile.egress)..."
	docker build -f "$root/Dockerfile.egress" -t drydock-egress:latest "$root"
	log "Image drydock-egress:latest ready."
}

# ── G2 smoke ──────────────────────────────────────────────────────────────────

_run_g2_smoke() {
	local root rc=0
	root="$(_repo_root)"
	log "=== G2: double-gate smoke (scripts/egress-smoke.sh) ==="
	"$root/scripts/egress-smoke.sh" || rc=$?
	if [ "$rc" -eq 0 ]; then
		log "G2: all automated gates PASSED (reachability 200, blocks 403)."
	else
		warn "G2 reported a failure (exit $rc). Read the gate table above:"
		warn "  - GATE 2 + IP-LITERAL MUST be 403 (block). If they are, enforcement works."
		warn "  - GATE 1 (reachability) FAIL on Docker Desktop is likely an env artifact —"
		warn "    re-run on native docker-ce before concluding the code is wrong."
	fi
	return "$rc"
}

# ── G1 recipe (printed, not executed — needs real interactive drydock sessions) ─

_print_g1_recipe() {
	cat <<'RECIPE'

=== G1: empirical baseline capture (guided manual step) ===

G1 needs REAL drydock contained sessions, so it is run by hand. With drydock
installed and the target project as cwd:

  1. Turn capture on (adds a temporary allow-all to the global allowlist;
     backs up your real allowlist first):
       scripts/egress-capture.sh enable

  2. Run representative sessions so every needed host is exercised, e.g.
     a fresh login / token auth, a plugin/marketplace install, a git push,
     a gh operation — each as a normal contained session:
       drydock run <project>

  3. Harvest the CONNECT hostnames from the sidecars' logs:
       scripts/egress-capture.sh collect
     -> Inspect ~/.config/drydock/egress-capture-raw.log ONCE to CONFIRM the
        tinyproxy log line format matches the parser (first real run only).

  4. Print baseline candidates (hosts not already shipped):
       scripts/egress-capture.sh finalize
     -> Paste the candidate lines into templates/egress-baseline.conf. Run the
        capture with telemetry ON and OFF; ship the SMALLER (telemetry-off) set.

  5. Restore your real allowlist (removes the allow-all):
       scripts/egress-capture.sh disable

RECIPE
}

# ── Usage ─────────────────────────────────────────────────────────────────────

_usage() {
	cat <<'EOF'
Usage: setup-gates.sh [--help]

Bootstraps and runs the drydock v0.4.0 egress-jail release gates on a bare-Linux
host (a WSL2 distro with native docker-ce, NOT Docker Desktop):

  1. Preflight  — docker present + reachable, native-vs-Desktop check, repo check.
  2. Build      — docker build -f Dockerfile.egress -t drydock-egress:latest.
  3. G2 smoke   — runs scripts/egress-smoke.sh (reachability 200 + block 403 x2).
  4. G1 recipe  — prints the manual capture steps (needs real drydock sessions).

G3 (the v0.4.0 release) is a separate maintainer step, only after G1/G2 pass.
EOF
}

main() {
	case "${1:-}" in
	--help | -h | help)
		_usage
		return 0
		;;
	"") : ;;
	*) die "unknown argument: $1 (try --help)" ;;
	esac

	log "drydock egress-jail release-gate runner"
	_preflight
	_build_image
	local g2_rc=0
	_run_g2_smoke || g2_rc=$?
	_print_g1_recipe

	echo ""
	if [ "$g2_rc" -eq 0 ]; then
		log "NEXT: complete G1 (above), then G3 (bump DRYDOCK_VERSION, dev->main, gh release create v0.4.0)."
	else
		warn "Resolve the G2 result first (see notes above), then proceed to G1 and G3."
	fi
	return "$g2_rc"
}

# Source-guard: only dispatch when executed directly, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
