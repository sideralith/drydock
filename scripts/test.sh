#!/usr/bin/env bash
# scripts/test.sh — run the drydock bats suite, including from inside a
# drydock container.
#
# Two container-only quirks this wrapper papers over (issue #3):
#   1. The hardening overlay (INV-8) mounts /tmp as a noexec tmpfs. bats writes
#      stub executables into its run-tmpdir under $TMPDIR; on a noexec mount
#      they fail with "Permission denied" and ~20 tests break. We probe $TMPDIR
#      and, if it rejects execution, redirect bats to an exec-allowed path
#      under $HOME — without weakening the /tmp hardening.
#   2. The base image ships no `bats` binary. When `bats` is not on PATH we
#      fall back to `npx --yes bats`.
#
# On a normal host (writable, exec-allowed /tmp; bats installed) this wrapper
# is transparent — it runs `bats test/` exactly as before.
#
# Usage: scripts/test.sh [bats-args...]   (defaults to `test/`)
set -euo pipefail

cd "$(dirname "$0")/.."

# Can an executable file created in $1 actually be run from there?
dir_allows_exec() {
	local dir=$1 probe
	probe=$(mktemp "$dir/.drydock-exec-probe.XXXXXX" 2>/dev/null) || return 1
	printf '#!/bin/sh\n' >"$probe"
	if chmod +x "$probe" 2>/dev/null && "$probe" >/dev/null 2>&1; then
		rm -f "$probe"
		return 0
	fi
	rm -f "$probe"
	return 1
}

tmpdir=${TMPDIR:-/tmp}
if ! dir_allows_exec "$tmpdir"; then
	# $HOME is writable and exec-allowed inside the container; ~/.cache is not
	# (it is created root-owned during the image build), so redirect straight
	# into $HOME rather than under ~/.cache.
	exec_tmp="${HOME:?HOME must be set to redirect a noexec TMPDIR}/.bats-tmp"
	mkdir -p "$exec_tmp"
	if ! dir_allows_exec "$exec_tmp"; then
		echo "scripts/test.sh: no exec-allowed tmpdir found (tried '$tmpdir' and '$exec_tmp')" >&2
		exit 1
	fi
	echo "scripts/test.sh: '$tmpdir' is noexec — redirecting bats TMPDIR to '$exec_tmp'" >&2
	export TMPDIR=$exec_tmp
fi

# Default to the whole suite; allow callers to pass specific files or flags.
if [ "$#" -eq 0 ]; then
	set -- test/
fi

if command -v bats >/dev/null 2>&1; then
	exec bats "$@"
fi

echo "scripts/test.sh: 'bats' not on PATH — falling back to 'npx --yes bats'" >&2
exec npx --yes bats "$@"
