# Sibling project links — `drydock link`

`drydock link` mounts other directories from your host into the container as
sibling workspaces. By default the mount is read-only — the agent can read
but not write. Use `--rw` to grant write access and enable `git push` from
the sibling via a per-sibling deploy key.

## The three commands

| Command | What it does |
|---|---|
| `drydock link [--rw] <host-path> [container-target]` | Mount `<host-path>` inside the container. Default target: `/workspace-siblings/<basename>`. Without `--rw`: read-only (`:ro`). With `--rw`: read-write (`:rw`) with per-sibling SSH credentials. Config is persistent — re-applied on every subsequent `drydock` invocation for this project. |
| `drydock unlink [--rw] <host-path>` | Remove the sibling mount. The `--rw` flag is accepted and ignored — the list entry's `flags` field is authoritative for cleanup behavior. |
| `drydock links` | Show all configured sibling mounts for the current project, with mount mode `(ro)` or `(rw)` per entry. |

## RO links (default)

```bash
drydock link ~/git/shared-lib
# linked: /home/user/git/shared-lib → /workspace-siblings/shared-lib (ro)
```

The agent can read the sibling but not write. The `:ro` flag is enforced at
the OS layer — not a policy setting the agent can modify.

## RW links (`--rw`)

```bash
drydock link --rw ~/git/mylib
# linked: /home/user/git/mylib → /workspace-siblings/mylib (rw)
# [prints pubkey + GitHub deploy-key instructions]
```

`--rw` grants the container write access to the sibling **and** sets up SSH
credentials so the agent can `git push` to the sibling's GitHub repo:

1. Generates a per-sibling ed25519 deploy key at
   `~/.config/drydock/keys/<sibling>_deploy{,.pub}`.
2. Regenerates the managed SSH config at
   `~/.config/drydock/ssh-config-<primary>` with a `Host github.com-<sibling>`
   alias block and a fallback `Host github.com` block for the primary.
3. Rewrites the sibling's `remote.origin.url` from
   `git@github.com:owner/repo.git` to `git@github.com-<sibling>:owner/repo.git`
   so OpenSSH routes to the correct deploy key.
4. Prints the public key and the `gh repo deploy-key add` command to register
   it on GitHub (drydock does not register it automatically — you decide when).
5. Appends a `flags="rw"` entry to the project link list.

**Only `git@github.com:owner/repo[.git]` SSH URLs are supported.** HTTPS
remotes (`https://github.com/...`) are rejected with an actionable error.

### Non-git directory (`--rw` with no `.git/`)

If the sibling has no `.git/` subdirectory at link time, `drydock link --rw`
still mounts it `:rw` but skips the deploy-key, SSH config, and URL rewrite
steps. An informational note is printed. Re-run `drydock link --rw <path>`
after `git init` to wire up the SSH flow (D10).

### Idempotency (re-link on same path)

Re-running `drydock link --rw` on an already-linked path is safe: the
existing key is reused unchanged, the managed SSH config is regenerated
(byte-identical when the link set hasn't changed), the URL rewrite is a
no-op, and the pubkey is printed again (D11).

## `drydock unlink` with RW siblings

```bash
drydock unlink ~/git/mylib
```

Regardless of whether `--rw` was used at link time, `unlink` detects the
`flags="rw"` entry and performs full cleanup (SR-6):

1. Removes the `.list` entry.
2. Regenerates the managed SSH config (removing the sibling's `Host` alias block).
3. Restores the sibling's `remote.origin.url` to canonical form
   (`git@github.com:owner/repo[.git]`).
4. Leaves deploy key files on disk (you own them — drydock never deletes credentials).
5. Prints a **dual-sided hint** (D6):
   - Local: path to the key files + the `rm` command.
   - GitHub: URL and `gh repo deploy-key` command to revoke the GitHub-side key
     (drydock cannot do this — it has no GitHub API access at unlink time).

The `--rw` flag is accepted on `unlink` and ignored. The `.list` entry's
`flags` field is the authoritative source for cleanup behavior. You do not
need to remember whether a sibling was linked with `--rw`.

## How per-sibling SSH routing works

The managed SSH config (`~/.config/drydock/ssh-config-<primary>`) is
bind-mounted `:ro` into the container. `GIT_SSH_COMMAND` is set to
`ssh -F <config>` so all git SSH operations go through it.

Inside the container, when the agent runs `git push` from an RW sibling:

1. The rewritten URL `git@github.com-<sibling>:owner/repo.git` has
   host part `github.com-<sibling>`.
2. OpenSSH matches the literal `Host github.com-<sibling>` block (first-match
   wins per option; literal patterns, no wildcards).
3. The block resolves `HostName github.com`, `User git`,
   `IdentityFile ~/.config/drydock/keys/<sibling>_deploy`,
   `IdentitiesOnly yes`.
4. ssh connects to `github.com` using only the sibling's deploy key.
5. GitHub's known-hosts check uses `github.com` (from `HostName`) — matched
   by the pinned key in `/etc/ssh/ssh_known_hosts` baked into the image.

For the primary project (canonical URL `git@github.com:owner/repo.git`):
1. Host part is `github.com` — matches the fallback `Host github.com` block.
2. Resolves to the primary deploy key.

**Note on alias naming**: the sibling alias is a local SSH label only (e.g.
`github.com-my_lib`). DNS resolution uses `HostName github.com`, so
underscores or dashes in the alias are irrelevant to actual TLS/DNS resolution
(R13).

## The host-path-mirror pattern

The optional `<container-target>` argument lets you mount a sibling at the
**same absolute path inside the container as it occupies on the host**:

```bash
# ~/git/shared-lib on host → /home/user/git/shared-lib inside container
drydock link ~/git/shared-lib /home/user/git/shared-lib
```

Useful whenever a tool embeds absolute paths into its output: stack traces,
language-server configs (TypeScript project references, Go workspaces, Python
path roots), build-tool output (source maps, debug info). Matching the host
path keeps tooling portable between host and container.

## List-file format and persistence

Link configuration is stored per-project in:

```
~/.config/drydock/links/<project>.list
```

Each line is pipe-delimited: `<host_path>|<container_target>|<flags>\n`.
The `flags` field is empty for RO links and `rw` for RW links.

The file is the **durable source of truth**. On every `drydock run` or
`drydock shell` invocation, `generate_links_overlay` reads it and generates a
temporary compose overlay (`/tmp/drydock-links-$$.yml`) containing the
`services.drydock.volumes` block. The overlay is cleaned up on exit and
regenerated fresh on the next launch — it is ephemeral state, not config.

`drydock link` / `unlink` / `links` are config-only commands: they read and
write the list file without invoking Docker or launching a container. They
work even when no container is running.

## Idempotent re-link (RO)

Re-linking the same host path with the **same container target** is a no-op:

```bash
drydock link ~/git/foo /workspace-siblings/foo   # first call: linked
drydock link ~/git/foo /workspace-siblings/foo   # second call: "already linked: ..."
```

Re-linking the same host path with a **different container target** is an
error — `drydock link` requires an explicit `unlink` first:

```bash
drydock link ~/git/foo /workspace-siblings/foo
drydock link ~/git/foo /home/user/git/foo
# error: already linked with a different container target '/workspace-siblings/foo'
#        — run 'drydock unlink ~/git/foo' first
```

## Collision detection

Two collision classes are detected at link time:

**Basename collision.** The default container target is
`/workspace-siblings/<basename>`. Two different host paths with the same
directory name would map to the same default target:

```bash
drydock link ~/work/foo    # → /workspace-siblings/foo
drydock link ~/personal/foo  # error: basename collision — 'foo' already used
```

Fix: supply an explicit container target for one or both:

```bash
drydock link ~/personal/foo /workspace-siblings/personal-foo
```

For RW links, a basename collision also means a deploy-key collision (two
siblings would share the same `<name>_deploy` file). drydock rejects the
collision at link time with an actionable error identifying the conflicting
existing entry (SR-4).

**Container target collision.** Two entries with the same custom container
target would cause Docker Compose to silently keep only one mount. drydock
rejects the second:

```bash
drydock link ~/git/a /workspace-siblings/common
drydock link ~/git/b /workspace-siblings/common
# error: container target collision: '/workspace-siblings/common' already used
```

## Credential safety in linked siblings

Three layers cooperate to protect credentials.
Full walkthrough: [security.md § Credential protection in linked siblings](security.md#credential-protection-in-linked-siblings).

Summary:

1. **Link-time guard** — `drydock link` rejects host paths that are (or are
   under) `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, or `~/.docker`. Credential
   dirs are never linked in the first place.
2. **`:ro` / `:rw` mount** — RO siblings block writes at the OS layer. RW
   siblings allow writes but only to the sibling directory itself.
3. **`//**/`-anchored deny rules** — `00-secrets.json` denies Read/Edit/Write
   on all `~/.config/drydock/**` paths (which covers the managed SSH config and
   all deploy keys) at any mount depth, including inside sibling trees.

The per-sibling deploy key and managed SSH config live under
`~/.config/drydock/` (INV-1). The agent cannot read or write them via Claude
Code tools. The `ssh` subprocess invoked by `git` opens them via the OS — this
is the intended mechanism and is not gated by the deny rules.

## Validation rules reference

For the full list of rejection classes with example triggers and resolutions,
see [troubleshooting.md § "drydock link rejected my path"](troubleshooting.md#drydock-link-rejected-my-path).
