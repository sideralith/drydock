# Contributing

Thanks for contributing to drydock. Use the table of contents below to jump to what you need.

- [How to file an issue](#how-to-file-an-issue)
- [How to submit a PR](#how-to-submit-a-pr)
- [Code style](#code-style)
- [Testing](#testing)
- [Where to discuss](#where-to-discuss)
- [Giving the sandbox GitHub credentials (optional)](#giving-the-sandbox-github-credentials-optional)

## Testing

New to drydock? Run `./install.sh` from the repo root (or `curl -fsSL <URL>/install.sh | bash` for a fresh machine) to create the `drydock` symlink and verify your prereqs before contributing. Running it in a terminal also offers to build the image and add `~/.local/bin` to PATH (all prompts default to no); the `curl | bash` form stays non-interactive. See `install.sh` header for env-var overrides.

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
scripts/test.sh        # recommended — wraps `bats -r test/`
```

`scripts/test.sh` is a thin wrapper around `bats -r test/` (recursive, so
`test/integration/*.bats` is collected too — those files skip themselves
unless their opt-in flag is set). On a normal host it is transparent. Pass
through specific files or flags as usual: `scripts/test.sh test/lib_paths.bats`.

#### Running the suite inside a drydock container

`scripts/test.sh` exists so the suite is runnable from *inside* a drydock
container too. The container hardening overlay (INV-8) mounts `/tmp` as a
`noexec` tmpfs; bats writes stub executables under `$TMPDIR`, so a bare
`bats test/` fails ~20 tests with `Permission denied`. The wrapper detects a
`noexec` tmpdir and redirects bats to an exec-allowed path under `$HOME`
(`~/.bats-tmp`) — the `/tmp` hardening is left untouched. It also
falls back to `npx --yes bats` when no `bats` binary is on `PATH` (the base
image ships none). Always use `scripts/test.sh` inside the container; plain
`bats test/` is the host-only invocation (equivalent on a normal host, but
not safe inside drydock where `/tmp` is `noexec`).

### Running integration tests locally

Most bats tests run unit-mode and need no special flag. Two integration tiers
exist for tests that exercise a built `drydock:latest` image; both are gated by
explicit opt-in flags so the default `scripts/test.sh` invocation stays fast
and green on a fresh checkout.

| Flag | What it enables | Where it runs |
|------|-----------------|---------------|
| `DRYDOCK_INTEGRATION=1` | Bats tests that `docker run --rm drydock:latest …` against the built image (T5 + the T19 family in `test/managed_settings.bats` — verify the INV-3 managed-settings bake: presence + JSON-validity of all six drop-ins, root ownership of the bake target, and the `00-secrets.json` deny-rule contract). DooD-safe. | Locally **and in CI** — the smoke job sets this flag after `drydock build`. |
| `DRYDOCK_INTEGRATION_HOSTNET=1` | Tests that launch real containers via `docker compose run` and require `network_mode: host` (`test/integration/test_projects_submount.sh` — SR-9, the shared `projects/` sub-mount resolution proof). | **Local only.** GitHub Actions runners use DinD where `network_mode: host` maps to the runner's container namespace, not a bare Linux host, and produces unreliable results. |

Local invocation:

```bash
# DooD-safe integration tier (also what CI runs):
drydock build
DRYDOCK_INTEGRATION=1 scripts/test.sh test/managed_settings.bats

# Host-network tier (local only — must run on a real host or inside a drydock
# container with the host Docker socket; cannot run in GHA):
drydock build
DRYDOCK_INTEGRATION_HOSTNET=1 test/integration/test_projects_submount.sh
```

The shared `DRYDOCK_INTEGRATION_*` prefix marks these as runtime-tier flags;
the `_HOSTNET` suffix is the explicit reason SR-9 stays out of CI.

#### The REQ-N10 session-lifecycle gate

`test/integration/session_lifecycle_compose_exec.bats` is the empirical gate
for REQ-N10 ("Detect + Delegate" session model): it runs the real production
lifecycle — `export_compose_env` + `compose_files` + `docker compose up -d` /
`exec` / `down` — against a built `drydock:latest` image and asserts L-A..L-D
(persistent `sleep` PID 1, SIGHUP survival, same-container re-attach, clean
teardown). It is part of the default suite but skips itself (via `skip` in
`setup_file()`) unless `DRYDOCK_INTEGRATION=1` is set. To run it:
`drydock build && DRYDOCK_INTEGRATION=1 scripts/test.sh
test/integration/session_lifecycle_compose_exec.bats` — it starts and removes
real containers, so run it only on a machine where that is acceptable.

### No submodule step needed

The bats helper libraries (`bats-support` and `bats-assert`) are vendored
under `test/test_helper/`. After a plain `git clone`, just run
`scripts/test.sh` — no `git submodule update --init` required.
(On a normal host `scripts/test.sh` delegates to `bats -r test/`; inside a
drydock container it additionally redirects bats' tmpdir away from the
`noexec` `/tmp`.)

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

After updating drydock, run `drydock build` so the new baseline denies in the managed-settings layer take effect.

## How to file an issue

Use a clear, specific title: one line describing what is broken and in which command (e.g., `drydock build fails on macOS 14 with "no such file" error`).

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

GitHub Issues is the only intake channel — there is no Discord, mailing list, or external tracker. A bug-report form lives in [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/bug_report.yml); the structure below is what it asks for.

## How to submit a PR

1. **Fork** the repository on GitHub, then clone your fork locally:
   ```bash
   git clone git@github.com:<your-username>/drydock.git
   cd drydock
   ```

2. **Create a branch** using the `type/short-description` convention — mirrors the commit-type prefix (e.g., `feat/add-podman-support`, `fix/submount-detection-macos`).

3. **Commit** using Conventional Commits. See [CLAUDE.md §5: Tracking & Contribution](CLAUDE.md#5-tracking--contribution) for the full conventions table: allowed types, the prohibition on `Co-Authored-By` trailers, and the `--no-verify` / `--force` rules. Do not duplicate the table here.

4. **Push** to your fork and open a PR against **`dev`** — not `main`.

   drydock uses a two-branch model. `dev` is the integration branch: every
   feature and fix PR lands there, and that is where day-to-day development
   happens. `main` holds only released versions — each commit on `main` is a
   shipped release. A normal contribution therefore always targets `dev`;
   `main` is never a PR target for feature or fix work.

   A release is itself a PR — `dev` → `main`, opened by a maintainer when a
   batch of changes is ready to ship. That merge bumps `DRYDOCK_VERSION`
   (`lib/common.sh`), is tagged `vX.Y.Z`, and is published as a GitHub Release.
   So every PR merged into `main` *is* a new tagged version; PRs merged into
   `dev` are the individual changes that accumulate into the next one.

5. **CI must pass.** The three gates are documented in [§ Code style](#code-style); a red CI blocks merge.

6. A maintainer will review. For now, write a clear PR description (what changed, why, how tested).

7. **On merge**, the maintainer manually closes the linked issue with a comment referencing the PR. GitHub does not auto-close it when the merge target is not the default branch, so the close is a deliberate step — done at merge time, not deferred to a later release.

## Code style

Run these three checks locally before pushing. CI runs the same gates and a red build blocks merge.

```bash
shellcheck bin/drydock lib/*.sh scripts/*.sh install.sh   # must produce no errors
shfmt -d bin/drydock lib/ scripts/ install.sh             # must produce no diff
scripts/test.sh                                           # all tests must pass
```

Every commit subject on a PR targeting `dev` must follow Conventional Commits format.
Verify locally before pushing:

```bash
scripts/lint-commits.sh   # auto-detects the range via git merge-base origin/dev HEAD
```

The same script runs in CI via the `Lint (commit-message)` job. For the exact set of valid
types and the `Co-Authored-By` trailer prohibition, see
[CLAUDE.md §5: Tracking & Contribution](CLAUDE.md#5-tracking--contribution).

Note: the script lints commits on the feature branch. When a PR is squash-merged, the
maintainer-provided squash subject lands on `dev` and is not CI-enforced.

Every script MUST start with `set -euo pipefail` — see [CLAUDE.md §3: Code / Tooling Conventions](CLAUDE.md#3-code--tooling-conventions) for the full Bash conventions.

## Where to discuss

Use **GitHub Issues** for bugs, feature requests, and design questions. Issues are public and searchable — filing an issue helps future contributors with the same question.

GitHub Discussions may open post-v0.1.0 if the community asks for a less-formal forum. There is no Discord, Slack, or mailing list for v0.1.0.
