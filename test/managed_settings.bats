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
# Also checks dev* — "dev" is a protected branch; a hypothetical
# "Bash(git branch *-D* dev*)" would false-block "develop" ops.
@test "10-git-safety: no B9/B4 git branch/push pattern uses raw name* substring form (R4)" {
    local found
    found="$(jq '[.permissions.deny[] |
        select(startswith("Bash(git branch") or startswith("Bash(git push")) |
        select(
            (. | test("main\\*")) or
            (. | test("master\\*")) or
            (. | test("develop\\*")) or
            (. | test("dev\\*")) or
            (. | test("staging\\*")) or
            (. | test("production\\*")) or
            (. | test("prod\\*")) or
            (. | test("release\\*"))
        )
    ] | length' "$GIT_SAFETY_FILE")"
    [ "$found" -eq 0 ]
}

# ── A-T9b (R4 — FP regression): fix/main-bug is NOT blocked by main substring ─
# Spec R4 scenario: a branch operation targeting "fix/main-bug" must not be
# blocked because the protected name "main" appears as a substring of the branch.
# This is structural: all B9/B4 entries use "space + name + (space|EOL)" form,
# never a raw "name*" trailing wildcard. The structural A-T9 test above guarantees
# no such pattern exists; this test documents the behavioral consequence explicitly.
@test "10-git-safety: fix/main-bug branch name does not match any deny entry as a substring (R4-scenario)" {
    # No deny entry in git-safety should use a form that would catch "fix/main-bug"
    # when Claude Code evaluates a branch command targeting that name.
    # Structural check: no entry contains "main" followed immediately by "*" (no space).
    local found
    found="$(jq '[.permissions.deny[] |
        select(startswith("Bash(git branch") or startswith("Bash(git push")) |
        select(test("main\\*"))
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

# ── slice B: os-safety deny drop-in (30-os-safety.json) ─────────────────────
#
# ── B-VERIFY-1: redirect operator does NOT split commands ────────────────────
# Verified 2026-05-18 from primary source:
#   https://docs.anthropic.com/en/docs/claude-code/permissions
#
# Key quote from the "Compound commands" section (section heading:
# "Compound commands", level 4, slug "compound-commands"):
#
#   "Claude Code is aware of shell operators, so a rule like Bash(safe-cmd *)
#    won't give it permission to run the command safe-cmd && other-cmd. The
#    recognized command separators are &&, ||, ;, |, |&, &, and newlines. A rule
#    must match each subcommand independently."
#
# CONCLUSION (ADR-4 C15/C21 CONFIRMED):
#   The redirect operator > is NOT in the recognized command separator list.
#   Therefore > does NOT split a command for deny matching purposes.
#   Bash(* > /dev/sd*) and Bash(* > /etc/passwd) are matched as single strings.
#   C15 (redirect to block device) and C21 (redirect to system files) entries
#   are VALID as designed in ADR-4. Implementation proceeds.

OS_SAFETY_FILE="$DRYDOCK_HOME/templates/managed-settings.d/30-os-safety.json"

# ── B-T1 (R1, R6): 30-os-safety.json exists and is valid JSON ───────────────
@test "30-os-safety: file exists and is valid JSON (B-T1)" {
    [ -f "$OS_SAFETY_FILE" ]
    jq . "$OS_SAFETY_FILE" >/dev/null
}

# ── B-T2 (R1): C1 rm system paths ───────────────────────────────────────────
# Path set is the UNION of spec §R1 and design ADR-4 — superset of both.
# Original source hook coverage: / /etc /usr /var /boot /opt /lib /lib32 /lib64
#   /sbin /bin /sys /proc /dev /root /home  (plus design additions /var /root /home).
@test "30-os-safety: C1 rm root and system paths present — full union set (B-T2)" {
    local failures=0
    # The one root entry
    jq -e '.permissions.deny | map(select(. == "Bash(rm *-r* /)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: Bash(rm *-r* /)"; failures=$((failures+1)); }
    # 15 paths × 3 forms each (exact dir, subpath /path/*, trailing arg /path *)
    # Union of spec §R1 and design ADR-4: /etc /usr /bin /sbin /lib /lib32 /lib64
    # /var /boot /opt /sys /proc /dev /root /home
    local paths=("/etc" "/usr" "/bin" "/sbin" "/lib" "/lib32" "/lib64" "/var" "/boot" "/opt" "/sys" "/proc" "/dev" "/root" "/home")
    for path in "${paths[@]}"; do
        local exact="Bash(rm *-r* ${path})"
        local subpath="Bash(rm *-r* ${path}/*)"
        local trailing="Bash(rm *-r* ${path} *)"
        jq -e --arg p "$exact" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $exact"; failures=$((failures+1)); }
        jq -e --arg p "$subpath" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $subpath"; failures=$((failures+1)); }
        jq -e --arg p "$trailing" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $trailing"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── B-T3 (R1): C2 find / -delete, C6 wipefs, C11 crontab -r ─────────────────
@test "30-os-safety: C2 find -delete, C6 wipefs, C11 crontab -r present (B-T3)" {
    jq -e '.permissions.deny | map(select(. == "Bash(find / *-delete*)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null
    jq -e '.permissions.deny | map(select(. == "Bash(wipefs -a*)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null
    jq -e '.permissions.deny | map(select(. == "Bash(wipefs --all*)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null
    jq -e '.permissions.deny | map(select(. == "Bash(crontab -r*)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null
}

# ── B-T4 (R1): C3 dd × 6 devices, C4 mkfs × 4, C5 partition tools × 5 ──────
@test "30-os-safety: C3 dd block device, C4 mkfs, C5 partition tools present (B-T4)" {
    local failures=0
    # C3: dd of=/dev/<prefix>
    local dd_devs=("sd" "nvme" "hd" "vd" "mmcblk" "loop")
    for dev in "${dd_devs[@]}"; do
        local p="Bash(dd *of=/dev/${dev}*)"
        jq -e --arg p "$p" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $p"; failures=$((failures+1)); }
    done
    # C4: mkfs × 4 block device prefixes (sd, nvme, hd, vd)
    local mkfs_devs=("sd" "nvme" "hd" "vd")
    for dev in "${mkfs_devs[@]}"; do
        local p="Bash(mkfs*/dev/${dev}*)"
        jq -e --arg p "$p" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $p"; failures=$((failures+1)); }
    done
    # C5: partition tools × 5
    local part_tools=("fdisk" "parted" "sfdisk" "cfdisk" "gdisk")
    for tool in "${part_tools[@]}"; do
        local p="Bash(${tool} /dev/*)"
        jq -e --arg p "$p" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $p"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── B-T5 (R1): C7 minimal sudo set ──────────────────────────────────────────
@test "30-os-safety: C7 minimal sudo deny set present (B-T5)" {
    local failures=0
    local sudo_cmds=("rm" "dd" "mkfs*" "shutdown*" "reboot*" "halt*" "poweroff*")
    for cmd in "${sudo_cmds[@]}"; do
        local p="Bash(sudo ${cmd} *)"
        jq -e --arg p "$p" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $p"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── B-T6 (R1): C8 package managers, C9 kernel modules, C10 firewall flush ───
@test "30-os-safety: C8 package manager purges, C9 rmmod, C10 firewall flush present (B-T6)" {
    local failures=0
    # C8: 8 package manager entries
    local pkg_entries=(
        "Bash(apt purge*)"
        "Bash(apt-get purge*)"
        "Bash(apt autoremove*)"
        "Bash(apt-get autoremove*)"
        "Bash(dnf remove*)"
        "Bash(yum remove*)"
        "Bash(pacman -R*)"
        "Bash(brew uninstall --force*)"
    )
    for entry in "${pkg_entries[@]}"; do
        jq -e --arg p "$entry" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $entry"; failures=$((failures+1)); }
    done
    # C9: kernel module unload
    jq -e '.permissions.deny | map(select(. == "Bash(rmmod*)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: Bash(rmmod*)"; failures=$((failures+1)); }
    jq -e '.permissions.deny | map(select(. == "Bash(modprobe -r*)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: Bash(modprobe -r*)"; failures=$((failures+1)); }
    # C10: firewall flush (6 entries)
    local fw_entries=(
        "Bash(iptables -F*)"
        "Bash(ip6tables -F*)"
        "Bash(ufw disable*)"
        "Bash(ufw reset*)"
        "Bash(nft flush ruleset*)"
        "Bash(firewall-cmd --remove-all*)"
    )
    for entry in "${fw_entries[@]}"; do
        jq -e --arg p "$entry" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $entry"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── B-T7 (R1): C13 docker prune, C16 PID-1, C15 redirect to block device ────
@test "30-os-safety: C13 docker prune, C16 kill -9 1, C15 redirect to block device present (B-T7)" {
    local failures=0
    # C13: docker prune (4 entries)
    local prune_entries=(
        "Bash(docker system prune -a*)"
        "Bash(docker system prune --all*)"
        "Bash(docker volume prune*)"
        "Bash(docker volume rm *)"
    )
    for entry in "${prune_entries[@]}"; do
        jq -e --arg p "$entry" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $entry"; failures=$((failures+1)); }
    done
    # C16: PID-1 word-boundary pair (kill -9 1 and kill -9 1 * — not kill -9 100)
    jq -e '.permissions.deny | map(select(. == "Bash(kill -9 1)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: Bash(kill -9 1)"; failures=$((failures+1)); }
    jq -e '.permissions.deny | map(select(. == "Bash(kill -9 1 *)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: Bash(kill -9 1 *)"; failures=$((failures+1)); }
    # C15: redirect to block device (6 device prefixes) — B-VERIFY-1 confirmed > does not split
    local block_devs=("sd" "nvme" "hd" "vd" "mmcblk" "loop")
    for dev in "${block_devs[@]}"; do
        local p="Bash(* > /dev/${dev}*)"
        jq -e --arg p "$p" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $p"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── B-T8 (R1): C21 redirect/tee to critical /etc files ──────────────────────
@test "30-os-safety: C21 redirect and tee to critical /etc files present (B-T8)" {
    local failures=0
    local sys_files=("passwd" "shadow" "sudoers" "fstab")
    for f in "${sys_files[@]}"; do
        # redirect form
        local redirect="Bash(* > /etc/${f})"
        jq -e --arg p "$redirect" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $redirect"; failures=$((failures+1)); }
        # tee form
        local tee_p="Bash(tee */etc/${f}*)"
        jq -e --arg p "$tee_p" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $tee_p"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── B-T9 (R1): docker host-escape deny ───────────────────────────────────────
@test "30-os-safety: docker host-escape deny patterns present (B-T9)" {
    jq -e '.permissions.deny | map(select(. == "Bash(docker run *--privileged*)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null
    jq -e '.permissions.deny | map(select(. == "Bash(docker run *-v /:*)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null
    jq -e '.permissions.deny | map(select(. == "Bash(docker run *--volume /:*)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null
}

# ── B-T10 (R1): total deny count floor ──────────────────────────────────────
# Original: C1(28) + C2(1) + C3(6) + C4(4) + C5(5) + C6(2) + C7(7) + C8(8) + C9(2) +
#   C10(6) + C11(1) + C13(4) + C15(6) + C16(2) + C21(8) + docker-escape(3) = 93
# W1 remediation adds 6 paths × 3 forms = 18 new C1 entries → total ≥ 111
# FIX-R2-1 adds 15 paths × 3 forms + 1 root = 46 new *-R* C1 entries
# FIX-R2-2 adds 4 bare sudo entries
# New floor: 111 + 46 + 4 = 161
@test "30-os-safety: deny array total count is at least 155 (B-T10)" {
    local count
    count="$(jq '.permissions.deny | length' "$OS_SAFETY_FILE")"
    [ "$count" -ge 155 ]
}

# ── B-T12 (FIX-R2-1): *-R* uppercase-recursive entries are present ───────────
# Each system path that has *-r* entries must also have *-R* entries.
@test "30-os-safety: *-R* uppercase-recursive entries present for system paths (B-T12)" {
    local failures=0
    jq -e '.permissions.deny | map(select(. == "Bash(rm *-R* /)")) | length >= 1' \
        "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: Bash(rm *-R* /)"; failures=$((failures+1)); }
    local paths=("/etc" "/usr" "/bin" "/sbin" "/lib" "/lib32" "/lib64" "/var" "/boot" "/opt" "/sys" "/proc" "/dev" "/root" "/home")
    for path in "${paths[@]}"; do
        local exact="Bash(rm *-R* ${path})"
        local subpath="Bash(rm *-R* ${path}/*)"
        local trailing="Bash(rm *-R* ${path} *)"
        jq -e --arg p "$exact" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $exact"; failures=$((failures+1)); }
        jq -e --arg p "$subpath" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $subpath"; failures=$((failures+1)); }
        jq -e --arg p "$trailing" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $trailing"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── B-T13 (FIX-R2-2): bare no-arg sudo forms are present ────────────────────
# sudo reboot, sudo halt, sudo poweroff, sudo shutdown without arguments must
# also be denied. The existing *-with-args* entries require a trailing space+arg.
@test "30-os-safety: bare no-arg sudo deny entries present for shutdown commands (B-T13)" {
    local failures=0
    local bare_sudo_entries=(
        "Bash(sudo reboot)"
        "Bash(sudo halt)"
        "Bash(sudo poweroff)"
        "Bash(sudo shutdown)"
    )
    for entry in "${bare_sudo_entries[@]}"; do
        jq -e --arg p "$entry" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$OS_SAFETY_FILE" >/dev/null || { echo "MISSING: $entry"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── slice C: hook wiring and PreToolUse drop-in (40-guardrails-hook.json) ────
#
# ── C-VERIFY-1 result documented here ────────────────────────────────────────
# See test/block_destructive.bats header for full verification record.
# Short form: matcher "Bash" is confirmed correct for PreToolUse entries.
#
GUARDRAILS_HOOK_FILE="$DRYDOCK_HOME/templates/managed-settings.d/40-guardrails-hook.json"
GUARDRAILS_SCRIPT="$DRYDOCK_HOME/templates/hooks/drydock-block-destructive.sh"

# ── C-T1 (R6): 40-guardrails-hook.json exists and is valid JSON ──────────────
@test "40-guardrails-hook: file exists and is valid JSON (C-T1)" {
    [ -f "$GUARDRAILS_HOOK_FILE" ]
    jq . "$GUARDRAILS_HOOK_FILE" >/dev/null
}

# ── C-T2 (R6, ADR-8): declares hooks.PreToolUse with matcher "Bash" ──────────
@test "40-guardrails-hook: PreToolUse entry with matcher Bash is present (C-T2)" {
    local matcher
    matcher="$(jq -r '(.hooks.PreToolUse // [])[] | select(.matcher == "Bash") | .matcher' \
        "$GUARDRAILS_HOOK_FILE" 2>/dev/null | head -1)"
    [ "$matcher" = "Bash" ]
}

# ── C-T3 (R6, ADR-8): command references drydock-block-destructive.sh ────────
@test "40-guardrails-hook: command references drydock-block-destructive.sh (C-T3)" {
    local cmd
    cmd="$(jq -r '(.hooks.PreToolUse // [])[] | select(.matcher == "Bash") | .hooks[]? | select(.type=="command") | .command' \
        "$GUARDRAILS_HOOK_FILE" 2>/dev/null)"
    [[ "$cmd" == *"drydock-block-destructive.sh"* ]]
}

# ── C-T4 (R6, ADR-8): command uses guard wrapper (not bare path) ─────────────
@test "40-guardrails-hook: command uses sh -c guard wrapper (C-T4)" {
    local cmd
    cmd="$(jq -r '(.hooks.PreToolUse // [])[] | select(.matcher == "Bash") | .hooks[]? | select(.type=="command") | .command' \
        "$GUARDRAILS_HOOK_FILE" 2>/dev/null)"
    [[ "$cmd" == "sh -c"* ]]
}

# ── C-T5 (R6): hook script exists at templates/hooks/ ────────────────────────
@test "drydock-block-destructive.sh: hook script exists at templates/hooks/ (C-T5)" {
    [ -f "$GUARDRAILS_SCRIPT" ]
}

# ── C-T6 (R6): hook script is executable ─────────────────────────────────────
@test "drydock-block-destructive.sh: hook script is executable (C-T6)" {
    [ -x "$GUARDRAILS_SCRIPT" ]
}

# ── C-T7 (R6): 40-guardrails-hook.json passes A-3 (all JSON valid) ───────────
# This is covered by the existing A-3 test which loops all JSON files.
# Separate explicit assertion for the specific file:
@test "40-guardrails-hook: file is valid JSON (covered by A-3, explicit here) (C-T7)" {
    jq . "$GUARDRAILS_HOOK_FILE" >/dev/null
}

# ── B-T11 (R5 — allowlist regression): no scope-creep patterns ───────────────
# Assert no entry would false-block common legitimate operations.
# Strategy: assert no deny entry contains these specific safe operation strings
# as literal substrings (guards against accidentally broad patterns).
@test "30-os-safety: no pattern false-blocks rm node_modules, rm dist, or docker compose down (R5, B-T11)" {
    # Safe patterns that MUST NOT appear literally in any deny entry:
    # These are structural checks — we assert none of the deny entries contain
    # substrings that would represent overly-broad patterns catching these safe ops.
    local dangerous_patterns=(
        "rm *-r* node"
        "rm *-r* dist"
        "compose down"
    )
    local failures=0
    for pat in "${dangerous_patterns[@]}"; do
        local found
        found="$(jq --arg p "$pat" \
            '[.permissions.deny[] | select(. | contains($p))] | length' \
            "$OS_SAFETY_FILE")"
        [ "$found" -eq 0 ] || { echo "SCOPE CREEP: deny entry contains '$pat'"; failures=$((failures+1)); }
    done
    [ "$failures" -eq 0 ]
}

# ── T18-RED: INV-1 deny-rule rewrite — credential rules use //**/ root anchor ──
# Design §5, D8, ADR-3: credential paths (ssh/aws/gnupg/kube/docker/credentials)
# must use //**/<path> so they match at ANY mount depth, not just under $HOME.
# drydock-state paths (.config/drydock) MUST keep __HOME__ anchor.

SECRETS_FILE="$DRYDOCK_HOME/templates/managed-settings.d/00-secrets.json"

@test "00-secrets: Read(//**/.ssh/**) present (credential root-anchor)" {
    jq -e '.permissions.deny | map(select(. == "Read(//**/.ssh/**)")) | length >= 1' \
        "$SECRETS_FILE" >/dev/null
}

@test "00-secrets: Read(//**/.aws/**) present (credential root-anchor)" {
    jq -e '.permissions.deny | map(select(. == "Read(//**/.aws/**)")) | length >= 1' \
        "$SECRETS_FILE" >/dev/null
}

@test "00-secrets: Read(//**/.gnupg/**) present (credential root-anchor)" {
    jq -e '.permissions.deny | map(select(. == "Read(//**/.gnupg/**)")) | length >= 1' \
        "$SECRETS_FILE" >/dev/null
}

@test "00-secrets: Read(//**/.kube/**) present (credential root-anchor)" {
    jq -e '.permissions.deny | map(select(. == "Read(//**/.kube/**)")) | length >= 1' \
        "$SECRETS_FILE" >/dev/null
}

@test "00-secrets: Read(//**/.docker/config.json) present (credential root-anchor)" {
    jq -e '.permissions.deny | map(select(. == "Read(//**/.docker/config.json)")) | length >= 1' \
        "$SECRETS_FILE" >/dev/null
}

@test "00-secrets: Read(//**/.claude/.credentials.json) present (credential root-anchor)" {
    jq -e '.permissions.deny | map(select(. == "Read(//**/.claude/.credentials.json)")) | length >= 1' \
        "$SECRETS_FILE" >/dev/null
}

@test "00-secrets: Read(//**/.claude-container*/.credentials.json) present (covers literal AND per-session disc dirs)" {
    # Glob '.claude-container*' matches both '.claude-container/' (legacy single
    # session) and '.claude-container-<disc>/' (per-session, concurrent-sessions
    # in v0.2.0+). Single rule, full coverage — no gap for per-session dirs.
    jq -e '.permissions.deny | map(select(. == "Read(//**/.claude-container*/.credentials.json)")) | length >= 1' \
        "$SECRETS_FILE" >/dev/null
}

@test "00-secrets: Edit and Write rules for credential dirs use //**/ root-anchor" {
    for verb in "Edit" "Write"; do
        for dir in ".ssh" ".aws" ".gnupg" ".kube"; do
            jq -e --arg rule "${verb}(//**/${dir}/**)" \
                '.permissions.deny | map(select(. == $rule)) | length >= 1' \
                "$SECRETS_FILE" >/dev/null
        done
    done
}

@test "00-secrets: Edit and Write rules for credential FILE paths use //**/ root-anchor" {
    # Symmetric with the directory-glob test above. Credential FILE paths cover:
    #   .docker/config.json                   — Docker registry creds
    #   .claude/.credentials.json             — Claude Code's own OAuth token
    #   .claude-container*/.credentials.json  — drydock per-session OAuth tokens
    # All three need R/E/W coverage: Read prevents exfiltration, Edit/Write
    # prevent accidental overwrite/corruption (threat model A, INV-7).
    for verb in "Edit" "Write"; do
        for path in ".docker/config.json" ".claude/.credentials.json" ".claude-container*/.credentials.json"; do
            jq -e --arg rule "${verb}(//**/${path})" \
                '.permissions.deny | map(select(. == $rule)) | length >= 1' \
                "$SECRETS_FILE" >/dev/null
        done
    done
}

@test "00-secrets: drydock-state rules keep __HOME__ anchor (NOT root-anchored)" {
    # .config/drydock Read/Edit/Write must still use __HOME__
    for verb in "Read" "Edit" "Write"; do
        jq -e --arg rule "${verb}(__HOME__/.config/drydock/**)" \
            '.permissions.deny | map(select(. == $rule)) | length >= 1' \
            "$SECRETS_FILE" >/dev/null
    done
}

@test "00-secrets: no __HOME__ anchor in credential rules (only state rules use __HOME__)" {
    # The credential rules (ssh, aws, gnupg, kube, docker, credentials) MUST NOT
    # have __HOME__ anchor. Only .config/drydock rules use __HOME__.
    local home_cred_rules
    home_cred_rules="$(jq '[.permissions.deny[] | select(
        (contains("__HOME__") and contains(".config/drydock") | not) and
        contains("__HOME__")
    )] | length' "$SECRETS_FILE")"
    [ "$home_cred_rules" -eq 0 ]
}

@test "00-secrets: SCOPE GUARD — no .env rule in deny list" {
    local env_rules
    env_rules="$(jq '[.permissions.deny[] | select(test("\\.(env)\"?$|/\\.env"))] | length' "$SECRETS_FILE")"
    [ "$env_rules" -eq 0 ]
}

# ── T19: INV-1 runtime integration — //**/ rules baked into the running image ───
#
# These tests require a built drydock:latest image. They are gated by
# DRYDOCK_INTEGRATION=1 and skip cleanly in unit mode (CI stays green without it).
#
# Scope: verify that the DEPLOYED managed-settings file at
#   /etc/claude-code/managed-settings.d/00-secrets.json
# inside the container contains the //**/-anchored credential deny rules.
# This is drydock's contract (INV-3 tamper-proof bake step), NOT a test of
# Claude Code's permission engine (which requires external auth and is upstream).
#
# T19-A covers the four symmetric DIRECTORY globs (.ssh/.aws/.gnupg/.kube) R/E/W.
# T19-B covers the three single-FILE credential paths R/E/W (closed in v0.2.0):
#   .docker/config.json, .claude/.credentials.json, .claude-container*/.credentials.json.
# The earlier Read-only asymmetry on .docker/config.json and .credentials.json
# was closed alongside the link-sibling-projects deny-rule rewrite (the per-session
# .claude-container-<disc>/.credentials.json gap also fixed via the '*' glob).

@test "00-secrets: //**/ root-anchored R/E/W rules baked into running image (integration)" {
    [[ "${DRYDOCK_INTEGRATION:-}" == "1" ]] \
        || skip "requires DRYDOCK_INTEGRATION=1 + built drydock:latest"

    run docker run --rm drydock:latest \
        cat /etc/claude-code/managed-settings.d/00-secrets.json
    [ "$status" -eq 0 ]

    local deployed_json="$output"

    # Four symmetric dirs: Read, Edit, Write must all use //**/ anchor
    for verb in "Read" "Edit" "Write"; do
        for dir in ".ssh" ".aws" ".gnupg" ".kube"; do
            local rule="${verb}(//**/${dir}/**)"
            echo "$deployed_json" | jq -e --arg r "$rule" \
                '.permissions.deny | map(select(. == $r)) | length >= 1' \
                >/dev/null \
                || { echo "MISSING in deployed image: $rule"; return 1; }
        done
    done
}

@test "00-secrets: //**/ credential FILE-path R/E/W rules baked into running image (integration)" {
    [[ "${DRYDOCK_INTEGRATION:-}" == "1" ]] \
        || skip "requires DRYDOCK_INTEGRATION=1 + built drydock:latest"

    run docker run --rm drydock:latest \
        cat /etc/claude-code/managed-settings.d/00-secrets.json
    [ "$status" -eq 0 ]

    local deployed_json="$output"

    # Symmetric R/E/W coverage for all three single-file credential paths.
    for verb in "Read" "Edit" "Write"; do
        for path in ".docker/config.json" ".claude/.credentials.json" ".claude-container*/.credentials.json"; do
            local rule="${verb}(//**/${path})"
            echo "$deployed_json" | jq -e --arg r "$rule" \
                '.permissions.deny | map(select(. == $r)) | length >= 1' \
                >/dev/null \
                || { echo "MISSING in deployed image: $rule"; return 1; }
        done
    done
}

# T19-C: Bash() deny rules for the per-sibling keys directory in the running
# image. Mirrors T19-A/T19-B: gated by DRYDOCK_INTEGRATION=1 and a built
# drydock:latest image. Honest-but-toothless without rebuild + integration
# flag — the value is regression catch when someone runs the integration
# suite, not local CI coverage. Unit-side equivalent is the JD1-C test
# (template form, runs always).
#
# Crucial difference vs T19-A: the source template uses __HOME__ as a
# placeholder, which the Dockerfile substitutes to the container's actual
# $HOME at image-build time (see Dockerfile sed). The literal-equality
# style of T19-A would silently always fail here. We resolve $HOME inside
# the container first, then build literal expected patterns.

@test "00-secrets: Bash deny rules for keys dir baked into running image (integration)" {
    [[ "${DRYDOCK_INTEGRATION:-}" == "1" ]] \
        || skip "requires DRYDOCK_INTEGRATION=1 + built drydock:latest"

    # Resolve the actual $HOME inside the container — the template's
    # __HOME__ placeholder is substituted at image-build time.
    run docker run --rm drydock:latest sh -c 'printf %s "$HOME"'
    [ "$status" -eq 0 ]
    local container_home="$output"
    [ -n "$container_home" ]

    run docker run --rm drydock:latest \
        cat /etc/claude-code/managed-settings.d/00-secrets.json
    [ "$status" -eq 0 ]

    local deployed_json="$output"

    # Each Bash deny entry takes the form:
    #   Bash(<cmd> *<container_home>/.config/drydock/keys/*)
    # The 10 commands below mirror the JD1-C unit test iteration list:
    # cat/less/more/head/tail/od/xxd/strings (Round 1 fix-pass) + bat/rg
    # (Round 2 + Round 3 fix-passes — both mandated by drydock's global
    # tool convention).
    for cmd in cat less more head tail od xxd strings bat rg; do
        local rule="Bash($cmd *${container_home}/.config/drydock/keys/*)"
        echo "$deployed_json" | jq -e --arg r "$rule" \
            '.permissions.deny | map(select(. == $r)) | length >= 1' \
            >/dev/null \
            || { echo "MISSING in deployed image: $rule"; return 1; }
    done
}

# ── JD1-C-RED: Bash deny coverage for keys dir ────────────────────────────────
#
# Glob convention. The `Bash(<cmd> *<path>*)` form uses Claude Code's
# argv-glob — `*` matches any substring within the assembled command-line
# string. This is intentionally distinct from the `Read/Edit/Write(<path>)`
# form, which uses a path-glob where `**` is the recursive wildcard. Every
# Bash deny entry across `templates/managed-settings.d/` (00-secrets.json,
# 10-git-safety.json, 30-os-safety.json) uses single `*`; `**` never
# appears inside a `Bash(...)` pattern because the two languages are not
# interchangeable. Judges in JD Round 2 flagged the asymmetry as a
# readability concern — kept as-is because the convention is consistent
# and the alternative (`**` in Bash patterns) would be a semantic error.

@test "JD1-C: 00-secrets template contains Bash deny entries for keys dir read commands" {
    local secrets_file="$DRYDOCK_HOME/templates/managed-settings.d/00-secrets.json"
    [ -f "$secrets_file" ]

    # Each of these Bash commands must be covered by a deny rule targeting
    # __HOME__/.config/drydock/keys/*. The pattern form matches existing entries:
    # Bash(<cmd> *__HOME__/.config/drydock/keys/*)
    #
    # JD2-AB: bat and rg are mandated by drydock's global agent convention
    # ("Use bat/rg/fd/sd/eza instead of cat/grep/find/sed/ls"); failing to
    # cover them leaves the normal-tool-usage hole the agent is most likely
    # to hit. rg can dump arbitrary file content via `rg . <file>`.
    for cmd in cat less more head tail od xxd strings bat rg; do
        local pattern="Bash($cmd *__HOME__/.config/drydock/keys/*)"
        jq -e --arg p "$pattern" \
            '.permissions.deny | map(select(. == $p)) | length >= 1' \
            "$secrets_file" >/dev/null \
            || { echo "MISSING deny rule: $pattern"; return 1; }
    done
}
