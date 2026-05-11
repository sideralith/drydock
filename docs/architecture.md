# drydock architecture

How the container is wired, what gets mounted, and why the storage is split
the way it is.

## Mount map

```
HOST                                CONTAINER (debian:12-slim)
─────────────────────────────────  ─────────────────────────────────
~/.engram/                          ~/.engram/  (container-specific)
  (host Claude's DB, untouched)       ← bind from ~/.engram-container/
                                       Init'd by `drydock setup` as a copy
                                       (auto-triggered on first run)

~/.claude/                          ~/.claude/  (container-specific)
  (host Claude's config dir)          ← bind from ~/.claude-container/
                                       Skills, plugins, hooks, settings visible

~/.claude.json                      ~/.claude.json  (container-specific)
  (project list, onboarding flags,    ← bind from ~/.claude-container.json
   MCP servers, OAuth account)          Without this, Claude Code in the
                                        container can't find its config file,
                                        creates a fresh ephemeral one, and
                                        "settings don't persist". MUST mount.

~/.claude/hooks/  ─────────────────→ ~/.claude/hooks/ :ro
  (authoritative)                     (RO overlay — agent can't self-edit)

~/.local/  ───────────────────────→ ~/.local/  :rw
  (binaries: claude, engram, etc.)    (shared — host upgrades propagate)

$PROJECT_DIR/  ───────────────────→ $PROJECT_DIR/  :rw
  (target project)                    (same path inside, so Makefile works)
$PROJECT_DIR/docs/ ───────────────→ $PROJECT_DIR/docs/  :rw
  (if 9P drvfs / sub-mount)           (explicit re-mount overlay)

/var/run/docker.sock  ────────────→ /var/run/docker.sock
  (host daemon)                       Container CLI → host daemon
                                       → `docker exec serendipilink-api …`

~/.gitconfig, ~/.config/gh/   ────→ same paths (gitconfig RO, gh RW)

NOT MOUNTED:
~/.ssh, ~/.aws, ~/.gnupg, ~/.kube, ~/.bash_history, other projects under ~/
```

## Two config locations

Claude Code reads its configuration from **two** places, and drydock mounts
both:

| Location | Type | Contains | Container sibling |
|---|---|---|---|
| `~/.claude/` | directory | skills, plugins, agents, commands, hooks, `settings.json`, `CLAUDE.md`, `mcp/*.json` | `~/.claude-container/` |
| `~/.claude.json` | single file | project registry, onboarding flags, "seen hints", `mcpServers`, OAuth account, various caches | `~/.claude-container.json` |

Forgetting the second one is a classic mistake: the container can't find
`~/.claude.json`, Claude Code creates a fresh one on the container's
ephemeral filesystem, and everything you configure in a session evaporates
on exit. drydock's `cmd_setup` creates both siblings; `cmd_sync` refreshes
both from host.

## Why the storage is split (host vs. container)

The container does **not** use the host's `~/.claude/`, `~/.claude.json`, or
`~/.engram/` directly. Each gets a container-specific sibling
(`~/.claude-container/`, `~/.claude-container.json`, `~/.engram-container/`),
initialized once as a copy.

Reasons:

1. **Engram SQLite/WAL contention**: engram's DB is SQLite in WAL mode. On
   WSL2, fcntl POSIX locks crossing the host↔container 9P boundary are
   historically unreliable. If host Claude (on another project) and container
   Claude both write to the same `engram.db` concurrently, worst case is WAL
   corruption. Separate DBs → zero contention.

2. **`~/.claude.json` is hot**: Claude Code rewrites it constantly (changelog
   fetch timestamps, "have you seen X", project `lastUsed` times, etc.).
   Shared between concurrent host + container sessions = constant last-writer-
   wins churn. Separate copies → no churn.

3. **OAuth refresh**: `~/.claude/.credentials.json` and `~/.claude.json`
   carry auth state. Concurrent refresh from two sessions = one invalidates
   the other. Separate copies sidestep this.

4. **Plugin install isolation**: `/plugin install foo` from inside the
   container lands in `~/.claude-container/plugins/` only — the host doesn't
   know. Useful as a reversible playground (see [lifecycle.md](lifecycle.md)).

Trade-off: the copies **diverge over time**. Skills/plugins/config installed
on host don't appear in the container until `drydock sync`. Engram memories
saved in one don't appear in the other (consolidate via `engram export` /
`engram import`). This is intentional — divergence is the price of
contention-free concurrent host + container sessions.

## The hooks RO overlay

`~/.claude/hooks/` is bind-mounted **`:ro`** on top of the `.claude-container`
mount (the second mount masks that subpath of the first). Effect: the agent
inside the container can read its hooks (e.g. `block-destructive.sh`, which
is a PreToolUse guardrail) but **cannot edit them**. Without this, the agent
could in principle disable its own guardrails — the protection would be
illusory under both adversarial behavior and ordinary bugs.

This means hook updates must happen on host. The container always sees the
host's authoritative hooks.

## How drydock decides what to mount

Each `drydock run` invocation reads the **current project directory** (cwd or
arg) and exports it as `PROJECT_DIR` to compose. The compose file uses
`${PROJECT_DIR}` for the project mounts. The image is universal — only the
env vars change per project (`PROJECT_DIR`, `PROJECT_NAME`, `USER_UID`,
`USER_GID`, `HOST_DOCKER_GID`, `COMPOSE_PROJECT_NAME`).

**Conditional `docs/` overlay**: if `$PROJECT_DIR/docs/` exists AND is a
separate filesystem mount point (typical on WSL2 where docs lives on Windows
via 9P drvfs), the CLI adds `docker-compose.docs.yml` as a second `-f`. This
re-mounts `docs/` explicitly — belt-and-suspenders, because Docker's
bind-mount-of-bind-mount propagation on WSL2 is historically flaky. If
`docs/` is on the same filesystem as the parent project (e.g. ext4 native),
no overlay — the parent mount covers it.

Detection: `awk '$2 == "$PROJECT_DIR/docs"' /proc/mounts` — non-empty means
it's a distinct mount point.

## Docker-out-of-Docker (DooD), not Docker-in-Docker

drydock bind-mounts `/var/run/docker.sock`. The `docker` CLI inside the
container talks to the **host's** daemon — it does NOT run a nested daemon.
So sibling containers in any project's `docker-compose` stack are visible:
`docker exec serendipilink-api …`, `make shell-api`, project Makefile
targets all work transparently.

Consequence: socket access ≈ root-equivalent on the host. This is why
drydock's threat model is "defense against accidents, not adversaries" — see
[security.md](security.md).

## Container base + UID/GID matching

Base image: `debian:12-slim`. Tooling installed: `docker-ce-cli`,
`docker-compose-plugin` (+ a `docker-compose` v1-name shim), `gh`, `make`,
`git`, `rsync`, `jq`, `curl`, plus `procps`/`vim-tiny`/`less`/`sudo` for
ergonomics.

The image is built with `USER_UID` / `USER_GID` / `HOST_DOCKER_GID` build
args (the CLI auto-detects from `id` and `stat /var/run/docker.sock`). The
container user `rai` is created with the matching UID/GID and added to a
group with the host's docker-socket GID. This ensures files created from
inside the container land on host with the user's ownership (not `root`) and
the docker socket is readable. Defensive `groupmod`/`groupadd` handles GID
collisions in the base image.
