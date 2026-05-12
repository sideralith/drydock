# drydock architecture

How the container is wired, what gets mounted, and why the storage is split
the way it is.

## Mount map

```
HOST                                CONTAINER (debian:12-slim)
─────────────────────────────────  ─────────────────────────────────
~/.engram-container/   (optional)   ~/.engram/  ← isolated mode (default)
  or ~/.engram/        (opt-in)         overlay active only when engram is
  (see "engram" section below)          usable (Linux host + binary on PATH)

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

**Env passthrough**: `GITHUB_PERSONAL_ACCESS_TOKEN` is forwarded from the
invoking shell (if set) so the GitHub MCP server and `gh` PAT auth work inside
the container — the only host env var drydock passes through. `docker compose
run` does not inherit the host environment, so this is an explicit
`environment:` entry in `docker-compose.yml`. `~/.config/gh` (mounted above)
covers `gh` CLI OAuth separately; the env var covers tools that read it directly.

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

## engram (optional)

engram is **not required**. drydock detects it and activates the overlay only
when both conditions are true: the `engram` binary is on the host's `$PATH`
AND the host OS is Linux. On a macOS host the binary is a native Mach-O
executable — it cannot run inside the Debian container, so drydock treats it as
absent regardless of `$PATH`.

When engram is not detected, `drydock setup`, `drydock run`, and all other
commands work without engram-related errors or startup noise. The engram MCP
server entry is removed from the container's `~/.claude-container.json` so
Claude Code doesn't try to spawn a missing binary.

### Topologies

| Mode | DRYDOCK_ENGRAM_SOURCE | When |
|------|----------------------|------|
| **Not detected** | — (overlay omitted) | No `engram` on PATH or macOS host |
| **Isolated** (default) | `~/.engram-container` | engram usable, no sentinel |
| **Shared** (opt-in) | `~/.engram` | engram usable + `~/.config/drydock/engram-shared` exists |

Isolated is the default and is always safe. Shared mounts the host's live DB
directly — the host and container agents share the same memories — but it
carries risk on WSL2 and macOS because POSIX file locks over those filesystems'
container bind-mount layers are unreliable.

### Safety downgrade (WSL2 / macOS + shared requested)

When shared mode is requested but the host's container bind-mount layer has
unreliable POSIX file locks — detected when `/proc/sys/kernel/osrelease`
contains `microsoft` (WSL2) or `uname -s` returns `Darwin` — drydock
automatically falls back to isolated mode and emits a `warn` explaining why.
Set `DRYDOCK_ENGRAM_SHARED=force` to override the downgrade (the sentinel must
still be present; `=force` alone does nothing).

### macOS limitation and future paths

On macOS, the host `engram` binary is a Mach-O executable and cannot run in
the Debian Linux container. Two paths that would fix this for a future release:

1. **Linux engram in image** — build a `linux_amd64`/`linux_arm64` engram
   binary into the image at build time (adds ~10 MB, pins the version).
2. **HTTP-API bridge** — run `engram` on the host with
   `ENGRAM_CLOUD_HOST=0.0.0.0` (port 7437) and configure the container's MCP
   server to reach it via the host network (already shared via `network_mode:
   host`). No binary inside the container needed.

Neither is implemented in v0.1.0.

## Why the storage is split (host vs. container)

The container does **not** use the host's `~/.claude/`, `~/.claude.json`, or
`~/.engram/` directly. Claude config gets container-specific siblings
(`~/.claude-container/`, `~/.claude-container.json`), initialized once as a
copy. Engram uses `~/.engram-container/` when isolated mode is active, or the
host's `~/.engram/` directly when shared mode is active.

Reasons (Claude config split — always applies):

1. **`~/.claude.json` is hot**: Claude Code rewrites it constantly (changelog
   fetch timestamps, "have you seen X", project `lastUsed` times, etc.).
   Shared between concurrent host + container sessions = constant last-writer-
   wins churn. Separate copies → no churn.

2. **OAuth refresh**: `~/.claude/.credentials.json` and `~/.claude.json`
   carry auth state. Concurrent refresh from two sessions = one invalidates
   the other. Separate copies sidestep this.

3. **Plugin install isolation**: `/plugin install foo` from inside the
   container lands in `~/.claude-container/plugins/` only — the host doesn't
   know. Useful as a reversible playground (see [lifecycle.md](lifecycle.md)).

Reasons (engram isolated — the default):

1. **SQLite/WAL contention**: engram's DB is SQLite in WAL mode. On WSL2,
   fcntl POSIX locks crossing the host↔container 9P boundary are historically
   unreliable. If host Claude (on another project) and container Claude both
   write to the same `engram.db` concurrently, worst case is WAL corruption.
   Separate DBs → zero contention. On native Linux the bind mount is a local
   filesystem path and locking is reliable, which is why shared mode is allowed
   there (with a caveat warn).

Trade-off: the copies **diverge over time**. Skills/plugins/config installed
on host don't appear in the container until `drydock sync`. Engram memories
saved in isolated mode don't appear in the host DB (consolidate via `engram
sync --import`). This is intentional — divergence is the price of
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
