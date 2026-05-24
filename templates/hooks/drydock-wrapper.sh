#!/usr/bin/env bash
# drydock-wrapper.sh — Container PID 1 wrapper for Zellij session persistence.
#
# Installs SIG_IGN for SIGHUP on PID 1 (this script). Zellij runs as a child
# process inside its own pseudo-TTY (via `script -qec`), so a terminal close
# (SIGHUP to the container's PID 1) does not kill the session. The Zellij
# server process manages the session independently of the client.
#
# Wrapper stays as PID 1 and waits on the `script` child; the container exits
# when Zellij kills its own session (via zellij kill-session drydock), which
# terminates the `script` child and causes `wait` to return.
#
# Nested-Zellij stealth mode (REQ-16 / REQ-17, design D-22):
#   DRYDOCK_NESTED_ZELLIJ=1           → load /etc/drydock/zellij-nested.kdl
#   DRYDOCK_FORCE_INNER_ZELLIJ_FULL=1 → bypass stealth even when nested flag is set
#
# SEAM: image-baked at /opt/drydock/hooks/ (needed by `docker run` empirical gate).

set -euo pipefail

# PID 1 ignores SIGHUP — terminal close does not kill the container.
trap '' HUP

if [ "${DRYDOCK_NESTED_ZELLIJ:-0}" = "1" ] && [ "${DRYDOCK_FORCE_INNER_ZELLIJ_FULL:-0}" != "1" ]; then
	_ZELLIJ_CONFIG="--config /etc/drydock/zellij-nested.kdl"
else
	_ZELLIJ_CONFIG=""
fi

# Layout path — DRYDOCK_ZELLIJ_LAYOUT_OVERRIDE is a test seam for the empirical gate
# (drydock run always leaves this unset, using the image-baked default).
_LAYOUT="${DRYDOCK_ZELLIJ_LAYOUT_OVERRIDE:-/etc/drydock/layouts/drydock.kdl}"

# Start Zellij inside its own pseudo-TTY (via `script`) so Zellij's client can
# acquire a terminal without needing PID 1 to be the terminal owner.
# shellcheck disable=SC2086
script -qec "zellij ${_ZELLIJ_CONFIG} --session drydock --new-session-with-layout ${_LAYOUT}" /dev/null &
_ZPID=$!

# Wait for the script child — returns when Zellij session ends (D assertion).
wait "$_ZPID"
