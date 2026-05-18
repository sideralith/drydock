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
#
# ── A-VERIFY-1: Claude Code Bash(...) wildcard semantics ─────────────────────
# Verified 2026-05-18 from primary source:
#   https://docs.anthropic.com/en/docs/claude-code/permissions
#
# Key quotes from the "Wildcard patterns" and "Bash" sections:
#
#   "The space before * matters: Bash(ls *) matches ls -la but not lsof,
#    while Bash(ls*) matches both."
#
#   "A single * matches any sequence of characters including spaces, so one
#    wildcard can span multiple arguments."
#
#   "Wildcards can appear at any position in the command, including at the
#    beginning, middle, or end"
#
#   Example given: Bash(git * main) matches "git checkout main" and
#                  "git log --oneline main"
#
# CONCLUSION (ADR-1 CONFIRMED):
#   - Space-before-* = word boundary: prefix must be followed by space or EOS.
#   - No-space-* = substring: prefix can extend into a longer token.
#   - Middle-position * spans multiple arguments (including spaces).
#   - Two-entry pairing strategy (exact + trailing-args) is SOUND:
#       Bash(git branch *--delete* main)   — exact, no trailing args
#       Bash(git branch *--delete* main *) — trailing space+* word boundary
#     The trailing space before * requires "main " + something, so "maintainer"
#     is NOT matched (word boundary holds). This eliminates the FP class the
#     change targets. ADR-1 is validated; implementation proceeds.

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

# ── F-1: ROADMAP entry for managed-settings-layer ────────────────────────────
@test "ROADMAP: v0.2.0 section references managed-settings-layer" {
    grep -q 'managed-settings-layer' "$DRYDOCK_HOME/docs/ROADMAP.md"
}

# ── slice A: git-safety deny-matrix extension (B2, B4-B10) ──────────────────
#
# Protected-branch set per ADR-2 (frozen list of 8):
GIT_SAFETY_FILE="$DRYDOCK_HOME/templates/managed-settings.d/10-git-safety.json"

# ── A-T7 (R7 — GREEN assertion): force-push deny patterns survive extension ──
# Written before other A tests; MUST stay GREEN throughout.
@test "10-git-safety: force-push deny patterns are present (R7)" {
    jq -e '.permissions.deny | map(select(. == "Bash(git push --force*)")) | length >= 1' \
        "$GIT_SAFETY_FILE" >/dev/null
    jq -e '.permissions.deny | map(select(. == "Bash(git push -f*)")) | length >= 1' \
        "$GIT_SAFETY_FILE" >/dev/null
}

# ── A-T8 (R4 — FP regression): no pattern substring-matches --merged flags ──
# Asserts no deny entry contains "--merged" as a plain substring that would
# also false-positive on B9 flag forms.
@test "10-git-safety: no pattern false-positives on --merged/--no-merged/--format flags (R4)" {
    # No deny entry should contain the literal strings --merged or --no-merged
    # or --format embedded inside a pattern that also uses B9-style matchers.
    # Strategy: assert the deny array contains no entry that is a substring of
    # "git branch --merged main" or "git branch --no-merged dev".
    local found
    found="$(jq '[.permissions.deny[] | select(
        (. | contains("--merged")) or
        (. | contains("--no-merged")) or
        (. | contains("--format"))
    )] | length' "$GIT_SAFETY_FILE")"
    [ "$found" -eq 0 ]
}

# ── A-T9 (R4 — FP regression): no B9/B4 pattern uses raw name* substring ───
# Asserts no git branch or git push --delete deny entry uses the substring-match
# form "main*" (no space before *), which would false-block branch names like
# "maintainer" or "main-bug". B10 (gh api *refs/heads/main*) is exempt: the
# trailing * after the ref path is intentional and does not create FP risk
# because no protected branch name appears as a path prefix of another.
@test "10-git-safety: no B9/B4 git branch/push pattern uses raw name* substring form (R4)" {
    local found
    found="$(jq '[.permissions.deny[] |
        select(startswith("Bash(git branch") or startswith("Bash(git push")) |
        select(
            (. | test("main\\*")) or
            (. | test("master\\*")) or
            (. | test("develop\\*")) or
            (. | test("staging\\*")) or
            (. | test("production\\*")) or
            (. | test("prod\\*")) or
            (. | test("release\\*"))
        )
    ] | length' "$GIT_SAFETY_FILE")"
    [ "$found" -eq 0 ]
}

# ── A-T1 (R1): B2 mirror push deny ──────────────────────────────────────────
@test "10-git-safety: B2 mirror push deny pattern is present" {
    jq -e '.permissions.deny | map(select(. == "Bash(git push *--mirror*)")) | length >= 1' \
        "$GIT_SAFETY_FILE" >/dev/null
}

# ── A-T2 (R1): B5 filter-branch and B6 update-ref -d deny ──────────────────
@test "10-git-safety: B5 filter-branch deny pattern is present" {
    jq -e '.permissions.deny | map(select(. == "Bash(git filter-branch*)")) | length >= 1' \
        "$GIT_SAFETY_FILE" >/dev/null
}

@test "10-git-safety: B6 update-ref -d deny pattern is present" {
    jq -e '.permissions.deny | map(select(. == "Bash(git update-ref -d*)")) | length >= 1' \
        "$GIT_SAFETY_FILE" >/dev/null
}

# ── A-T3 (R1): B7 gh repo/B8 gh release deny ────────────────────────────────
@test "10-git-safety: B7 gh repo destructive deny patterns are present" {
    jq -e '.permissions.deny | map(select(. == "Bash(gh repo delete*)")) | length >= 1' \
        "$GIT_SAFETY_FILE" >/dev/null
    jq -e '.permissions.deny | map(select(. == "Bash(gh repo archive*)")) | length >= 1' \
        "$GIT_SAFETY_FILE" >/dev/null
    jq -e '.permissions.deny | map(select(. == "Bash(gh repo transfer*)")) | length >= 1' \
        "$GIT_SAFETY_FILE" >/dev/null
}

@test "10-git-safety: B8 gh release delete deny pattern is present" {
    jq -e '.permissions.deny | map(select(. == "Bash(gh release delete*)")) | length >= 1' \
        "$GIT_SAFETY_FILE" >/dev/null
}

# ── A-T4 (R1): B4 matrix — git push --delete × 8 branches × 2 forms ────────
@test "10-git-safety: B4 push --delete word-boundary pair present for all 8 protected branches" {
    local branches=(main master dev develop staging production prod release)
    local failures=0
    for branch in "${branches[@]}"; do
        # Exact form (no trailing args)
        local exact="Bash(git push *--delete* ${branch})"
        # Trailing-args form (space+* word boundary)
        local trailing="Bash(git push *--delete* ${branch} *)"
        jq -e --arg p "$exact" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$GIT_SAFETY_FILE" >/dev/null || { echo "MISSING: $exact"; failures=$((failures+1)); }
        jq -e --arg p "$trailing" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$GIT_SAFETY_FILE" >/dev/null || { echo "MISSING: $trailing"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── A-T5 (R1): B9 matrix — flag forms × 8 branches × 2 word-boundary forms ─
@test "10-git-safety: B9 branch flag matrix covers all 6 flags × 8 branches × 2 forms" {
    local branches=(main master dev develop staging production prod release)
    local flags=("-D" "-d" "--delete" "-m" "-M" "--move")
    local failures=0
    for flag in "${flags[@]}"; do
        for branch in "${branches[@]}"; do
            # Exact form (no trailing args after branch)
            local exact="Bash(git branch *${flag}* ${branch})"
            # Trailing-args form
            local trailing="Bash(git branch *${flag}* ${branch} *)"
            jq -e --arg p "$exact" \
                '.permissions.deny | map(select(. == $p)) | length >= 1' \
                "$GIT_SAFETY_FILE" >/dev/null || { echo "MISSING: $exact"; failures=$((failures+1)); }
            jq -e --arg p "$trailing" \
                '.permissions.deny | map(select(. == $p)) | length >= 1' \
                "$GIT_SAFETY_FILE" >/dev/null || { echo "MISSING: $trailing"; failures=$((failures+1)); }
        done
    done
    [ "$failures" -eq 0 ]
}

# ── A-T6 (R1): B10 matrix — gh api DELETE refs/heads/<branch> × 8 branches ─
@test "10-git-safety: B10 gh api DELETE refs/heads matrix covers all 8 protected branches" {
    local branches=(main master dev develop staging production prod release)
    local failures=0
    for branch in "${branches[@]}"; do
        local pattern="Bash(gh api *DELETE* *refs/heads/${branch}*)"
        jq -e --arg p "$pattern" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$GIT_SAFETY_FILE" >/dev/null || { echo "MISSING: $pattern"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── A-T10 (R1): total deny count floor ──────────────────────────────────────
# Floor: 11 (existing) + 1(B2) + 16(B4) + 1(B5) + 1(B6) + 3(B7) + 1(B8) + 90(B9 new) + 8(B10)
# = 11 + 1 + 16 + 1 + 1 + 3 + 1 + 90 + 8 = 132
@test "10-git-safety: deny array total count is at least 132 after slice A" {
    local count
    count="$(jq '.permissions.deny | length' "$GIT_SAFETY_FILE")"
    [ "$count" -ge 132 ]
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
