# Contributing

> This file currently covers **testing** and the **optional GitHub-credentials
> setup** for the containerized agent. PR flow, issue process, and discussion
> channels will be added by change #4 (`add-license-contributing`) in the
> v0.1.0 release plan.

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
