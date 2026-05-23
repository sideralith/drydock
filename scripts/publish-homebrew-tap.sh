#!/usr/bin/env bash
# publish-homebrew-tap.sh — publish drydock as a Homebrew tap.
#
# Run this ON THE HOST after a drydock release tag exists upstream. It:
#   1. Computes the SHA256 of the tagged release tarball from GitHub.
#   2. Substitutes __VERSION__, the url line, and __SHA256_PLACEHOLDER__
#      into the formula template (packaging/homebrew/drydock.rb).
#   3. Creates sideralith/homebrew-tap on GitHub if missing (else updates).
#   4. Pushes Formula/drydock.rb to that repo.
#
# After running, users install with:
#   brew tap sideralith/tap
#   brew install sideralith/tap/drydock
#
# Requirements on the host:
#   - gh CLI authenticated with `repo` scope (verify: gh auth status)
#   - git, curl, sha256sum (Linux) or shasum -a 256 (macOS)
#
# Usage:
#   ./scripts/publish-homebrew-tap.sh                 # use latest tag
#   ./scripts/publish-homebrew-tap.sh v0.2.0          # specific tag
#   ./scripts/publish-homebrew-tap.sh v0.2.0 --dry-run

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
SOURCE_OWNER="sideralith"
SOURCE_REPO="drydock"
TAP_OWNER="sideralith"
# Tap repo follows Homebrew convention: `homebrew-<short-name>`. Users invoke
# it as `<owner>/<short-name>` — i.e. `sideralith/tap`. The intentionally
# generic "tap" short-name lets the same tap host future sideralith formulae
# without forcing a rename (e.g. `brew install sideralith/tap/other-tool`).
TAP_REPO="homebrew-tap"
FORMULA_NAME="drydock"

# ── Locate repo root + formula template ──────────────────────────────────────
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
formula_src="$repo_root/packaging/homebrew/drydock.rb"

[ -f "$formula_src" ] || {
	echo "error: formula not found at $formula_src" >&2
	exit 1
}

# ── Parse args ───────────────────────────────────────────────────────────────
tag=""
dry_run=0
for arg in "$@"; do
	case "$arg" in
	--dry-run) dry_run=1 ;;
	-h | --help)
		sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	v*) tag="$arg" ;;
	*)
		echo "error: unknown argument: $arg" >&2
		exit 1
		;;
	esac
done

# ── Resolve tag (latest if unspecified) ──────────────────────────────────────
if [ -z "$tag" ]; then
	tag="$(gh api "repos/$SOURCE_OWNER/$SOURCE_REPO/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
	[ -n "$tag" ] || {
		echo "error: no release found for $SOURCE_OWNER/$SOURCE_REPO — pass a tag explicitly" >&2
		exit 1
	}
fi
echo "→ Using tag: $tag"

# ── Compute SHA256 of the release tarball ────────────────────────────────────
tarball_url="https://github.com/$SOURCE_OWNER/$SOURCE_REPO/archive/refs/tags/$tag.tar.gz"
echo "→ Fetching $tarball_url"

tmp_tarball="$(mktemp)"
trap 'rm -f "$tmp_tarball"' EXIT
curl -fsSL --output "$tmp_tarball" "$tarball_url" || {
	echo "error: failed to fetch tarball — does tag $tag exist on GitHub?" >&2
	exit 1
}

if command -v sha256sum >/dev/null 2>&1; then
	sha="$(sha256sum "$tmp_tarball" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
	sha="$(shasum -a 256 "$tmp_tarball" | awk '{print $1}')"
else
	echo "error: neither sha256sum nor shasum found on PATH" >&2
	exit 1
fi
echo "→ SHA256: $sha"

# ── Render formula (substitute url + sha) ────────────────────────────────────
tmp_formula="$(mktemp)"
trap 'rm -f "$tmp_tarball" "$tmp_formula"' EXIT

# Substitute the three placeholder fields in the template:
#   __VERSION__         → the resolved tag (e.g. v0.2.1)
#   __SHA256_PLACEHOLDER__ → the SHA256 of the tagged tarball
# The url line is also regex-replaced as a safety net so a maintainer can
# accidentally land a real version in the template without breaking the
# publish (the regex wins over whatever literal is on disk).
sed \
	-e "s|__VERSION__|$tag|g" \
	-e "s|^  url \".*\"\$|  url \"$tarball_url\"|" \
	-e "s|__SHA256_PLACEHOLDER__|$sha|" \
	"$formula_src" >"$tmp_formula"

echo
echo "─── Rendered formula ──────────────────────────────────────────────────"
cat "$tmp_formula"
echo "─────────────────────────────────────────────────────────────────────"

if [ "$dry_run" = "1" ]; then
	echo
	echo "Dry-run: stopping before publishing."
	exit 0
fi

# ── Ensure tap repo exists ───────────────────────────────────────────────────
if gh repo view "$TAP_OWNER/$TAP_REPO" >/dev/null 2>&1; then
	echo "→ Tap repo $TAP_OWNER/$TAP_REPO already exists"
else
	echo "→ Creating $TAP_OWNER/$TAP_REPO (public)"
	gh repo create "$TAP_OWNER/$TAP_REPO" \
		--public \
		--description "Homebrew tap for drydock" \
		--homepage "https://github.com/$SOURCE_OWNER/$SOURCE_REPO" \
		--add-readme >/dev/null
fi

# ── Clone, write Formula/, commit, push ──────────────────────────────────────
tap_dir="$(mktemp -d)"
trap 'rm -f "$tmp_tarball" "$tmp_formula"; rm -rf "$tap_dir"' EXIT

gh repo clone "$TAP_OWNER/$TAP_REPO" "$tap_dir" -- --depth=1 --quiet
mkdir -p "$tap_dir/Formula"
cp "$tmp_formula" "$tap_dir/Formula/$FORMULA_NAME.rb"

(
	cd "$tap_dir"
	# Stage first, THEN diff against HEAD — `git diff` without --cached only
	# compares the working tree to the index and IGNORES untracked files
	# entirely, so an unstaged-new formula would falsely report "no changes"
	# and the publish would silently no-op. Staging first ensures both
	# "first-time create" and "update-on-rerun" paths are handled correctly.
	git add "Formula/$FORMULA_NAME.rb"
	if git diff --cached --quiet -- "Formula/$FORMULA_NAME.rb"; then
		echo "→ No changes — formula already up to date for $tag"
		exit 0
	fi
	git commit -m "$FORMULA_NAME: $tag" >/dev/null
	git push origin HEAD >/dev/null
	echo "→ Pushed Formula/$FORMULA_NAME.rb @ $tag to $TAP_OWNER/$TAP_REPO"
)

echo
echo "✔ Published. Users can now install with:"
echo "  brew tap $TAP_OWNER/${TAP_REPO#homebrew-}"
echo "  brew install $TAP_OWNER/${TAP_REPO#homebrew-}/$FORMULA_NAME"
