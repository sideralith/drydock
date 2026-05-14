# Contributing

Thanks for contributing to drydock. Use the table of contents below to jump to what you need.

- [How to file an issue](#how-to-file-an-issue)
- [How to submit a PR](#how-to-submit-a-pr)
- [Code style](#code-style)
- [Testing](#testing)
- [Where to discuss](#where-to-discuss)
- [Sharing project memory with engram (optional)](#sharing-project-memory-with-engram-optional)
- [Giving the sandbox GitHub credentials (optional)](#giving-the-sandbox-github-credentials-optional)

## Testing

### Install the test runner

```bash
# Debian/Ubuntu
sudo apt-get install -y bats

# macOS
brew install bats-core

# Any OS with Node.js
npm install -g bats
```

### Run the suite

```bash
bats test/
```

### No submodule step needed

The bats helper libraries (`bats-support` and `bats-assert`) are vendored
under `test/test_helper/`. After a plain `git clone`, just run `bats test/`
— no `git submodule update --init` required.

## Giving the sandbox GitHub credentials (optional)

By default the containerized agent can push over **HTTPS** (drydock mounts your
`~/.config/gh`, so `gh` and `git` use your GitHub OAuth token). It cannot push
over **SSH**, and its commits are unsigned (drydock deliberately does not mount
`~/.ssh` or `~/.gnupg` — a leak there would expose your *personal* keys, which
is exactly the class of accident drydock exists to prevent).

If you want SSH push and/or GitHub-"Verified" commits from inside the box, set
up **scoped, revocable** credentials in drydock's own namespace
(`~/.config/drydock/`). drydock auto-detects them and activates a compose
overlay — nothing in `~/.ssh` / `~/.gnupg` is ever touched, so the deny rules
covering those dirs stay intact. The agent's file tools (`Read`/`Edit`/`Write`)
can't read `~/.config/drydock/**` either; only `git`/`ssh`/`gpg` subprocesses
use the key material.

### SSH deploy key (per repo) — for `git push` over SSH

```bash
mkdir -p ~/.config/drydock/keys
ssh-keygen -t ed25519 -f ~/.config/drydock/keys/<PROJECT>_deploy -N "" \
  -C "drydock-<PROJECT>-deploy-$(date +%Y%m%d)"
chmod 600 ~/.config/drydock/keys/<PROJECT>_deploy

# Register the public half as a write-access deploy key on the repo:
gh repo deploy-key add ~/.config/drydock/keys/<PROJECT>_deploy.pub \
  --repo <owner>/<PROJECT> --title "drydock-<PROJECT> (write)" --allow-write
# (or via the web UI: github.com/<owner>/<PROJECT>/settings/keys → "Add deploy
#  key" → paste the .pub → check "Allow write access")
```

`<PROJECT>` is the basename of the project directory you run `drydock` in.
Next time you `drydock` / `drydock shell` in that project, `git push` over an
`git@github.com:...` remote works. Verify inside the box with
`ssh -T git@github.com` ("Hi <owner>/<PROJECT>! You've successfully
authenticated, but GitHub does not provide shell access.").

### Sandbox GPG signing key — for GitHub-"Verified" commits

A **throwaway, low-value** key kept in its own homedir, registered on your
GitHub account as a signing key. If it ever leaks, an attacker can sign commits
as you (revoke it on GitHub independently) but cannot decrypt anything encrypted
to your real key or impersonate it elsewhere — same trade-off as a per-repo
deploy key vs. your personal SSH key.

```bash
mkdir -p ~/.config/drydock/signing && chmod 700 ~/.config/drydock/signing
GNUPGHOME=~/.config/drydock/signing gpg --quick-generate-key \
  "Your Name (drydock sandbox) <your-verified-github-email@example.com>" ed25519 sign 2y
#   ↑ no passphrase — the file *is* the secret, by design. The email MUST be a
#     verified email on your GitHub account or commits show "Unverified".

GNUPGHOME=~/.config/drydock/signing gpg --armor --export <fingerprint>
#   → GitHub → Settings → SSH and GPG keys → New GPG key → paste the block
```

drydock then auto-detects the key and signs the agent's commits with it.

**Don't want a sandbox key?** Then leave `~/.config/drydock/signing/` absent —
commits inside the box are simply unsigned (no failed-to-sign errors; the image
turns `commit.gpgsign` off). Re-sign when you fold the sandbox branch into your
real branch, e.g. `git rebase --exec 'git commit --amend --no-edit -S' <base>`,
or just sign the merge/squash commit. Signing at the merge boundary is where it
actually matters.

### What drydock will NOT do

- Mount your `~/.ssh` or `~/.gnupg` into the container.
- Mount the `gpg-agent` socket.
- Provide a CLI to generate/register these keys for you (the steps above are
  one-time and explicit on purpose).

After updating drydock, run `drydock init --update` in already-configured projects to pick up new baseline denies.

## How to file an issue

Use a clear, specific title: one line describing what is broken and in which command (e.g., `drydock init --update fails on macOS 14 with "no such file" error`).

Include in the body:

1. **The exact command you ran** — copy the full invocation, including any flags.
2. **Reproduction steps** — what you did before running the command; minimal directory layout if relevant.
3. **Your environment**:
   ```
   drydock version  # run inside the project
   docker --version
   OS and version
   ```
4. **Expected behavior** — what you thought would happen.
5. **Actual behavior** — what happened instead (terminal output, error messages, exit code).

GitHub Issues is the only intake channel for v0.1.0 — there is no Discord, mailing list, or external tracker. Issue templates may land post-v0.1.0; for now, use this structure.

## How to submit a PR

1. **Fork** the repository on GitHub, then clone your fork locally:
   ```bash
   git clone git@github.com:<your-username>/drydock.git
   cd drydock
   ```

2. **Create a branch** using the `type/short-description` convention — mirrors the commit-type prefix (e.g., `feat/add-podman-support`, `fix/init-update-macos`).

3. **Commit** using Conventional Commits. See [CLAUDE.md §5: Tracking & Contribution](CLAUDE.md#5-tracking--contribution) for the full conventions table: allowed types, the prohibition on `Co-Authored-By` trailers, and the `--no-verify` / `--force` rules. Do not duplicate the table here.

4. **Push** to your fork and open a PR against `main`.

5. **CI must pass.** The three gates are documented in [§ Code style](#code-style); a red CI blocks merge.

6. A maintainer will review. For now, write a clear PR description (what changed, why, how tested) — a PR template may land post-v0.1.0.

> Note: no GitHub remote exists yet (v0.1.0 ships it). These instructions describe the canonical GitHub OSS flow and will be end-to-end verifiable once the remote is live.

## Code style

Run these three checks locally before pushing. CI runs the same gates and a red build blocks merge.

```bash
shellcheck bin/drydock lib/*.sh   # must produce no errors
shfmt -d bin/drydock lib/         # must produce no diff
bats test/                        # all tests must pass
```

Every script MUST start with `set -euo pipefail` — see [CLAUDE.md §3: Code / Tooling Conventions](CLAUDE.md#3-code--tooling-conventions) for the full Bash conventions.

## Where to discuss

Use **GitHub Issues** for bugs, feature requests, and design questions. Issues are public and searchable — filing an issue helps future contributors with the same question.

GitHub Discussions may open post-v0.1.0 if the community asks for a less-formal forum. There is no Discord, Slack, or mailing list for v0.1.0.

## Sharing project memory with engram (optional)

engram is optional per drydock's design ([CLAUDE.md INV-4: Engram is Optional](CLAUDE.md#inv-4-engram-is-optional)): drydock works fully without it. This section applies only if you already use engram and want to share architectural memories with other drydock contributors.

**Maintainer side** — after closing an architectural decision relevant to drydock:

```bash
cd ~/git/drydock
engram sync --project drydock   # creates a chunk in .engram/
git add .engram/
git commit -m "sync engram memories: <topic>"
git push
```

**Contributor side** (engram users only):

```bash
git pull
engram sync --import            # absorbs new chunks into your local DB
```

After `engram sync --import`, `engram search` returns the maintainer's drydock memories in your tool.

**Not using engram?** The `.engram/` directory is committed to the repo (`.gitignore` deliberately does not exclude it — chunks are text-based and meant to be versioned). You can ignore `.engram/` entirely; drydock works fine without it.

This is NOT "engram cloud sync" — no central server is involved. It is a git-based sharing pattern.
