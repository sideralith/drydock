# Homebrew packaging

This directory contains the Homebrew formula source for drydock and the
publish flow that ships it as a tap.

## For users — install via Homebrew

After the tap is published (one-time, see below):

```bash
brew tap sideralith/tap
brew install sideralith/tap/drydock

# First-time setup:
drydock build       # ~5 min, one-off

# Use it in any project:
cd ~/git/myproject && drydock
```

Requirements (handled by brew except Docker itself):

- `jq`, `rsync` — declared `depends_on` in the formula.
- Docker — must be installed and running on the host (Docker Desktop on
  macOS, Docker Engine on Linux). Brew can't install Docker Engine on
  Linux; install per https://docs.docker.com/engine/install/.

Engram (optional persistent memory) is auto-detected if on `PATH`.

## For maintainers — publishing the tap

The tap lives at `sideralith/homebrew-tap` (separate repo, Homebrew
convention — the generic `homebrew-tap` name keeps the install command
clean: `brew install sideralith/tap/drydock` instead of the double-named
`sideralith/drydock/drydock`, and leaves room for future sideralith
formulae under the same tap). The formula source lives here in this
repo; the `scripts/publish-homebrew-tap.sh` script computes the release
tarball SHA256, renders the formula, and pushes it to the tap repo.

**Run on the host** (the script creates a public GitHub repo on first
run — outward-facing action, do it explicitly):

```bash
# After a drydock release tag exists upstream:
./scripts/publish-homebrew-tap.sh              # uses latest release tag
./scripts/publish-homebrew-tap.sh v0.2.1       # specific tag
./scripts/publish-homebrew-tap.sh --dry-run    # render formula, don't push
```

The script needs `gh` authenticated with `repo` scope. Verify:

```bash
gh auth status
```

### What the script does

1. Resolves the release tag (latest by default).
2. Downloads `https://github.com/sideralith/drydock/archive/refs/tags/<tag>.tar.gz`.
3. Computes SHA256.
4. Substitutes `url` + `sha256` into `drydock.rb`.
5. Creates `sideralith/homebrew-tap` if missing (else clones existing).
6. Stages `Formula/drydock.rb`, commits if changed, and pushes.

### Updating for a new release

Just re-run the script with the new tag. It commits `drydock: vX.Y.Z` to
the tap repo. Brew picks up the new version on `brew update`.

The script is idempotent: re-running with the same tag detects no change
(staged file matches HEAD) and exits without a commit/push.

### Why a separate tap repo (and not just `brew tap sideralith/drydock <url>`)?

Homebrew's convention is `homebrew-<name>` tap repos that ship a
`Formula/` directory. That convention enables the short
`brew tap sideralith/tap` invocation without users having to pass an
explicit URL. The drydock source repo stays free of Ruby and brew-
specific build noise.

### Why the tap repo is named `homebrew-tap` (and not `homebrew-drydock`)

A repo named `homebrew-drydock` would force users to type
`brew install sideralith/drydock/drydock` — the "drydock" appears twice,
which is the standard "double-name" UX wart of single-formula taps. The
generic `homebrew-tap` name (used by AWS, goreleaser, hashicorp, and
others) keeps the install command clean and lets the same tap host
future sideralith formulae without forcing a rename later.
