#!/usr/bin/env bash
# install.sh — drydock installer
# Usage: curl -fsSL https://raw.githubusercontent.com/sideralith/drydock/main/install.sh | bash
#        or: git clone … && cd drydock && ./install.sh
#
# Env overrides:
#   DRYDOCK_INSTALL_DIR  — install directory          (default: ~/.local/share/drydock)
#   DRYDOCK_BIN_DIR      — symlink destination dir    (default: ~/.local/bin)
#   DRYDOCK_BRANCH       — branch to clone            (default: main)
#   DRYDOCK_REPO_URL     — git remote URL             (default: https://github.com/sideralith/drydock.git)

set -euo pipefail

# ── Env-var defaults ──────────────────────────────────────────────────────────

DRYDOCK_INSTALL_DIR="${DRYDOCK_INSTALL_DIR:-$HOME/.local/share/drydock}"
DRYDOCK_BIN_DIR="${DRYDOCK_BIN_DIR:-$HOME/.local/bin}"
DRYDOCK_BRANCH="${DRYDOCK_BRANCH:-main}"
DRYDOCK_REPO_URL="${DRYDOCK_REPO_URL:-https://github.com/sideralith/drydock.git}"

# ── TTY detection ─────────────────────────────────────────────────────────────

IS_TTY=0
[ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ] && IS_TTY=1

# ── Interactivity seams ───────────────────────────────────────────────────────
# DRYDOCK_INTERACTIVE: 1 when stdin+stdout are both TTYs; 0 otherwise.
# Distinct from IS_TTY (color-only, stdout-only). Set to 0 in tests or
# pipe installs (curl | bash) to suppress all prompts.
: "${DRYDOCK_INTERACTIVE:=$([ -t 0 ] && [ -t 1 ] && printf 1 || printf 0)}"
# UNAME / OSRELEASE_FILE: OS-detection seams (same pattern as lib/paths.sh:20-21)
: "${UNAME:=uname}"
: "${OSRELEASE_FILE:=/proc/sys/kernel/osrelease}"
# _DRYDOCK_TTY: input source seam; default /dev/tty

# ── ANSI palette (mirrors lib/common.sh:12-18) ────────────────────────────────

_RED='\033[31m'
_GREEN='\033[32m'
_YELLOW='\033[33m'
_CYAN='\033[36m'
_DIM='\033[2m'
_RST='\033[0m'

# ── Output helpers ────────────────────────────────────────────────────────────

print_header() {
	if [ "$IS_TTY" = "1" ]; then
		printf '┌─ drydock ──────────────────────────┐\n'
		printf '│ Defense-in-depth Claude sandbox    │\n'
		printf '└────────────────────────────────────┘\n'
	else
		printf 'drydock installer\n'
	fi
	printf '\n'
}

step_ok() { [ "$IS_TTY" = "1" ] && printf '  %b✓%b  %s\n' "$_GREEN" "$_RST" "$1" || printf '[OK] %s\n' "$1"; }
step_miss() { [ "$IS_TTY" = "1" ] && printf '  %b✗%b  %s\n' "$_RED" "$_RST" "$1" || printf '[MISS] %s\n' "$1"; }
step_warn() { [ "$IS_TTY" = "1" ] && printf '  %bwarn:%b  %s\n' "$_YELLOW" "$_RST" "$1" >&2 || printf '[WARN] %s\n' "$1" >&2; }
hint() { [ "$IS_TTY" = "1" ] && printf '  %b%s%b\n' "$_DIM" "$1" "$_RST" || printf '  %s\n' "$1"; }
info() { [ "$IS_TTY" = "1" ] && printf '  %b•%b  %s\n' "$_CYAN" "$_RST" "$1" || printf '%s\n' "$1"; }

step_fail() {
	[ "$IS_TTY" = "1" ] &&
		printf '%berror:%b %s\n' "$_RED" "$_RST" "$1" >&2 ||
		printf 'error: %s\n' "$1" >&2
	exit 1
}

print_next_steps() {
	if [ "$IS_TTY" = "1" ]; then
		printf '\n  next steps:\n\n    drydock build                   # ~5 min, first time\n    cd <project> && drydock init .  # per-project setup\n    cd <project> && drydock         # launch claude, sandboxed\n\n'
	else
		printf '\nnext steps:\n  drydock build                   (5 min first time)\n  cd <project> && drydock init .  (per-project setup)\n  cd <project> && drydock         (launch claude, sandboxed)\n\n'
	fi
}

# ── Prereq check (buffered — bash-3.2-safe scalar sets) ──────────────────────

_po1=0 _pv1="" _po2=0 _pv2="" _po3=0 _pv3="" _po4=0 _pv4=""

check_prereqs() {
	if command -v docker >/dev/null 2>&1; then
		_po1=1
		_pv1="$(docker --version 2>/dev/null | head -1 || printf 'docker')"
	fi
	if docker compose version >/dev/null 2>&1; then
		_po2=1
		_pv2="$(docker compose version 2>/dev/null | head -1)"
	fi
	if command -v git >/dev/null 2>&1; then
		_po3=1
		_pv3="$(git --version 2>/dev/null | head -1 || printf 'git')"
	fi
	if command -v jq >/dev/null 2>&1; then
		_po4=1
		_pv4="$(jq --version 2>/dev/null | head -1 || printf 'jq')"
	fi

	local _miss=""
	[ "$_po1" = "0" ] && _miss="$_miss docker"
	[ "$_po2" = "0" ] && _miss="$_miss compose"
	[ "$_po3" = "0" ] && _miss="$_miss git"
	[ "$_po4" = "0" ] && _miss="$_miss jq"

	if [ -z "$_miss" ]; then
		# Happy path: single aggregate line (abbreviate versions)
		local _v1 _v2 _v3 _v4
		_v1="$(printf '%s' "$_pv1" | sed 's/Docker version //' | cut -d'.' -f1,2)"
		_v2="$(printf '%s' "$_pv2" | sed 's/.*version //' | cut -d'.' -f1,2)"
		_v3="$(printf '%s' "$_pv3" | sed 's/git version //' | cut -d'.' -f1,2)"
		_v4="$(printf '%s' "$_pv4" | sed 's/jq-//' | cut -d'.' -f1,2)"
		step_ok "Prereqs (docker ${_v1:-?}, compose ${_v2:-?}, git ${_v3:-?}, jq ${_v4:-?})"
		return
	fi

	# Failure path: per-tool lines then abort
	local _abbrev
	if [ "$_po1" = "1" ]; then
		_abbrev="$(printf '%s' "$_pv1" | sed 's/Docker version //' | cut -d'.' -f1,2)"
		step_ok "docker ${_abbrev:-?}"
	else step_miss "docker — not found"; fi
	if [ "$_po2" = "1" ]; then
		_abbrev="$(printf '%s' "$_pv2" | sed 's/.*version //' | cut -d'.' -f1,2)"
		step_ok "compose ${_abbrev:-?}"
	else step_miss "compose v2 — not found"; fi
	if [ "$_po3" = "1" ]; then
		_abbrev="$(printf '%s' "$_pv3" | sed 's/git version //' | cut -d'.' -f1,2)"
		step_ok "git ${_abbrev:-?}"
	else step_miss "git — not found"; fi
	if [ "$_po4" = "1" ]; then
		_abbrev="$(printf '%s' "$_pv4" | sed 's/jq-//' | cut -d'.' -f1,2)"
		step_ok "jq ${_abbrev:-?}"
	else step_miss "jq — not found"; fi
	printf '\n' >&2
	if [ "$IS_TTY" = "1" ]; then
		printf '%berror:%b missing prerequisite(s):%s\n' "$_RED" "$_RST" "$_miss" >&2
	else
		printf 'error: missing prerequisite(s):%s\n' "$_miss" >&2
	fi
	printf '\n' >&2
	for _t in $_miss; do
		case "$_t" in
		docker) printf '  install on Linux:   sudo apt-get install docker.io\n  install on macOS:   brew install --cask docker\n' >&2 ;;
		compose) printf '  install on Linux:   sudo apt-get install docker-compose-plugin\n  install on macOS:   (bundled with Docker Desktop)\n' >&2 ;;
		git) printf '  install on Linux:   sudo apt-get install git\n  install on macOS:   brew install git\n' >&2 ;;
		jq) printf '  install on Linux:   sudo apt-get install jq\n  install on macOS:   brew install jq\n' >&2 ;;
		esac
	done
	printf '\n  re-run install.sh after installing.\n' >&2
	exit 1
}

check_docker_sock() {
	if ! { [ -S /var/run/docker.sock ] || [ -S "$HOME/.docker/run/docker.sock" ]; }; then
		step_warn "Docker daemon socket not found — start Docker before running drydock"
	fi
}

# ── Mode detection (LOCAL_MODE via positive identity) ─────────────────────────

_src="${BASH_SOURCE[0]:-}"
if [ -n "$_src" ] && [ "$_src" != "bash" ]; then
	while [ -L "$_src" ]; do
		_dir="$(cd -P "$(dirname "$_src")" >/dev/null 2>&1 && pwd)"
		_src="$(readlink "$_src")"
		case "$_src" in
		/*) ;;
		*) _src="$_dir/$_src" ;;
		esac
	done
	SCRIPT_DIR="$(cd -P "$(dirname "$_src")" >/dev/null 2>&1 && pwd)"
else
	SCRIPT_DIR=""
fi

LOCAL_MODE=0
if [ -n "$SCRIPT_DIR" ] &&
	[ -f "$SCRIPT_DIR/bin/drydock" ] &&
	[ -f "$SCRIPT_DIR/lib/common.sh" ]; then
	LOCAL_MODE=1
	DRYDOCK_INSTALL_DIR="$SCRIPT_DIR"
fi

# ── Clone or skip ─────────────────────────────────────────────────────────────

do_clone() {
	if [ "$LOCAL_MODE" = "1" ]; then
		info "Installing from local clone at $DRYDOCK_INSTALL_DIR"
		step_ok "Local clone — skipping git clone"
		return
	fi
	if [ -d "$DRYDOCK_INSTALL_DIR/.git" ]; then
		step_ok "Found existing clone at $DRYDOCK_INSTALL_DIR — skipping clone"
		return
	fi
	info "Cloning sideralith/drydock@${DRYDOCK_BRANCH} → $DRYDOCK_INSTALL_DIR"
	mkdir -p "$(dirname "$DRYDOCK_INSTALL_DIR")"
	git clone --depth=1 --branch "$DRYDOCK_BRANCH" "$DRYDOCK_REPO_URL" "$DRYDOCK_INSTALL_DIR"
	step_ok "Cloned sideralith/drydock@${DRYDOCK_BRANCH} → $DRYDOCK_INSTALL_DIR"
}

# ── Symlink creation (7-row conflict matrix) ──────────────────────────────────

do_symlink() {
	local _target="$DRYDOCK_INSTALL_DIR/bin/drydock"
	local _link="$DRYDOCK_BIN_DIR/drydock"
	mkdir -p "$DRYDOCK_BIN_DIR"

	if [ -L "$_link" ]; then
		local _cur
		_cur="$(readlink "$_link")"
		if [ "$_cur" = "$_target" ]; then
			step_ok "Symlink already current → $_link"
			return
		fi
		if [ "$IS_TTY" = "1" ]; then
			printf '%berror:%b symlink conflict at %s\n' "$_RED" "$_RST" "$_link" >&2
		else
			printf 'error: symlink conflict at %s\n' "$_link" >&2
		fi
		printf '  existing: %s → %s\n' "$_link" "$_cur" >&2
		printf '  expected: %s → %s\n' "$_link" "$_target" >&2
		printf '\n  Remove the existing symlink or set DRYDOCK_BIN_DIR to a different directory.\n' >&2
		exit 1
	elif [ -d "$_link" ]; then
		step_fail "directory exists at $_link — manual cleanup needed"
	elif [ -e "$_link" ]; then
		step_fail "regular file exists at $_link — manual cleanup needed"
	else
		ln -s "$_target" "$_link"
		step_ok "Symlinked → $_link"
	fi
}

# ── Interactive helpers ───────────────────────────────────────────────────────

# ask(prompt, default) — prompt → stderr; read from ${_DRYDOCK_TTY:-/dev/tty}.
# Returns resolved 'y' or 'n'. Empty input → default. Missing TTY → default.
# Safe under set -e: exec 3< failure is guarded; never aborts.
ask() {
	[ "$DRYDOCK_INTERACTIVE" = "1" ] || { printf '%s' "$2"; return 0; }
	if ! exec 3<"${_DRYDOCK_TTY:-/dev/tty}" 2>/dev/null; then
		printf '%s' "$2"; return 0
	fi
	local _ans=""
	printf '%s [%s] ' "$1" "$2" >&2
	read -r _ans <&3 || true
	exec 3<&-
	case "${_ans:-$2}" in [Yy]*) printf y ;; [Nn]*) printf n ;; *) printf '%s' "$2" ;; esac
}

# _host_shared_safe — returns 0 (true) when native Linux with reliable fcntl locks;
# returns 1 (false) on macOS or WSL2 where engram shared mode is unsafe.
# Mirrors lib/paths.sh:host_fs_locks_unreliable (lines 78-83).
# install.sh ships standalone (curl|bash) and cannot source lib/paths.sh —
# this block is an INTENTIONAL duplicate. Keep in sync; grep "paths.sh".
_host_shared_safe() {
	[ "$("$UNAME" -s)" = "Darwin" ] && return 1
	[ -r "$OSRELEASE_FILE" ] && grep -qi microsoft "$OSRELEASE_FILE" && return 1
	return 0
}

# ask_engram_mode — on native Linux: prompt to enable shared engram mode (INV-5).
# WSL2 and macOS: silently skip (unsafe fcntl locks). Non-interactive: skip.
ask_engram_mode() {
	[ "$DRYDOCK_INTERACTIVE" = "1" ] || return 0
	_host_shared_safe || return 0

	local _ans
	_ans="$(ask "Share engram DB with host session (native Linux only)? (INV-5)" n)"
	if [ "$_ans" = "y" ]; then
		mkdir -p "$HOME/.config/drydock"
		touch "$HOME/.config/drydock/engram-shared"
	fi
}

# ── PATH check + hint ─────────────────────────────────────────────────────────

check_path() {
	case ":${PATH}:" in
	*":${DRYDOCK_BIN_DIR}:"*) ;;
	*)
		step_warn "$DRYDOCK_BIN_DIR is not in PATH"
		hint "Add to ~/.bashrc:  export PATH=\"\$HOME/.local/bin:\$PATH\""
		hint "Add to ~/.zshrc:   export PATH=\"\$HOME/.local/bin:\$PATH\""
		;;
	esac
}

# ── Main ──────────────────────────────────────────────────────────────────────

print_header
check_prereqs
check_docker_sock
ask_engram_mode
do_clone
do_symlink
step_ok "Ready"
check_path
print_next_steps
