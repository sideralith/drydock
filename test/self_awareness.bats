#!/usr/bin/env bats
# test/self_awareness.bats — subprocess tests for templates/hooks/drydock-session-start.sh
#
# Tests the hook script in isolation via subprocess invocation. Uses two env-var
# seams (design D-5, mirrors lib/paths.sh) to swap in fixtures without bats
# gymnastics:
#   DRYDOCK_RELEASE_FILE — points to a present/absent fixture
#   MOUNTINFO_FILE       — points to a mountinfo-format fixture
#
# All invocations via `run bash <script> …` to test real subprocess behaviour.

load "helpers/load"

# Absolute path to the hook script under test.
HOOK_SCRIPT="$DRYDOCK_HOME/templates/hooks/drydock-session-start.sh"

setup() {
	# A fixture /etc/drydock-release-like file that EXISTS.
	RELEASE_FIXTURE="$BATS_TEST_TMPDIR/drydock-release"
	echo 'drydock' >"$RELEASE_FIXTURE"

	# A mountinfo fixture where /tmp is mounted with noexec.
	MOUNTINFO_NOEXEC="$BATS_TEST_TMPDIR/mountinfo-noexec"
	cat >"$MOUNTINFO_NOEXEC" <<'MOUNTINFO'
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
22 21 0:18 / /sys rw,relatime shared:6 - sysfs sysfs rw
23 21 0:4 / /proc rw,relatime - proc proc rw
30 1 0:24 / /tmp rw,nosuid,nodev,noexec,relatime - tmpfs tmpfs rw
MOUNTINFO

	# A mountinfo fixture where /tmp has NO noexec.
	MOUNTINFO_EXEC="$BATS_TEST_TMPDIR/mountinfo-exec"
	cat >"$MOUNTINFO_EXEC" <<'MOUNTINFO'
24 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw
22 21 0:18 / /sys rw,relatime shared:6 - sysfs sysfs rw
23 21 0:4 / /proc rw,relatime - proc proc rw
30 1 0:24 / /tmp rw,nosuid,nodev,relatime - tmpfs tmpfs rw
MOUNTINFO

	# A minimal PATH with bats absent (keep basic utilities for the hook script).
	PATH_NO_BATS="/usr/bin:/bin"
}

# ── Scenario 2a — host-session guard ─────────────────────────────────────────
# GIVEN /etc/drydock-release is absent
# WHEN  hook is executed
# THEN  exit status is 0 AND stdout is empty

@test "hook: absent release file → exit 0, empty stdout (host-session silence)" {
	local absent_file="$BATS_TEST_TMPDIR/absent-release-does-not-exist"
	[ ! -f "$absent_file" ]
	run env \
		DRYDOCK_RELEASE_FILE="$absent_file" \
		MOUNTINFO_FILE="$MOUNTINFO_EXEC" \
		bash "$HOOK_SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# ── Scenario 2b — marker present → stdout non-empty ─────────────────────────
# GIVEN /etc/drydock-release is present
# WHEN  hook is executed
# THEN  exit status is 0 AND stdout is non-empty

@test "hook: present release file → exit 0, non-empty stdout" {
	run env \
		DRYDOCK_RELEASE_FILE="$RELEASE_FIXTURE" \
		MOUNTINFO_FILE="$MOUNTINFO_EXEC" \
		bash "$HOOK_SCRIPT"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
}

# ── Scenario 3a — INV-6 framing present ──────────────────────────────────────
# GIVEN marker present
# WHEN  hook runs
# THEN  stdout contains "Docker socket"

@test "hook: stdout contains INV-6 Docker socket framing" {
	run env \
		DRYDOCK_RELEASE_FILE="$RELEASE_FIXTURE" \
		MOUNTINFO_FILE="$MOUNTINFO_EXEC" \
		bash "$HOOK_SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Docker socket"* ]]
}

# Also verify the full mandatory INV-6 content-exact fragment (design: content-exact).
@test "hook: stdout contains root-equivalent host access framing (INV-6 exact)" {
	run env \
		DRYDOCK_RELEASE_FILE="$RELEASE_FIXTURE" \
		MOUNTINFO_FILE="$MOUNTINFO_EXEC" \
		bash "$HOOK_SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"root-equivalent host access, not a security sandbox"* ]]
}

# ── Scenario 3b — .ssh and .gnupg not mounted ────────────────────────────────
# GIVEN marker present
# WHEN  hook runs
# THEN  stdout contains ".ssh" and ".gnupg" references

@test "hook: stdout contains .ssh reference (INV-1 framing)" {
	run env \
		DRYDOCK_RELEASE_FILE="$RELEASE_FIXTURE" \
		MOUNTINFO_FILE="$MOUNTINFO_EXEC" \
		bash "$HOOK_SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *".ssh"* ]]
}

@test "hook: stdout contains .gnupg reference (INV-1 framing)" {
	run env \
		DRYDOCK_RELEASE_FILE="$RELEASE_FIXTURE" \
		MOUNTINFO_FILE="$MOUNTINFO_EXEC" \
		bash "$HOOK_SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *".gnupg"* ]]
}

# ── Scenario 3c — XDG_CACHE_HOME workaround ──────────────────────────────────
# GIVEN marker present
# WHEN  hook runs
# THEN  stdout contains "XDG_CACHE_HOME"

@test "hook: stdout contains XDG_CACHE_HOME gh workaround" {
	run env \
		DRYDOCK_RELEASE_FILE="$RELEASE_FIXTURE" \
		MOUNTINFO_FILE="$MOUNTINFO_EXEC" \
		bash "$HOOK_SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"XDG_CACHE_HOME"* ]]
}

# ── Scenario 4a — noexec /tmp detected ───────────────────────────────────────
# GIVEN marker present AND mountinfo fixture has /tmp with noexec
# WHEN  hook runs
# THEN  stdout contains "noexec"

@test "hook: noexec /tmp probe → stdout mentions noexec" {
	run env \
		DRYDOCK_RELEASE_FILE="$RELEASE_FIXTURE" \
		MOUNTINFO_FILE="$MOUNTINFO_NOEXEC" \
		bash "$HOOK_SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"noexec"* ]]
}

# ── Scenario 4b — /tmp NOT noexec → no noexec mention ────────────────────────
# GIVEN marker present AND mountinfo fixture has NO noexec entry for /tmp
# WHEN  hook runs
# THEN  stdout does NOT contain "noexec"

@test "hook: exec /tmp (no noexec flag) → stdout does NOT mention noexec" {
	run env \
		DRYDOCK_RELEASE_FILE="$RELEASE_FIXTURE" \
		MOUNTINFO_FILE="$MOUNTINFO_EXEC" \
		bash "$HOOK_SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" != *"noexec"* ]]
}

# ── Scenario 4c — bats absent from PATH ──────────────────────────────────────
# GIVEN bats absent from PATH AND marker present
# WHEN  hook runs
# THEN  stdout mentions "bats" as unavailable

@test "hook: bats absent from PATH → stdout mentions bats unavailable" {
	run env \
		PATH="$PATH_NO_BATS" \
		DRYDOCK_RELEASE_FILE="$RELEASE_FIXTURE" \
		MOUNTINFO_FILE="$MOUNTINFO_EXEC" \
		bash "$HOOK_SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bats"* ]]
}
