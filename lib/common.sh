#!/usr/bin/env bash
# lib/common.sh — output helpers and version constant
#
# Sourced by bin/drydock (the thin dispatcher). Never sourced directly by
# lib/*.sh siblings — let the dispatcher control the source order.

# ── Version ───────────────────────────────────────────────────────────────────
# shellcheck disable=SC2034  # used in lib/commands.sh (usage, cmd_status)
DRYDOCK_VERSION="0.3.0"

# ── Output helpers ────────────────────────────────────────────────────────────
err() {
	printf '\033[31merror:\033[0m %s\n' "$*" >&2
	exit 1
}
warn() { printf '\033[33mwarn:\033[0m  %s\n' "$*" >&2; }
note() { printf '\033[36m• \033[0m%s\n' "$*"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
