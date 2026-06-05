#!/usr/bin/env bats
# test/egress_gate.bats — unit tests for the G1 egress-capture helper functions
#
# Sources scripts/egress-capture.sh via the source-guard so the pure parsing
# helpers (_extract_connect_hosts, _to_ere_baseline_pattern) can be exercised
# without executing any subcommand logic or side effects.
#
# NOTE: These tests validate internal consistency (parser + fixtures, both
# authored here). They do NOT validate against real tinyproxy output.
# The "confirm log format on first real run" note in collect is the real gate.

load "helpers/load"

setup() {
	# Source the capture script.  The source-guard ensures no main() is called.
	# shellcheck disable=SC1090
	source "$DRYDOCK_HOME/scripts/egress-capture.sh"
}

# ── source-guard: no side effects when sourced ────────────────────────────────

@test "egress-capture: sourcing produces zero output" {
	output="$(source "$DRYDOCK_HOME/scripts/egress-capture.sh" 2>&1)"
	[ -z "$output" ]
}

@test "egress-capture: _extract_connect_hosts is defined after sourcing" {
	declare -f _extract_connect_hosts >/dev/null
}

@test "egress-capture: _to_ere_baseline_pattern is defined after sourcing" {
	declare -f _to_ere_baseline_pattern >/dev/null
}

# ── _extract_connect_hosts ────────────────────────────────────────────────────

@test "_extract_connect_hosts: parses Request CONNECT lines and strips :port" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		_extract_connect_hosts <<'"'"'LOG'"'"'
CONNECT   Mon Jun  5 12:00:00 2026 [1234]: Request (file descriptor 7): CONNECT api.anthropic.com:443 HTTP/1.1
LOG
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "api.anthropic.com" ]
}

@test "_extract_connect_hosts: parses Connect fallback lines and strips [ip]" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		_extract_connect_hosts <<'"'"'LOG'"'"'
CONNECT   Mon Jun  5 12:00:00 2026 [1234]: Connect (file descriptor 7): api.anthropic.com [160.79.104.10]
LOG
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "api.anthropic.com" ]
}

@test "_extract_connect_hosts: deduplicates multiple same-host lines" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		_extract_connect_hosts <<'"'"'LOG'"'"'
CONNECT   Mon Jun  5 12:00:00 2026 [1111]: Request (file descriptor 3): CONNECT api.anthropic.com:443 HTTP/1.1
CONNECT   Mon Jun  5 12:00:01 2026 [1112]: Request (file descriptor 4): CONNECT api.anthropic.com:443 HTTP/1.1
LOG
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "api.anthropic.com" ]
}

@test "_extract_connect_hosts: handles mixed forms and multiple hosts, sorted" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		_extract_connect_hosts <<'"'"'LOG'"'"'
CONNECT   Mon Jun  5 12:00:00 2026 [1234]: Request (file descriptor 7): CONNECT api.anthropic.com:443 HTTP/1.1
CONNECT   Mon Jun  5 12:00:00 2026 [1234]: Connect (file descriptor 7): api.anthropic.com [160.79.104.10]
CONNECT   Mon Jun  5 12:00:01 2026 [1235]: Request (file descriptor 8): CONNECT raw.githubusercontent.com:443 HTTP/1.1
CONNECT   Mon Jun  5 12:00:02 2026 [1236]: Connect (file descriptor 9): objects.githubusercontent.com [185.199.108.133]
LOG
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	# Sorted unique: three distinct hosts
	[ "$(echo "$output" | wc -l)" -eq 3 ]
	echo "$output" | grep -q "^api\.anthropic\.com$"
	echo "$output" | grep -q "^objects\.githubusercontent\.com$"
	echo "$output" | grep -q "^raw\.githubusercontent\.com$"
}

@test "_extract_connect_hosts: ignores non-CONNECT noise lines" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		_extract_connect_hosts <<'"'"'LOG'"'"'
INFO    Mon Jun  5 12:00:00 2026 [1234]: Not a connect line
WARNING Mon Jun  5 12:00:01 2026 [1234]: tinyproxy: something happened
NOTICE  Mon Jun  5 12:00:02 2026 [1234]: tinyproxy started
CONNECT   Mon Jun  5 12:00:03 2026 [1235]: Request (file descriptor 5): CONNECT api.anthropic.com:443 HTTP/1.1
LOG
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "api.anthropic.com" ]
}

@test "_extract_connect_hosts: empty input produces empty output" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		_extract_connect_hosts </dev/null
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "_extract_connect_hosts: Request lines preferred over Connect lines (same host, both present)" {
	# When both forms appear for the same host, the dedup removes duplicates — result is one line
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		_extract_connect_hosts <<'"'"'LOG'"'"'
CONNECT   Mon Jun  5 12:00:00 2026 [1234]: Request (file descriptor 7): CONNECT api.anthropic.com:443 HTTP/1.1
CONNECT   Mon Jun  5 12:00:00 2026 [1234]: Connect (file descriptor 7): api.anthropic.com [160.79.104.10]
LOG
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "api.anthropic.com" ]
}

@test "_extract_connect_hosts: drops a malformed Connect line with no trailing [ip] (no raw leak)" {
	# A Connect line whose host sits at end-of-line (no [ip]) is not transformed by
	# the sed; the ' '-guard must drop it so a raw log line never leaks as a host.
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		_extract_connect_hosts <<'"'"'LOG'"'"'
CONNECT   Mon Jun  5 12:00:00 2026 [1234]: Connect (file descriptor 7): malformed-no-ip
CONNECT   Mon Jun  5 12:00:01 2026 [1235]: Request (file descriptor 8): CONNECT api.anthropic.com:443 HTTP/1.1
LOG
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "api.anthropic.com" ]
}

@test "_extract_connect_hosts: IP-literal CONNECT lines are extracted as-is" {
	# tinyproxy may log IP literals; we extract them — finalize can omit/flag them
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		_extract_connect_hosts <<'"'"'LOG'"'"'
CONNECT   Mon Jun  5 12:00:00 2026 [1234]: Request (file descriptor 7): CONNECT 1.1.1.1:443 HTTP/1.1
LOG
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "1.1.1.1" ]
}

# ── _to_ere_baseline_pattern ──────────────────────────────────────────────────

@test "_to_ere_baseline_pattern: escapes dots and anchors api.anthropic.com" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		echo "api.anthropic.com" | _to_ere_baseline_pattern
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "^api\.anthropic\.com$" ]
}

@test "_to_ere_baseline_pattern: escapes dots and anchors raw.githubusercontent.com" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		echo "raw.githubusercontent.com" | _to_ere_baseline_pattern
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "^raw\.githubusercontent\.com$" ]
}

@test "_to_ere_baseline_pattern: handles multiple hosts from stdin" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		printf "api.anthropic.com\nraw.githubusercontent.com\n" | _to_ere_baseline_pattern
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | wc -l)" -eq 2 ]
	echo "$output" | grep -qF '^api\.anthropic\.com$'
	echo "$output" | grep -qF '^raw\.githubusercontent\.com$'
}

@test "_to_ere_baseline_pattern: empty input produces empty output" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		_to_ere_baseline_pattern </dev/null
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "_to_ere_baseline_pattern: no-dot host is still anchored" {
	run bash -c '
		source "$1/scripts/egress-capture.sh"
		echo "localhost" | _to_ere_baseline_pattern
	' -- "$DRYDOCK_HOME"
	[ "$status" -eq 0 ]
	[ "$output" = "^localhost$" ]
}
