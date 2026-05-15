# drydock troubleshooting

Common failures and fixes. Run `drydock doctor` first — it shows versions,
paths, mount detection, and GIDs.

## "Claude configuration file not found at: /home/rai/.claude.json" / settings don't persist

Claude Code reads config from TWO locations: the `~/.claude/` **directory**
(skills, plugins, `settings.json`, `CLAUDE.md`, hooks) AND the `~/.claude.json`
**file** (project list, onboarding flags, `mcpServers`, OAuth). drydock must
mount both. If `~/.claude-container.json` doesn't exist on host, Claude Code
inside the container can't find `~/.claude.json`, creates a fresh one on the
container's ephemeral filesystem, and any config you do (onboarding, theme,
hints) is lost when the container exits.

Fix:

```bash
cp -a ~/.claude.json ~/.claude-container.json    # or: drydock setup
```

`drydock setup` auto-creates it. `drydock sync` refreshes it from host. The
compose file mounts `~/.claude-container.json:/home/rai/.claude.json:rw`.

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
literal `./docs` path. Inside drydock, the env var is exported and
auto-substituted.

**Why this gap exists**: drydock's sub-mount propagation rewrites paths for
its own container, but cannot intercept arbitrary `docker compose` calls the
agent makes internally — those go directly to the host daemon via the
bind-mounted socket. Exposing the translated path as an env var lets each
project opt in explicitly in its compose file.

## drydock can't find DRYDOCK_HOME / compose file

The CLI resolves `DRYDOCK_HOME` by following the symlink at
`~/.local/bin/drydock` back to `<DRYDOCK_HOME>/bin/drydock`. If you moved the
drydock directory, re-create the symlink:

```bash
rm ~/.local/bin/drydock
ln -s /new/path/to/drydock/bin/drydock ~/.local/bin/drydock
```

Or set `DRYDOCK_HOME` explicitly in your environment.
