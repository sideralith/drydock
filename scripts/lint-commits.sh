#!/usr/bin/env bash
# scripts/lint-commits.sh — lint conventional-commit subjects in a git range.
#
# Usage: scripts/lint-commits.sh [-h|--help] [--base <sha>]
#
# Without --base, auto-detects the base via git merge-base origin/dev HEAD.
# With --base <sha>, uses that exact commit as the range start.
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────

TYPES=(feat fix docs refactor test style chore)

# Build ERE from TYPES array (Bash 4+).
# NOTE: $REGEX must be used UNQUOTED on the RHS of [[ =~ ]] — quoting it
# causes Bash to treat the pattern as a literal string (not a regex).
_types_re="$(
	IFS='|'
	echo "${TYPES[*]}"
)"
REGEX="^(${_types_re})(\([^)]+\))?: .+$"
unset _types_re

# ── Helpers ───────────────────────────────────────────────────────────────────

die() {
	local code=$1
	shift
	printf 'lint-commits: %s\n' "$*" >&2
	exit "$code"
}

usage() {
	cat <<'EOF'
Usage: scripts/lint-commits.sh [-h|--help] [--base <sha>]

Lint conventional-commit subjects for each non-merge commit in <base>..HEAD.

  --base <sha>   Use this commit as the range start instead of auto-detecting.
                 Required in CI; optional locally.

Without --base, the script auto-detects the base via:
  git merge-base origin/dev HEAD

Exit codes: 0 all OK, 1 lint failures, 2 usage error, 3 git state error.
EOF
	exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────

base_arg=""

while [[ $# -gt 0 ]]; do
	case $1 in
	-h | --help)
		usage
		;;
	--base)
		[[ $# -gt 1 ]] || die 2 "--base requires an argument"
		base_arg=$2
		shift 2
		;;
	*)
		die 2 "unknown flag '$1'; use --help for usage"
		;;
	esac
done

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
	local base failures=() checked=0

	# Base resolution (T-25 adds auto-detect).
	if [[ -n ${base_arg:-} ]]; then
		base=$base_arg
		git rev-parse --verify "$base^{commit}" >/dev/null 2>&1 ||
			die 3 "base '$base' is not a valid git commit"
	else
		# Auto-detect: use git merge-base origin/dev HEAD (D-6, D-7).
		if ! git rev-parse --verify origin/dev >/dev/null 2>&1; then
			git fetch origin dev --quiet 2>/dev/null ||
				die 3 "no origin/dev locally and 'git fetch origin dev' failed — pass --base <sha> or fetch manually"
		fi
		base=$(git merge-base origin/dev HEAD) ||
			die 3 "git merge-base origin/dev HEAD failed"
	fi

	# ── Lint loop ──────────────────────────────────────────────────────────────
	# Process substitution keeps $failures array in the parent shell (not a subshell).
	# $REGEX must be unquoted on the RHS of [[ =~ ]] — quoting makes it a literal.

	while IFS= read -r line; do
		[[ -n $line ]] || continue
		local sha subject
		sha=${line%% *}
		subject=${line#* }

		# Belt-and-suspenders: skip rebase-artifact single-parent merge subjects.
		# (Real two-parent merges are excluded via --no-merges in git log.)
		[[ $subject =~ ^Merge[[:space:]] ]] && continue

		# Count only commits that pass the skip filter (rebase artifacts excluded).
		((checked++)) || true

		# Strip trailing whitespace from subject before matching (Decision E).
		subject="${subject%"${subject##*[![:space:]]}"}"

		if ! [[ $subject =~ $REGEX ]]; then
			failures+=("${sha:0:7}"$'\t'"$subject")
		fi
	done < <(git log "$base..HEAD" --no-merges --format='%H %s')

	# ── Report ─────────────────────────────────────────────────────────────────

	local count=${#failures[@]}
	if [[ $count -gt 0 ]]; then
		printf 'lint-commits: %d invalid commit subject(s) found\n\n' "$count" >&2
		local entry
		for entry in "${failures[@]}"; do
			printf '  %s\n' "$entry" >&2
		done
		printf '\nExpected format: type(scope)?: subject\n' >&2
		printf 'Valid types:     %s\n' "${TYPES[*]}" >&2
		printf 'Example:         feat(ci): add commit-message lint job\n\n' >&2
		printf 'Reference: CLAUDE.md §5 (Commit Conventions)\n' >&2
		exit 1
	fi

	printf 'lint-commits: %d commit(s) checked, all OK\n' "$checked"
}

main
