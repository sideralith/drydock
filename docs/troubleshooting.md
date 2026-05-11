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

## `docs/` content not visible inside the container

If your project's `docs/` is a separate filesystem mount (e.g. WSL2 9P drvfs
from Windows), drydock should auto-add the `docs/` overlay. Verify:

```bash
cd ~/git/yourproject && drydock doctor
# Look for: "docs/: separate mount (9P or similar) → docs overlay activates"
```

If it says "docs/: local" but you know it's a separate mount, check
`awk '$2 == "/abs/path/to/yourproject/docs"' /proc/mounts` returns a line.

## drydock can't find DRYDOCK_HOME / compose file

The CLI resolves `DRYDOCK_HOME` by following the symlink at
`~/.local/bin/drydock` back to `<DRYDOCK_HOME>/bin/drydock`. If you moved the
drydock directory, re-create the symlink:

```bash
rm ~/.local/bin/drydock
ln -s /new/path/to/drydock/bin/drydock ~/.local/bin/drydock
```

Or set `DRYDOCK_HOME` explicitly in your environment.
