# Sibling project links — `drydock link`

`drydock link` mounts other directories from your host into the container as
read-only sibling workspaces. The agent can read them — useful for referencing a
shared library, another repo's API surface, or a monorepo sibling — but cannot
write to them.

## The three commands

| Command | What it does |
|---|---|
| `drydock link <host-path> [container-target]` | Mount `<host-path>` read-only inside the container. Default target: `/workspace-siblings/<basename>`. Config is persistent — re-applied on every subsequent `drydock` invocation for this project. |
| `drydock unlink <host-path>` | Remove the sibling mount for this project. |
| `drydock links` | Show all configured sibling mounts for the current project. |

**RO-by-default contract.** All linked siblings are mounted `:ro`. The
read-only flag is enforced at the OS layer — it is not a policy setting the
agent can modify. If you need the agent to modify a sibling, edit it directly
on the host (outside any drydock container). See
[§ Write access gap](#write-access-gap-workaround) below.

## The host-path-mirror pattern

The optional `<container-target>` argument lets you mount a sibling at the
**same absolute path inside the container as it occupies on the host**:

```bash
# ~/git/shared-lib on host → /home/rai/git/shared-lib inside container
drydock link ~/git/shared-lib /home/rai/git/shared-lib
```

This is the **host-path-mirror pattern**. It is useful whenever a tool embeds
absolute paths into its output:

- **Stack traces** — `~/git/shared-lib/src/utils.ts:42` is valid both on host
  and inside the container; the agent can navigate to the file without
  rewriting paths.
- **Language server configs** (TypeScript project references, Go workspaces,
  Python path roots) — absolute include paths resolve correctly.
- **Build tool output** — webpack/esbuild source-map references, Go binary
  debug info, Cargo build artifacts all embed the source root. Matching the
  host path keeps tooling portable.

Devcontainers use the same convention: mount the workspace at the same path as
on the host so `$PWD` inside the container equals `$PWD` outside.

**Why `home` is not in the system-dir reject list.** The custom container
target rejects first-path-component system directories (`etc`, `bin`, `usr`,
etc.) to prevent shadowing critical container paths. `home` is intentionally
absent from that list (`lib/commands.sh:753`) — `/home/<user>/git/foo` is
exactly the host-path-mirror target. `$HOME` **itself** and its **ancestors**
(`/home`, `/`) are still rejected; only targets strictly under `$HOME` are
allowed.

## List-file format and persistence

Link configuration is stored per-project in:

```
~/.config/drydock/links/<project>.list
```

Each line is pipe-delimited: `<host_path>|<container_target>|<flags>\n`.

The file is the **durable source of truth**. On every `drydock run` or
`drydock shell` invocation, `generate_links_overlay` reads it and generates a
temporary compose overlay (`/tmp/drydock-links-$$.yml`) containing the
`services.drydock.volumes` block. The overlay is cleaned up on exit and
regenerated fresh on the next launch — it is ephemeral state, not config.

`drydock link` / `unlink` / `links` are config-only commands: they read and
write the list file without invoking Docker or launching a container. They
work even when no container is running.

## Idempotent re-link

Re-linking the same host path with the **same container target** is a no-op:

```bash
drydock link ~/git/foo /workspace-siblings/foo   # first call: linked
drydock link ~/git/foo /workspace-siblings/foo   # second call: "already linked: ..."
```

Re-linking the same host path with a **different container target** is an
error — `drydock link` requires an explicit `unlink` first:

```bash
drydock link ~/git/foo /workspace-siblings/foo
drydock link ~/git/foo /home/rai/git/foo
# error: already linked with a different container target '/workspace-siblings/foo'
#        — run 'drydock unlink ~/git/foo' first
```

This prevents silent remounting: if you change the target path while a session
is running, the running container is unaffected (overlays are generated at
launch time). The error prompts an explicit unlink + re-link so the intent is
clear.

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

**Container target collision.** Two entries with the same custom container
target would cause Docker Compose to silently keep only one mount. drydock
rejects the second:

```bash
drydock link ~/git/a /workspace-siblings/common
drydock link ~/git/b /workspace-siblings/common
# error: container target collision: '/workspace-siblings/common' already used
```

## Deferred: `--rw` (read-write links)

The `--rw` flag is parsed by `drydock link` but is not yet implemented — it
errors immediately:

```
drydock link --rw ~/git/foo
error: RW links not yet implemented
```

Several design questions remain open before RW links can ship:

- **Deploy-key-per-sibling isolation** — if the agent can write to a sibling,
  it needs git credentials scoped to that repo. The current credential model
  is project-scoped.
- **`CLAUDE.md` governance** — which project's `CLAUDE.md` governs the agent
  when it edits a sibling? The primary project's, the sibling's, or both
  merged?
- **Git identity for sibling commits** — should commits in the sibling use
  the same author as the primary project?
- **Encoding flags in the list file** — the flags column already exists in
  the format (currently always empty); populating it for `--rw` is
  straightforward once the design questions above are resolved.

**Today's workaround.** To modify a sibling, step outside the drydock
container and edit it directly on the host. The sibling's host path is
unchanged — your regular editor, terminal, or another drydock session started
in the sibling's directory all work as normal. The current drydock session
can read the changes immediately (the `:ro` mount reflects whatever is on
the host filesystem in real time).

## Credential safety in linked siblings

Three layers cooperate to protect credentials inside any linked sibling.
Full walkthrough: [security.md § Credential protection in linked siblings](security.md#credential-protection-in-linked-siblings).

Summary:

1. **Link-time guard** — `drydock link` rejects host paths that are (or are
   under) `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, or `~/.docker`. Credential
   dirs are never linked in the first place.
2. **`:ro` mount** — even if a sibling contains a credential-like file (a
   `.env`, a `.pem`), the bind-mount is read-only. Writes are blocked at the
   OS layer.
3. **`//**/`-anchored deny rules** — `00-secrets.json` denies Read/Edit/Write
   on credential paths at any mount depth, including inside sibling trees.

## Validation rules reference

For the full list of rejection classes with example triggers and resolutions,
see [troubleshooting.md § "drydock link rejected my path"](troubleshooting.md#drydock-link-rejected-my-path).

## Write access gap workaround

RW links are not yet implemented (see [§ Deferred: `--rw`](#deferred---rw-read-write-links)).
To share writes with a sibling project:

1. Exit or leave the drydock container running (the sibling's `:ro` mount
   reflects live host filesystem state).
2. In a separate terminal **on the host** (or in another drydock session
   started in the sibling's directory), edit the sibling directly.
3. Changes are immediately visible inside the running container through the
   `:ro` mount — no restart needed.

This gap is intentional for the current release. The `--rw` flag exists in
the parser to reserve the syntax; the implementation waits on the open design
questions listed above.
