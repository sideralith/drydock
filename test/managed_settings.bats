#!/usr/bin/env bats
# test/managed_settings.bats — unit tests for templates/managed-settings.d/
#
# Verifies the managed-settings drop-in directory structure (A-1..A-6)
# and the Dockerfile bake step (T5, integration-only / skipped in unit mode).
#
# DRYDOCK_CANONICAL_SESSION_HOOK_CMD is the byte-identical command string that
# cmd_init historically stamped into project settings.json files (resolved form).
# Design D3 / spec R-7a require the managed-settings drop-in to carry the same
# string so Claude Code's dedup fires against stale project files.

load "helpers/load"

# Canonical hook command (resolved form — uses /opt/drydock/, no __HOME__).
# Must be byte-identical to:
#   jq -r '.hooks.SessionStart[0].hooks[0].command' templates/default-settings.json
DRYDOCK_CANONICAL_SESSION_HOOK_CMD="sh -c '[ -x /opt/drydock/hooks/drydock-session-start.sh ] && exec /opt/drydock/hooks/drydock-session-start.sh || exit 0'"
export DRYDOCK_CANONICAL_SESSION_HOOK_CMD

# ── A-1: drop-in directory exists ─────────────────────────────────────────
@test "managed-settings: drop-in directory exists in templates/" {
    [ -d "$DRYDOCK_HOME/templates/managed-settings.d" ]
}

# ── A-2: at least one JSON file ───────────────────────────────────────────
@test "managed-settings: drop-in contains at least one JSON file" {
    local count
    count="$(find "$DRYDOCK_HOME/templates/managed-settings.d" -maxdepth 1 -name '*.json' | wc -l)"
    [ "$count" -ge 1 ]
}

# ── A-3: all drop-in JSON files are valid JSON ────────────────────────────
@test "managed-settings: all drop-in JSON files are valid JSON" {
    local failures=0
    for f in "$DRYDOCK_HOME/templates/managed-settings.d/"*.json; do
        jq . "$f" >/dev/null 2>&1 || { failures=$((failures + 1)); echo "INVALID: $f"; }
    done
    [ "$failures" -eq 0 ]
}

# ── A-4: deny array is non-empty across drop-in files ────────────────────
@test "managed-settings: deny array is non-empty across all drop-in files" {
    local total_denys=0
    for f in "$DRYDOCK_HOME/templates/managed-settings.d/"*.json; do
        local count
        count="$(jq '(.permissions.deny // []) | length' "$f")"
        total_denys=$((total_denys + count))
    done
    [ "$total_denys" -gt 0 ]
}

# ── A-5: drop-in includes a hooks.SessionStart entry ─────────────────────
@test "managed-settings: drop-in declares hooks.SessionStart" {
    local found=0
    for f in "$DRYDOCK_HOME/templates/managed-settings.d/"*.json; do
        local count
        count="$(jq '(.hooks.SessionStart // []) | length' "$f")"
        [ "$count" -gt 0 ] && { found=1; break; }
    done
    [ "$found" -eq 1 ]
}

# ── A-6: SessionStart command string byte-identical to canonical baseline ─
@test "managed-settings: SessionStart command string matches resolved canonical baseline" {
    local found=0
    for f in "$DRYDOCK_HOME/templates/managed-settings.d/"*.json; do
        local cmd
        cmd="$(jq -r '(.hooks.SessionStart // [])[] | .hooks[]? | select(.type=="command") | .command' "$f" 2>/dev/null)"
        [ "$cmd" = "$DRYDOCK_CANONICAL_SESSION_HOOK_CMD" ] && { found=1; break; }
    done
    [ "$found" -eq 1 ]
}

# ── T5: Dockerfile bakes managed-settings.d (integration, skipped in unit mode)
@test "managed-settings: Dockerfile bakes managed-settings.d with USER_NAME substituted" {
    skip "requires built drydock image (integration test — set DRYDOCK_INTEGRATION=1 and rebuild to enable)"
    # Confirm __HOME__ is fully resolved and paths use /home/<user>/.ssh, not placeholder.
    run docker run --rm drydock:latest cat /etc/claude-code/managed-settings.d/00-secrets.json
    [ "$status" -eq 0 ]
    [[ "$output" == *"/home/"*"/.ssh"* ]]
    [[ "$output" != *"__HOME__"* ]]
}
