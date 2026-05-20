# drydock troubleshooting

Common failures and fixes. Run `drydock doctor` first — it shows versions,
paths, mount detection, and GIDs.

## "Claude configuration file not found at: /home/rai/.claude.json" / settings don't persist

Claude Code reads config from TWO locations: the `~/.claude/` **directory**
(skills, plugins, `settings.json`, `CLAUDE.md`, hooks) AND the `~/.claude.json`
**file** (project list, onboarding flags, `mcpServers`, OAuth). drydock must
mount both. If the `~/.claude-container.json` prototype doesn't exist on host,
the per-session `~/.claude-container-<disc>.json` cannot be seeded, Claude Code
inside the container can't find `~/.claude.json`, creates a fresh one on the
container's ephemeral filesystem, and any config you do (onboarding, theme,
hints) is lost when the container exits.

Fix:

```bash
cp -a ~/.claude.json ~/.claude-container.json    # repair the prototype; or: drydock setup
```

`drydock setup` auto-creates the prototype. `drydock sync` refreshes it from
host. The compose file mounts a per-session `~/.claude-container-<disc>.json`
(seeded from the `~/.claude-container.json` prototype) at
`/home/rai/.claude.json:rw`.

## `docker exec` from inside the container fails with permission denied

The container user must be in a group matching the host's docker-socket GID.
Check on host:

```bash
stat -c '%g' /var/run/docker.sock
```

If different from the `HOST_DOCKER_GID` baked into the image (default 1001),
rebuild with the right value:

```bash
HOST_DOCKER_GID=999 drydock build
```

The CLI auto-detects on each build by default — manual override only if the
detection is wrong for some reason.

## `claude` not found inside container

The binary lives at `~/.local/bin/claude` on host, bind-mounted into the
container. If `PATH` doesn't include `~/.local/bin`, check `ENV PATH` in the
Dockerfile.

## Engram returns "no memories" inside container

Verify `~/.engram-container/engram.db` exists on host with size > 0:

```bash
ls -la ~/.engram-container/
```

If empty, re-init:

```bash
rm -rf ~/.engram-container
drydock setup
```

If it has memories but they're stale (missing recent ones saved on host), the
container DB diverged from host's — that's by design (see
[architecture.md](architecture.md) § "Why the storage is split"). Consolidate
with `engram export` / `engram import`, or re-snapshot:

```bash
# WAL caveat: stop all Claude/engram processes first, or you risk a torn copy
rm -f ~/.engram-container/engram.db-wal ~/.engram-container/engram.db-shm
cp -a ~/.engram/engram.db ~/.engram-container/engram.db
```

For shared vs isolated mode and the migration recipe, see [engram.md](engram.md).

## Files created from container appear as `root` on host

UID/GID mismatch. Check on host:

```bash
id            # UID/GID must match what `drydock build` used
```

Rebuild:

```bash
USER_UID=$(id -u) USER_GID=$(id -g) drydock build
```

## gh CLI fails with "failed to write config after migration"

`~/.config/gh` must be RW (it migrates `hosts.yml` schema on first run in a
fresh environment). This is the default in drydock. If you changed the mount
to `:ro`, revert it.

## Image doesn't pick up changes to the Dockerfile

`drydock build` always rebuilds. If you suspect a stale layer cache:

```bash
docker image rm drydock:latest
drydock build
```

## A command was unexpectedly blocked by the guardrail layer

drydock ships a two-tier guardrail layer. Both tiers are tamper-proof — Tier 1
(the deny policy) image-baked into the container, Tier 2 (the hook script)
read-only via bind-mount (INV-3). See
[security.md](security.md#destructive-command-guardrail-layer-v020).

**Tier 1 — declarative deny (`permissions.deny`).** Two managed-settings drop-ins
at `/etc/claude-code/managed-settings.d/` (root-owned, not overridable from project
`.claude/settings.json`):

- `10-git-safety.json` — git destructive ops: protected-branch delete/rename,
  history-rewrite, remote-delete refspecs, GitHub destructive API calls.
- `30-os-safety.json` — OS destruction: `rm -rf` to system paths, disk-destruction
  tools (`dd`, `mkfs`, `wipefs`), `sudo` + destructive verb, package-manager
  purge/remove, firewall flush, `docker system/volume prune`, `docker run --privileged`,
  host-root bind mounts, and more.

Claude Code evaluates the deny list before any hook runs — matched commands are
blocked at the framework level.

**Tier 2 — `PreToolUse` hook (`drydock-block-destructive.sh`).** Handles six rule
classes that deny patterns cannot express:

| Rule | Example blocked |
|---|---|
| C1-residue — `rm` with a recursive flag targeting a system path | `rm -Rf /etc` |
| A1 — ssh to production host | `ssh user@prod.example.com` |
| C12 — fork bomb | `:() { :|:& };:` |
| C17 — `rm` of `.` or `.git` | `rm -rf .` |
| C18 — `rm` of parent traversal | `rm -rf ../sibling` |
| C20 — curl/wget pipe to shell | `curl https://x.com/i.sh \| bash` |

**If the block is correct:** rephrase the command to a non-destructive form, or
run it from the host where drydock's guardrails do not apply.

**If you believe it is a false positive:** check the documented limitation classes
in [security.md](security.md#known-limitations). If your case is not listed, open
a GitHub issue (issue #31 tracks the quoted-target bypass as one known gap). Do
NOT edit the image-baked drop-ins locally — a `drydock build` restores them from
the image.

**To inspect active rules:** the drop-in JSON files are readable at
`/etc/claude-code/managed-settings.d/` inside the container (read-only), and in
the repo at `templates/managed-settings.d/`.

## Sub-mount not visible inside the container

drydock automatically detects sub-mounts under `$PROJECT_DIR` and propagates
them. Run `drydock doctor` to see the current detection:

```bash
cd ~/git/yourproject && drydock doctor
# Look for the "sub-mounts under ..." section:
#   ✓ /home/rai/git/yourproject/docs → /mnt/c/.../docs (drvfs auto-translated)
#   ✓ /home/rai/git/yourproject/data → /data/src (Linux-native bind)
#   ⚠ /home/rai/git/yourproject/nfs → server:/share (nfs, may not propagate)
#   (none detected)
```

**If a sub-mount shows `✓` but content is still missing inside the container:**
- Restart `drydock shell` — the overlay is generated per-invocation; a running
  container from before the mount was added won't have it.
- For drvfs: ensure Docker Desktop is running and the WSL2 integration is
  enabled for the drive.

**If a sub-mount shows `⚠ (source FS root not found — will be skipped)`:**
- This is a linux-native bind where the source filesystem's root entry is
  missing from `/proc/self/mountinfo`. This can happen on some container
  runtimes or with unusual bind configurations. Diagnostic:
  `awk '{print $3, $4, $5}' /proc/self/mountinfo | sort` — look for the
  major:minor of the sub-mount and check if a row with `fsroot=/` exists.

**If a sub-mount is classified exotic and not propagating:**
- NFS, CIFS, FUSE, tmpfs, and overlay mounts may not propagate through
  Docker Desktop's WSL2 channel. The source path is passed through as-is,
  but Docker may reject or silently drop it. Consider bind-mounting a
  linux-native path instead.

**If `(none detected)` but you see a mount in `mount | grep your/path`:**
- Check that the mount appears in `/proc/self/mountinfo` (not just `/proc/mounts`
  which can be stale). drydock reads `mountinfo` exclusively.

## Sub-mount visible in drydock but NOT in containers launched via DooD

The sub-mount propagation overlay only applies to the **drydock container
itself**. When you (or the agent inside drydock) runs `docker compose up`
against a project's own stack (Docker-out-of-Docker), those child containers
talk to the host's Docker daemon — which does NOT see drvfs sub-mounts
created post-boot of its WSL2 shared filesystem. The path `./docs` in your
project's compose resolves to the same drvfs path the host daemon can't read,
so the child container sees the mount as empty.

**Symptom**: `drydock shell` lists `docs/` correctly, but
`docker exec your-project-api ls /var/www/docs` is empty.

**Fix**: drydock exports a translated host path as an env var for each
detected sub-mount: `DRYDOCK_SUBMOUNT_<UPPER_RELPATH>_HOST_PATH`. Reference
it in your project's `docker-compose.yml` with a portable fallback:

```yaml
# project-side docker-compose.yml
services:
  api:
    volumes:
      - ./backend:/var/www/html
      # Use the drydock-translated path inside drydock; fall back to ./docs
      # for collaborators without the bind mount (or running outside drydock).
      - ${DRYDOCK_SUBMOUNT_DOCS_HOST_PATH:-./docs}:/var/www/docs
```

The env var name is derived from the path of the sub-mount relative to
`$PROJECT_DIR`: uppercased, with non-alphanumeric characters replaced by `_`.
Examples:

| Sub-mount path inside project | Env var name |
|---|---|
| `docs/` | `DRYDOCK_SUBMOUNT_DOCS_HOST_PATH` |
| `vault/notes/` | `DRYDOCK_SUBMOUNT_VAULT_NOTES_HOST_PATH` |
| `data/shared/` | `DRYDOCK_SUBMOUNT_DATA_SHARED_HOST_PATH` |

The fallback `${DRYDOCK_SUBMOUNT_..._HOST_PATH:-./docs}` keeps the project's
compose portable: collaborators on machines without the bind mount (or
running `docker compose up` directly without going through drydock) use the
literal `./docs` path.

### How the env vars flow into compose substitution

drydock writes the env vars in three places automatically every time the
CLI runs against your project:

1. **Host CLI shell environment** — `export_compose_env()` sets each
   `DRYDOCK_SUBMOUNT_*_HOST_PATH` in the shell that invokes
   `docker compose run drydock …`.

2. **Container drydock environment (DooD passthrough)** — the generated
   submount overlay (`/tmp/drydock-submounts-<pid>.yml`) declares
   `environment:` entries (KEY-only) so docker compose inherits each value
   from the CLI shell into the container drydock. The inner `docker compose`
   (run by the agent inside drydock) then sees the env vars and substitutes
   them.

3. **`${PROJECT_DIR}/.env` marker block** — drydock writes a
   marker-delimited block in your project's `.env` file containing one
   line per detected sub-mount:

   ```ini
   APP_KEY=base64:...
   DB_PASSWORD=hunter2

   # >>> drydock managed (auto-generated, do not edit manually) <<<
   DRYDOCK_SUBMOUNT_DOCS_HOST_PATH=/mnt/c/Users/.../Vault
   # <<< end drydock managed >>>
   ```

   This lets `docker compose` invocations from the **host shell directly**
   (without drydock involvement) substitute the env vars too — docker
   compose reads `.env` automatically when run in the project directory.

The marker block is maintained idempotently: re-runs of drydock won't
duplicate it; sub-mounts that disappear get their entries removed; the
block is deleted entirely when there are no more sub-mounts. **Only the
content between the markers is touched** — your other `.env` variables are
preserved.

**`.env` is gitignored**: ensure your project's `.gitignore` includes
`.env` (this is the standard pattern). drydock's marker block contains
host-specific paths and should never be committed.

**Opt out**: set `DRYDOCK_SKIP_ENV_WRITE=1` in your environment to disable
the `.env` auto-edit. The overlay environment passthrough (item 2 above)
keeps working, so the bug fix still applies when running through drydock —
you only lose the "host shell direct" path.

**Migration note**: if you previously added `DRYDOCK_SUBMOUNT_*_HOST_PATH`
lines to `.env` by hand (before this feature existed), drydock will NOT
touch them — they live outside the marker block. After a `drydock` run,
your `.env` will have BOTH the manual line and a duplicate inside the
marker block. docker compose reads top-down, so the marker-block value
(written last) wins. To clean up, delete the manual line; drydock's marker
block stays.

**Why this gap exists**: drydock's sub-mount propagation rewrites paths for
its own container, but cannot intercept arbitrary `docker compose` calls the
agent makes internally — those go directly to the host daemon via the
bind-mounted socket. Exposing the translated path as an env var lets each
project opt in explicitly in its compose file, and the three-layer
auto-population (shell + container env + `.env`) covers every common flow.

## ccstatusline / MCP-remote OAuth tools not working inside drydock

Two opt-in compose overlays activate **automatically** when drydock detects
the user has the relevant tool configured on host:

| Overlay | Activated when | What it mounts |
|---|---|---|
| `docker-compose.mcp-auth.yml` | `~/.mcp-auth/` exists on host | `~/.mcp-auth/` RW (mcp-remote OAuth tokens) |
| `docker-compose.ccstatusline.yml` | `~/.config/ccstatusline/` exists on host | `~/.config/ccstatusline/` + `~/.cache/ccstatusline/` RW |

These overlays are **strictly opt-in** — drydock does NOT create empty dirs
in users' homes for tools they don't use. To activate:

- **mcp-remote** (Cloudflare-bindings MCP, etc.): authenticate once from
  host claude (where the browser flow works); `mcp-remote` creates
  `~/.mcp-auth/<server-hash>/` with the OAuth tokens. From then on every
  drydock session sees them and the MCP server connects without re-auth.
  Symptom of missing this: `MCP server "cloudflare-bindings" connection
  timed out after 30000ms` because mcp-remote falls back to launching a
  browser that does not exist inside the container.

- **ccstatusline**: run `npx ccstatusline` once from host claude and save
  your preferences. The directory `~/.config/ccstatusline/` is created
  automatically and from then on drydock mounts it. Symptom of missing
  this: status line shows defaults (segments/themes from ccstatusline are
  NOT applied) even after `drydock sync` ran. `drydock sync` only copies
  the `statusLine` block inside `~/.claude/settings.json` (which tells
  Claude WHICH command to run); the actual personalization lives in
  `~/.config/ccstatusline/settings.json` which is OUT of the `~/.claude/`
  sync scope by design.

The detection happens in `lib/compose.sh:compose_files()` — runs on every
`drydock` invocation, no manual step required. To verify which overlays
are active for your current session, inspect:

```bash
cd ~/git/yourproject
# As-if-invoked compose command (does not actually run docker):
DRYDOCK_HOME=~/.local/share/drydock bash -c '
  source $DRYDOCK_HOME/lib/common.sh
  source $DRYDOCK_HOME/lib/paths.sh
  source $DRYDOCK_HOME/lib/compose.sh
  export_compose_env $PWD
  compose_files $PWD
'
# Look for -f docker-compose.mcp-auth.yml and -f docker-compose.ccstatusline.yml
# in the output. Absence = overlay not activated (and that's correct if you
# don't use the corresponding tool).
```

## `drydock link` rejected my path

`drydock link` validates both the host source path and the optional custom
container target before writing anything. If your path is rejected, the table
below maps each rejection class to a cause and a fix.

### Host source rejections

| Rejection class | Example trigger | Resolution |
|---|---|---|
| 1. Path does not exist or is not a directory | `drydock link ~/git/file.txt` | The host path must exist and be a directory. Symlinks to directories are followed (via `realpath`). |
| 2. Path contains metacharacters | Host path with `\|`, `:`, `"`, `\`, newline, or tab | These break the pipe-delimited list file, the Docker Compose volume spec, or the YAML overlay. Rename or use a path without these characters. |
| 3. Path is `$HOME` itself or an ancestor of `$HOME` | `drydock link ~` or `drydock link /home` or `drydock link /` | Mounting `$HOME` or its ancestors would expose everything under `~/` to the container — defeating credential isolation entirely. |
| 4. Path is a credential directory (or any subdirectory) | `drydock link ~/.ssh`, `drydock link ~/.aws/my-profile` | Separator-anchored guard: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker` and anything strictly under them are rejected. Defense-in-depth for [INV-1](../CLAUDE.md). Note: `~/.ssh-backup` is **not** rejected — the guard is anchored at the directory boundary, not prefix-only. |
| 5. Path is drydock or Claude state | `drydock link ~/.claude`, `drydock link ~/.engram-container` | `~/.claude*`, `~/.engram*`, and `~/.config/drydock` (including per-session `~/.claude-container-<disc>/` dirs) are rejected. These are load-bearing wildcards for [INV-2](../CLAUDE.md). |
| 6. Path is the current project directory | `drydock link ~/git/current-project` | The project directory is already mounted at `/workspace`. Linking it again would shadow it. |

### Custom container target rejections

These fire only when you supply an explicit container path as the second argument
(`drydock link <host> <container-target>`).

| Rejection class | Example trigger | Resolution |
|---|---|---|
| 7a. custom target: not absolute | `drydock link ~/git/foo relative/path` | Container targets must begin with `/`. |
| 7b. custom target: filesystem root | `drydock link ~/git/foo /` | Mounting over `/` would replace the container's root filesystem. |
| 7c. custom target: starts with `//` | `drydock link ~/git/foo //etc/foo` | The kernel normalizes `//foo` to `/foo` at mount time, which would bypass all single-slash guards (e.g. let `//etc/foo` mount at `/etc/foo`). |
| 7d. custom target: contains `..` or `.` components | `drydock link ~/git/foo /workspace-siblings/../etc` | Docker normalizes path components at mount time. `/../etc` → `/etc`, bypassing the system-dir guard. |
| 7e. custom target: shadows `/opt/drydock/hooks` | `drydock link ~/git/foo /opt/drydock/hooks` | This is the hooks RO bind-mount ([INV-3](../CLAUDE.md)). A sibling mount over it would silently remove the read-only guardrail. See [security.md](security.md) and [docs/architecture.md](architecture.md). |
| 7f. custom target: under a system directory | `drydock link ~/git/foo /etc/myapp`, `/bin/...`, `/usr/...` | First path component must not be `etc`, `bin`, `sbin`, `usr`, `lib`, `lib32`, `lib64`, `boot`, `root`, `opt`, `proc`, `sys`, `dev`, `run`, `var`, or `tmp`. Note: `home` is intentionally **not** in this list — `/home/<user>/git/foo` is the [host-path-mirror pattern](links.md#the-host-path-mirror-pattern). |
| 7g. custom target: shadows `/workspace`, `/workspace-siblings`, `$HOME`, or drydock state | `drydock link ~/git/foo /workspace/sub`, `/workspace-siblings` | These targets would shadow the primary project mount, the siblings parent directory, `$HOME`, or container state dirs (`~/.claude*`, `~/.engram*`, `~/.config/drydock`). |
| 8. Basename collision | Two different paths with the same `basename` | The default container target is `/workspace-siblings/<basename>`. Two siblings with the same basename would collide. Supply an explicit `<container-target>` for one of them, or use `drydock unlink` on the conflicting entry first. |
| 8. Container target collision | Two entries share the same custom target | Docker Compose would silently keep only one mount. Assign distinct container targets. |

**Cross-references**: credential guard rationale → [security.md](security.md);
hooks guard rationale → [architecture.md](architecture.md#inv-3-and-the-link-guard);
host-path-mirror pattern → [docs/links.md](links.md#the-host-path-mirror-pattern).

## drydock can't find DRYDOCK_HOME / compose file

The CLI resolves `DRYDOCK_HOME` by following the symlink at
`~/.local/bin/drydock` back to `<DRYDOCK_HOME>/bin/drydock`. If you moved the
drydock directory, re-create the symlink:

```bash
rm ~/.local/bin/drydock
ln -s /new/path/to/drydock/bin/drydock ~/.local/bin/drydock
```

Or set `DRYDOCK_HOME` explicitly in your environment.
