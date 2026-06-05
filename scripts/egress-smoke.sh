#!/usr/bin/env bash
# scripts/egress-smoke.sh — G2 egress double-gate smoke test.
#
# Brings up a standalone test sidecar using the production drydock-egress:latest
# image, attaches it to the real drydock_internal / drydock_egress networks,
# then verifies:
#   GATE 1 (reachability): allowlisted host returns non-403 through proxy.
#   GATE 2 (block):        unlisted host returns 403 (proxy refuses).
#   IP-LITERAL:            IP-literal CONNECT returns 403 (no host pattern match).
#
# NOT for CI — requires Docker on the host (Linux / DooD mode), the prod sidecar
# image, and an internet connection.  Run manually before tagging a v0.4.0 release.
#
# Manual checklist (steps that cannot be automated here — require a real drydock run):
#   □ dood mode direct egress: confirm `drydock dood <proj>` session can still reach
#     internet directly (bypasses the proxy entirely; no HTTPS_PROXY set in dood mode).
#   □ SIGHUP-persist: start a contained session, detach (Ctrl-P Ctrl-Q), reattach
#     (`drydock attach <proj>`), verify the egress sidecar is still healthy and
#     proxying correctly (check with `docker logs drydock-<proj>-<disc>-egress`).

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────

SMOKE_CONTAINER='drydock-egress-smoke'
NETWORK_INTERNAL='drydock_internal'
NETWORK_EGRESS='drydock_egress'
SIDECAR_IMAGE='drydock-egress:latest'
PROXY_PORT=8888
HEALTHCHECK_TIMEOUT=30
CURL_IMAGE='curlimages/curl:latest'

# The allowlisted host (must be in templates/egress-baseline.conf).
GATE1_HOST='api.anthropic.com'
# A host NOT in the baseline — proxy should block it.
GATE2_HOST='example.com'
# An IP literal — proxy should block all IP literals (no host pattern match).
GATE3_IP='1.1.1.1'

# ── Script-relative paths ─────────────────────────────────────────────────────

_script_dir() {
	cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

_baseline_path() {
	printf '%s/../templates/egress-baseline.conf' "$(_script_dir)"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { printf '[egress-smoke] %s\n' "$*"; }

die() {
	printf '[egress-smoke] FATAL: %s\n' "$*" >&2
	exit 1
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────

_cleanup() {
	log "Cleaning up smoke sidecar..."
	docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
	# Networks are shared, fixed-name — do NOT remove them.
}

trap _cleanup EXIT

# ── Preconditions ─────────────────────────────────────────────────────────────

_check_preconditions() {
	log "Checking preconditions..."

	# sidecar image
	if ! docker image inspect "$SIDECAR_IMAGE" >/dev/null 2>&1; then
		die "Image $SIDECAR_IMAGE not found.  Run 'drydock build' first."
	fi

	# Create networks if absent (do not fail if they already exist)
	if ! docker network inspect "$NETWORK_INTERNAL" >/dev/null 2>&1; then
		log "Creating network $NETWORK_INTERNAL (internal: true)..."
		docker network create --internal "$NETWORK_INTERNAL"
	fi
	if ! docker network inspect "$NETWORK_EGRESS" >/dev/null 2>&1; then
		log "Creating network $NETWORK_EGRESS..."
		docker network create "$NETWORK_EGRESS"
	fi

	# Remove a leftover smoke container from a previous failed run
	if docker inspect "$SMOKE_CONTAINER" >/dev/null 2>&1; then
		log "Removing leftover smoke container from previous run..."
		docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
	fi
}

# ── Write effective filter (baseline only, comments stripped) ─────────────────

_write_filter() {
	local baseline filter_file
	baseline="$(_baseline_path)"

	# Check the baseline BEFORE mktemp so an absent baseline cannot leak a temp file.
	if [ ! -f "$baseline" ]; then
		die "Baseline file not found at $baseline"
	fi
	filter_file="$(mktemp /tmp/egress-smoke-filter.XXXXXX)"

	sed 's/#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' "$baseline" |
		awk 'NF && !seen[$0]++' \
			>"$filter_file"

	printf '%s' "$filter_file"
}

# ── Sidecar startup ───────────────────────────────────────────────────────────

_start_sidecar() {
	local filter_file="$1"
	log "Starting smoke sidecar ($SMOKE_CONTAINER)..."

	# Mirror the prod sidecar hardening (docker-compose.contain.yml): cap_drop ALL,
	# no-new-privileges, read_only + tmpfs /run + /tmp (tinyproxy writes its PidFile
	# to /tmp). A fidelity gap here would let the smoke pass on a config prod rejects.
	docker run -d \
		--name "$SMOKE_CONTAINER" \
		--network "$NETWORK_EGRESS" \
		--cap-drop ALL \
		--security-opt "no-new-privileges:true" \
		--read-only \
		--tmpfs /run \
		--tmpfs /tmp \
		-v "${filter_file}:/etc/tinyproxy/filter:ro" \
		"$SIDECAR_IMAGE" >/dev/null

	# Connect to internal network so the agent-side curl can reach the proxy
	docker network connect "$NETWORK_INTERNAL" "$SMOKE_CONTAINER"

	log "Waiting for sidecar to become healthy (up to ${HEALTHCHECK_TIMEOUT}s)..."
	local elapsed=0
	while [ "$elapsed" -lt "$HEALTHCHECK_TIMEOUT" ]; do
		if docker exec "$SMOKE_CONTAINER" \
			timeout 1 bash -c "</dev/tcp/127.0.0.1/$PROXY_PORT" 2>/dev/null; then
			log "Sidecar is healthy."
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	die "Sidecar did not become healthy within ${HEALTHCHECK_TIMEOUT}s."
}

# ── Curl probe ────────────────────────────────────────────────────────────────

# _probe_connect_code <host_or_ip>
# Runs a curl CONNECT probe from drydock_internal through the sidecar proxy and
# prints the proxy's CONNECT response code: 200 = tunnel allowed, 403 = proxy
# refused (deny-by-default block). Uses %{http_connect} — NOT %{http_code}, which
# is the code of the tunneled GET and is always 000 when the CONNECT is refused.
# An unreachable proxy yields an empty result, normalized to 000.
_probe_connect_code() {
	local target="$1" out
	out="$(docker run --rm \
		--network "$NETWORK_INTERNAL" \
		"$CURL_IMAGE" \
		curl -sS -o /dev/null \
		-w '%{http_connect}' \
		--max-time 10 \
		-x "http://${SMOKE_CONTAINER}:${PROXY_PORT}" \
		"https://${target}/" \
		2>/dev/null)"
	printf '%s' "${out:-000}"
}

# ── Gate evaluation ───────────────────────────────────────────────────────────

# _gate_expect_allowed <label> <connect_code>
# PASS when the proxy CONNECT code is 200 (tunnel allowed). 403 = proxy refused
# (a real gate-1 failure); 000 = proxy unreachable. %{http_connect}=200 holds
# regardless of what the upstream GET returns, so there is no upstream-403 ambiguity.
_gate_expect_allowed() {
	local label="$1" code="$2"
	if [ "$code" = "200" ]; then
		printf '  %-40s  PASS  (CONNECT %s)\n' "$label" "$code"
		return 0
	fi
	printf '  %-40s  FAIL  (CONNECT %s — expected 200 tunnel-allowed)\n' "$label" "$code"
	return 1
}

# _gate_expect_blocked <label> <connect_code>
# PASS when the proxy CONNECT code is 403 (proxy refused the tunnel).
_gate_expect_blocked() {
	local label="$1" code="$2"
	if [ "$code" = "403" ]; then
		printf '  %-40s  PASS  (CONNECT %s)\n' "$label" "$code"
		return 0
	fi
	printf '  %-40s  FAIL  (CONNECT %s — expected 403 proxy block)\n' "$label" "$code"
	return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
	log "=== drydock egress double-gate smoke (G2) ==="
	log "Image:    $SIDECAR_IMAGE"
	log "Networks: $NETWORK_INTERNAL (internal) / $NETWORK_EGRESS (NAT)"
	log ""

	_check_preconditions

	local filter_file
	filter_file="$(_write_filter)"
	trap 'rm -f "$filter_file"; _cleanup' EXIT

	_start_sidecar "$filter_file"

	log "Running gate probes via $CURL_IMAGE..."
	log "(Note: first run may pull $CURL_IMAGE — that is expected.)"
	log ""

	local code1 code2 code3
	code1="$(_probe_connect_code "$GATE1_HOST")"
	code2="$(_probe_connect_code "$GATE2_HOST")"
	code3="$(_probe_connect_code "$GATE3_IP")"

	local any_fail=0

	echo ""
	echo "┌─────────────────────────────────────────────────────────────────────┐"
	echo "│  Gate results                                                       │"
	echo "├─────────────────────────────────────────────────────────────────────┤"

	_gate_expect_allowed "GATE 1 reachability ($GATE1_HOST)" "$code1" ||
		any_fail=1

	_gate_expect_blocked "GATE 2 block ($GATE2_HOST)" "$code2" ||
		any_fail=1

	_gate_expect_blocked "IP-LITERAL block ($GATE3_IP)" "$code3" ||
		any_fail=1

	echo "└─────────────────────────────────────────────────────────────────────┘"
	echo ""

	cat <<'CHECKLIST'
Manual checklist (cannot be automated here — require a real drydock run):

  □  dood mode direct egress: run 'drydock dood <proj>', confirm the agent
     can reach the internet without a proxy (no HTTPS_PROXY in dood mode).

  □  SIGHUP-persist: start a contained session, detach (Ctrl-P Ctrl-Q),
     reattach ('drydock attach <proj>'), confirm the egress sidecar is still
     healthy ('docker logs drydock-<proj>-<disc>-egress' shows tinyproxy up).

CHECKLIST

	if [ "$any_fail" -eq 0 ]; then
		log "All automated gates PASSED."
		exit 0
	else
		log "One or more gates FAILED — see table above." >&2
		exit 1
	fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
