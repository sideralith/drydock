#!/usr/bin/env bats
# test/mounts.bats — is_separate_mount function tests
#
# Spec: Behavior Preservation → Scenario "is_separate_mount against fixture"
# Uses a synthetic MOUNTS_FILE injected via the MOUNTS_FILE seam.

load "helpers/load"

setup() {
  # Source bin/drydock so is_separate_mount is defined in the test shell.
  # shellcheck disable=SC1090
  source "$DRYDOCK_HOME/bin/drydock"

  # Create a real directory that will appear as a mount point in the fixture.
  MOUNTED_DIR="$BATS_TEST_TMPDIR/mounted"
  mkdir -p "$MOUNTED_DIR"

  # Another existing dir that is NOT in the fixture.
  OTHER_DIR="$BATS_TEST_TMPDIR/other"
  mkdir -p "$OTHER_DIR"

  # Synthetic /proc/mounts — second field is the mount point.
  # The mount point path MUST exist on disk (is_separate_mount checks [ -e ]).
  SYNTHETIC_MOUNTS="$BATS_TEST_TMPDIR/proc-mounts"
  cat > "$SYNTHETIC_MOUNTS" <<MOUNTS
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
drvfs $MOUNTED_DIR 9p rw,noatime,uid=1000,gid=1000 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev 0 0
MOUNTS

  export MOUNTS_FILE="$SYNTHETIC_MOUNTS"
}

@test "is_separate_mount: path in fixture returns exit 0" {
  run is_separate_mount "$MOUNTED_DIR"
  [ "$status" -eq 0 ]
}

@test "is_separate_mount: path NOT in fixture returns non-zero" {
  run is_separate_mount "$OTHER_DIR"
  [ "$status" -ne 0 ]
}

@test "is_separate_mount: existing path not in fixture returns non-zero" {
  run is_separate_mount "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
}

@test "is_separate_mount: nonexistent path returns non-zero" {
  run is_separate_mount "/nonexistent/path/that/does/not/exist"
  [ "$status" -ne 0 ]
}

@test "is_separate_mount: different MOUNTS_FILE with no entries returns non-zero" {
  empty_mounts="$BATS_TEST_TMPDIR/empty-mounts"
  cat > "$empty_mounts" <<'MOUNTS'
sysfs /sys sysfs rw 0 0
MOUNTS
  export MOUNTS_FILE="$empty_mounts"
  run is_separate_mount "$MOUNTED_DIR"
  [ "$status" -ne 0 ]
}
