#!/usr/bin/env bash
# scripts/egress-capture.sh — G1 egress-baseline empirical capture harness.
#
# Subcommand-style script.  Source-guard: only dispatch when executed directly.
# Pure helper functions (_extract_connect_hosts, _to_ere_baseline_pattern) are
# defined at top level so bats tests can source this and exercise them.
#
# NOT for CI.  Requires a running drydock contained-mode session with a live
# drydock-egress sidecar.  See docs/troubleshooting.md "contained mode".

set -euo pipefail

# ── Pure parsing helpers (unit-tested via test/egress_gate.bats) ──────────────

# _extract_connect_hosts — reads tinyproxy LogLevel Connect output on stdin,
# writes one unique requested hostname per line (sorted) to stdout.
#
# Handles two tinyproxy line forms:
#   Request: CONNECT   ... Request (...): CONNECT <host>:<port> HTTP/1.1
#   Fallback: CONNECT   ... Connect (...): <host> [<ip>]
#
# Both forms are extracted and merged; sort -u provides the dedup.  The union
# naturally handles "prefer Request" — if both forms appear for the same host,
# the host appears once in output.
#
# IMPORTANT: The log format is derived from tinyproxy ~1.11 on Debian 12.
# Confirm it matches real output on first `collect` run by inspecting the raw
# log saved to ~/.config/drydock/egress-capture-raw.log.  The bats unit tests
# validate parser internal consistency, NOT real tinyproxy format.
_extract_connect_hosts() {
	grep -E '(CONNECT [^ ]+ HTTP|Connect \(file descriptor)' |
		sed -E \
			-e 's/.*CONNECT ([^ :]+):[0-9]+ HTTP.*/\1/' \
			-e 's/.*Connect \(file descriptor [0-9]+\): ([^ ]+) .*/\1/' |
		grep -v ' ' |
		sort -u ||
		true
}

# _to_ere_baseline_pattern — reads hostnames on stdin, writes anchored ERE
# patterns to stdout (^host\.with\.escaped\.dots$), one per input line.
_to_ere_baseline_pattern() {
	sed -E 's/\./\\./g; s/^/^/; s/$/$/'
}

# ── Internal helpers ──────────────────────────────────────────────────────────

_drydock_cfg_dir() {
	printf '%s/.config/drydock' "${HOME}"
}

_allowlist_path() {
	printf '%s/egress-allowlist' "$(_drydock_cfg_dir)"
}

_allowlist_backup_path() {
	printf '%s/egress-allowlist.capture-bak' "$(_drydock_cfg_dir)"
}

_raw_log_path() {
	printf '%s/egress-capture-raw.log' "$(_drydock_cfg_dir)"
}

_hosts_path() {
	printf '%s/egress-capture-hosts.txt' "$(_drydock_cfg_dir)"
}

# Resolve the templates directory relative to THIS script (not cwd).
_templates_dir() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	printf '%s/../templates' "$script_dir"
}

_baseline_path() {
	printf '%s/egress-baseline.conf' "$(_templates_dir)"
}

# ── Subcommand implementations ────────────────────────────────────────────────

_cmd_enable() {
	local allowlist backup marker_comment allow_all_line

	allowlist="$(_allowlist_path)"
	backup="$(_allowlist_backup_path)"
	marker_comment='# drydock egress capture — REMOVE via egress-capture.sh disable'
	allow_all_line='.*'

	mkdir -p "$(_drydock_cfg_dir)"

	# Refuse double-enable to avoid clobbering a real backup.
	if [ -f "$backup" ]; then
		echo "egress-capture enable: backup already exists at $backup" >&2
		echo "A capture session may already be active.  Run 'disable' first, or remove the backup manually." >&2
		exit 1
	fi

	# Back up current allowlist (or create an empty placeholder).
	if [ -f "$allowlist" ]; then
		cp "$allowlist" "$backup"
		echo "Backed up $allowlist → $backup"
	else
		touch "$allowlist"
		touch "$backup"
		echo "No existing allowlist; created empty placeholder at $backup"
	fi

	# Check if the allow-all entry is already present (exact-line match: -x avoids a
	# false positive against a legitimate user pattern that merely contains '.*').
	if grep -qxF "$allow_all_line" "$allowlist" 2>/dev/null; then
		echo "Allow-all entry already present in $allowlist — nothing appended."
	else
		{
			printf '\n%s\n%s\n' "$marker_comment" "$allow_all_line"
		} >>"$allowlist"
		echo "Appended allow-all entry to $allowlist"
	fi

	cat <<'EOF'

Capture mode is ACTIVE.  Now run your representative sessions:

  1. Start a fresh drydock contained-mode session (drydock run <project>).
  2. Exercise the agent: fresh login, token auth, plugin install, git push, gh op.
  3. When done, run:  egress-capture.sh collect

IMPORTANT: After collect, run disable to restore the original allowlist.
EOF
}

_cmd_collect() {
	local raw_log hosts_file container total

	raw_log="$(_raw_log_path)"
	hosts_file="$(_hosts_path)"

	mkdir -p "$(_drydock_cfg_dir)"
	touch "$raw_log"
	touch "$hosts_file"

	echo "Scanning for running egress sidecars..."

	# Find containers whose names match *-egress
	while IFS= read -r container; do
		[ -z "$container" ] && continue
		echo "  Collecting logs from: $container"
		# Append raw logs (stderr too — tinyproxy logs to stderr)
		docker logs "$container" >>"$raw_log" 2>&1 || {
			echo "  Warning: could not get logs from $container" >&2
		}
	done < <(docker ps -a --format '{{.Names}}' --filter name=-egress 2>/dev/null || true)

	# Parse accumulated raw log → extract unique hosts → merge with existing list
	if [ -s "$raw_log" ]; then
		_extract_connect_hosts <"$raw_log" | sort -u >"${hosts_file}.new" || true
		# Merge with existing hosts file (union, sorted unique)
		sort -u "$hosts_file" "${hosts_file}.new" >"${hosts_file}.merged" || true
		mv "${hosts_file}.merged" "$hosts_file"
		rm -f "${hosts_file}.new"
		total=$(wc -l <"$hosts_file" | tr -d ' ')
	else
		total=0
	fi

	cat <<EOF

Raw logs saved to:     $raw_log
Accumulated hosts at:  $hosts_file
Unique hosts found:    $total

CONFIRM LOG FORMAT: Inspect $raw_log on your first real run to verify
the tinyproxy CONNECT line format matches the parser expectations.
When done collecting, run:  egress-capture.sh finalize
EOF
}

_cmd_finalize() {
	local hosts_file baseline_path host pattern

	hosts_file="$(_hosts_path)"
	baseline_path="$(_baseline_path)"

	if [ ! -f "$hosts_file" ] || [ ! -s "$hosts_file" ]; then
		echo "No collected hosts found at $hosts_file.  Run 'collect' first." >&2
		exit 1
	fi

	# Load current baseline patterns (strip comments and blanks).
	local baseline_patterns
	baseline_patterns=""
	if [ -f "$baseline_path" ]; then
		baseline_patterns=$(sed 's/#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' "$baseline_path" |
			awk 'NF && !seen[$0]++' || true)
	fi

	echo "# Candidate baseline patterns — paste into templates/egress-baseline.conf"
	echo "# (hosts already covered by the shipped baseline are omitted)"
	echo "#"
	echo "# DESIGN NOTE: Capture with telemetry ON and OFF (DISABLE_TELEMETRY=1 /"
	echo "# DISABLE_ERROR_REPORTING=1 per Claude docs).  Compare both lists and ship"
	echo "# the SMALLER (telemetry-off) set as the baseline.  Telemetry hosts ship"
	echo "# commented-out for opt-in."
	echo "#"
	echo "# REMINDER: Disable capture mode when done:  egress-capture.sh disable"
	echo ""

	local candidates_count=0
	local pattern
	while IFS= read -r host; do
		[ -z "$host" ] && continue
		pattern="$(_to_ere_baseline_pattern <<<"$host")"
		# Skip if already in baseline (exact pattern match)
		if echo "$baseline_patterns" | grep -qxF "$pattern" 2>/dev/null; then
			continue
		fi
		echo "$pattern"
		candidates_count=$((candidates_count + 1))
	done <"$hosts_file"

	echo ""
	echo "# $candidates_count candidate pattern(s) above."
}

_cmd_disable() {
	local allowlist backup marker_comment

	allowlist="$(_allowlist_path)"
	backup="$(_allowlist_backup_path)"
	marker_comment='# drydock egress capture — REMOVE via egress-capture.sh disable'

	if [ -f "$backup" ]; then
		cp "$backup" "$allowlist"
		rm -f "$backup"
		echo "Restored $allowlist from backup; backup removed."
	else
		# No backup: idempotently strip the capture block (the marker comment line
		# and the '.*' line that immediately follows it) with awk for precision.
		if [ -f "$allowlist" ] && grep -qF "$marker_comment" "$allowlist" 2>/dev/null; then
			awk -v marker="$marker_comment" '
				$0 == marker { skip=1; next }
				skip && /^\.\*$/ { skip=0; next }
				{ print }
			' "$allowlist" >"${allowlist}.clean"
			mv "${allowlist}.clean" "$allowlist"
			echo "No backup found; stripped capture marker from $allowlist"
		else
			echo "Capture mode is not active and no backup found — nothing to do."
		fi
	fi
}

_usage() {
	cat <<'EOF'
Usage: egress-capture.sh <subcommand>

Subcommands:
  enable    Back up global allowlist and append allow-all entry for capture.
            Refuses double-enable to protect the real backup.
  collect   Harvest CONNECT logs from running *-egress sidecars and accumulate
            unique hostnames into ~/.config/drydock/egress-capture-hosts.txt.
            Raw logs saved to ~/.config/drydock/egress-capture-raw.log.
  finalize  Print candidate ERE baseline patterns (hosts not already in the
            shipped baseline) for the maintainer to paste into
            templates/egress-baseline.conf.  Does NOT edit the file.
  disable   Restore global allowlist from backup (or strip capture marker).
            Idempotent.
  --help    Show this message.
EOF
}

main() {
	local cmd="${1:-}"
	case "$cmd" in
	enable) _cmd_enable ;;
	collect) _cmd_collect ;;
	finalize) _cmd_finalize ;;
	disable) _cmd_disable ;;
	--help | help | "") _usage ;;
	*)
		printf 'egress-capture.sh: unknown subcommand: %s\n' "$cmd" >&2
		_usage >&2
		exit 1
		;;
	esac
}

# Source-guard: only dispatch when executed directly, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
