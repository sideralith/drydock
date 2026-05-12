# test/helpers/load.bash — shared setup for all drydock bats test files
#
# Usage in a .bats file:
#   load "helpers/load"   (from test/ directory)
#   load "../helpers/load" (if .bats is in a subdirectory)

# ── Resolve DRYDOCK_HOME to the repo root ──────────────────────────────────
# BATS_TEST_FILENAME is the absolute path to the .bats file being run.
# From that we walk up to find the repo root (parent of test/).
_helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRYDOCK_HOME="${DRYDOCK_HOME:-$(cd "$_helpers_dir/../.." && pwd)}"
export DRYDOCK_HOME
unset _helpers_dir

# ── Load vendored bats helpers ─────────────────────────────────────────────
# bats-support must be loaded before bats-assert (assert depends on support).
load "$DRYDOCK_HOME/test/test_helper/bats-support/load"
load "$DRYDOCK_HOME/test/test_helper/bats-assert/load"
