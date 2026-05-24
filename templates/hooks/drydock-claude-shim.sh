#!/usr/bin/env bash
# drydock-claude-shim.sh — In-pane teardown owner.
#
# Runs claude then kills the Zellij session so the container exits cleanly
# when running with --rm. Teardown is owned by this shim (stable
# `zellij kill-session` CLI) rather than by version-varying config keys.
#
# SEAM: image-baked at /opt/drydock/hooks/ (needed by `docker run` empirical gate).

set -euo pipefail

claude "$@" || true
zellij kill-session drydock
