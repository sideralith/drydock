# drydock

> A defense-in-depth sandbox for AI coding agents. Containerized workspace, host
> Docker socket access for project tooling, isolated memory and config from the
> host. Currently supports **Claude Code** with engram-aware memory split.

Multi-project, single-image. Onboard a new project with one command.

## What problem it solves

AI coding agents on the host can touch anything `$HOME` can touch. That's fine
most of the time, but accidents at scale add up. `drydock` puts the agent in
a Debian 12 slim container with:

- **Filesystem mounts limited to your project** — `~/.ssh`, `~/.aws`,
  `~/.gnupg`, `~/.kube`, and every other unrelated project under `~/` are not
  visible from inside.
- **Hooks read-only overlay** — the agent cannot self-edit its own guardrails
  (`~/.claude/hooks/block-destructive.sh` and similar).
- **Engram memory split** — container has its own SQLite DB so concurrent host
  Claude sessions on other projects don't race.
- **Docker-out-of-Docker** — `/var/run/docker.sock` bind-mounted means
  `docker exec`, `make shell-api`, project Makefiles all work transparently
  against your existing stack.

> **Threat model**: defense against agent **accidents** (rm against wrong
> path, write to wrong file). NOT a sandbox against an adversarial agent —
> Docker socket access ≈ root-equivalent on host. See *Security boundaries*
> below.

## Install

drydock is a per-user, host-side tool. There's no system-wide install.

```bash
# 1. Clone or copy this directory to ~/drydock/
git clone <repo> ~/drydock
# (or, if you bootstrapped manually as we did: this directory IS ~/drydock/)

# 2. Symlink the CLI into your PATH
mkdir -p ~/.local/bin
ln -s ~/drydock/bin/drydock ~/.local/bin/drydock
# (verify: drydock version)

# 3. Build the image (~5-10 min first time)
drydock build
```

Host-side runtime state (`~/.engram-container/`, `~/.claude-container/`,
`~/.claude-container.json`) is auto-created on first `drydock run`/`shell`/
`sync` if missing. You can force it with `drydock setup` but you rarely need
to.

## Use it on a project

### A. Existing project that already has `.claude/settings.json`

```bash
cd ~/git/myproject
drydock              # default: launches Claude Code in this project
```

### B. New project (no `.claude/` yet)

```bash
drydock init ~/git/newproject
cd ~/git/newproject && drydock
```

`drydock init` creates `.claude/settings.json` with a baseline of denies
(secrets, git policy bypass, branch deletions). Project-scoped so you can
commit it, the team can share it, rollback with `git checkout` if you don't
like it. Same mental model as `git init` — once per project.

### C. Other useful subcommands

```bash
drydock status        # short health: image, container DBs, docker socket
drydock doctor        # detailed diagnostics + cwd context
drydock shell         # bash inside container, no claude launch
drydock sync          # ~/.claude/ → ~/.claude-container/ (after host changes)
drydock build         # rebuild image
```

## Architecture

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

## How drydock decides what to mount

Each `drydock run` invocation reads the **current project directory** (cwd or
arg) and exports it as `PROJECT_DIR` to compose. The compose file uses
`${PROJECT_DIR}` for all mounts. The image is universal — only the env vars
change per project.

Special case: if `$PROJECT_DIR/docs/` exists AND is a separate filesystem
mount (typical on WSL2 where docs lives on Windows via 9P drvfs), the CLI
adds an explicit `docs/` overlay (`docker-compose.docs.yml`). Otherwise no
docs overlay — saves an unnecessary mount.

## Three rules to know

### 1. Engram memories diverge between host and container

After the first run (which auto-triggers `drydock setup`), container engram
is an independent SQLite DB. Memories saved in host Claude (any project) stay
on host. Memories saved in container Claude (any project) stay in container.
They do **not** auto-sync.

This is intentional — lets you run host Claude on other projects in parallel
without contention. If you ever need to consolidate:

```bash
# inside container or on host (both work):
engram export ~/engram-snapshot.json
# on the destination side:
engram import ~/engram-snapshot.json
```

### 2. Skills/plugins/hooks on host need an explicit `drydock sync`

Install a new skill or plugin on host? Or edit a hook? The change is NOT
visible in the container until:

```bash
drydock sync
```

Excludes `sessions/`, `projects/`, `file-history/`, `cache/`, `backups/`,
`telemetry/`, `plans/`, `tasks/` — your container's in-flight work is
preserved.

Plugins installed **from inside the container** stay only in the container's
`~/.claude-container/plugins/`. Use this as a playground for new plugins
without polluting host.

### 3. Don't edit the same file in host and container concurrently

The project tree is mounted RW from host to container. If you edit
`docs/foo.md` in Obsidian on host while Claude inside container is also
editing it, you get tearing — especially over 9P drvfs (WSL2 docs case).

For 9P mounts in particular, fcntl locks don't propagate reliably. The
pragmatic rule: don't have both writing the same file at the same instant.
Close the Obsidian tab before Claude edits, or wait for an idle moment to
edit in Obsidian.

## Subcommand reference

| Command | What it does |
|---|---|
| `drydock` | Default — `drydock run` in current directory |
| `drydock run [DIR]` | Launch Claude Code inside the container, mounted at DIR (or cwd) |
| `drydock shell [DIR]` | Bash shell inside the container at DIR — for debugging |
| `drydock init [DIR]` | Initialize a project — creates `.claude/settings.json` baseline (per-project, like `git init`) |
| `drydock build` | Build/rebuild `drydock:latest` |
| `drydock sync` | rsync `~/.claude/` → `~/.claude-container/` (excludes session state) |
| `drydock status` | Short health snapshot |
| `drydock doctor` | Full diagnostics: versions, paths, mount detection, GIDs |
| `drydock setup` | (advanced) Force host-side setup — auto-triggered on first run/build/sync; rarely needed explicitly |
| `drydock version` | Show version |
| `drydock help` | Show help |

## Plugin & binary lifecycle (where to update what)

The split-storage architecture means different things land in different
places. Read this once so you know the right place for each action.

| Action | Writes to | Shared host ↔ container? |
|---|---|---|
| Update binaries: `gentle-ai`, `claude`, `engram`, `gga`, `uv`, `node` | `~/.local/` | **YES** — mount RW |
| `/plugin install <x>` inside Claude | `~/.claude/plugins/` | **NO** — separate |
| Create/edit skill in `~/.claude/skills/` | `~/.claude/skills/` | **NO** — separate |
| Edit `~/.claude/CLAUDE.md` or `settings.json` (global) | `~/.claude/` | **NO** — separate |
| Onboarding flags, "seen hints", project registry, MCP servers, OAuth | `~/.claude.json` | **NO** — separate (`~/.claude-container.json`) |
| Edit `~/.claude/hooks/` | blocked from container (RO overlay) | host-only |
| Edits to `.claude/settings.json` of project | repo at `$PROJECT_DIR` | **YES** — same mount |
| engram memories (`mem_save`) | `~/.engram/engram.db` | **NO** — separate DBs |

### Practical rules

**Update binaries (gentle-ai, claude, engram, etc.) → do it on HOST.**

```bash
# on host:
gentle-ai self-update          # or whatever upgrade command
# container picks up the new version via ~/.local/ mount automatically
```

Why not from container? Some installer flows (`curl | sh`, pnpm/npm scripts,
uv packages) write to `~/.config/`, `~/.cache/`, `~/.bashrc`, system PATH —
paths NOT mounted from host. Update from container = partial update,
container `/tmp` pollution, doesn't persist.

**Engram update gets a specific recipe**: its binary in `~/.local/bin/engram`
is shared, but its plugin metadata in `~/.claude/plugins/cache/engram/` is
separate between host and container. Update from container leaves the new
binary in host with stale plugin metadata in host → skew. Correct recipe:

```bash
# on host:
gentle-ai update engram        # or canonical upgrade path
drydock sync                   # sync metadata host → container
```

**Plugins from Claude (`/plugin install foo`)**:

- **From container**: stays only in `~/.claude-container/plugins/`. Host
  doesn't know. Perfect for trying plugins without committing.
- **From host**: stays only in `~/.claude/plugins/`. Container doesn't see
  it until `drydock sync`.
- **No automatic promote**. If a plugin you tested in container convinces
  you, do `/plugin install foo` on host too.

**New skills**: same pattern. Create on host (canonical) + `drydock sync` so
container picks up.

### Mental model

- **`~/.local/`** = **shared toolchain**. Source of truth = host.
- **`~/.claude/`** = **isolated workspace**. Container is **reversible
  playground**; host is **canonical**.

## Security boundaries — be honest with yourself

What this **does** protect against:
- `rm -rf ~/.ssh` typo — the path isn't mounted.
- `rm -rf /` accidental — container's `/` is the container's, not host's.
- Read of `~/.aws/credentials` — not mounted.
- Self-modification of `~/.claude/hooks/block-destructive.sh` — RO overlay.

What this **does NOT** protect against:
- Adversarial agent running `docker run -v /:/host --privileged alpine sh`
  via the mounted socket — that's root on host. The socket is
  root-equivalent.
- Agent committing nonsense to the project tree (project IS mounted RW).
- Agent reading anything inside the project, including `.env`. Mitigated by
  `Read(.env)` deny in your global `~/.claude/settings.json` (set this up
  yourself; not part of drydock).

If you need adversarial-resistant isolation, layer
[`Tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy)
or [`cetusguard`](https://github.com/cetusguard/cetusguard) in front of the
socket and tighten the API endpoints. Out of scope here.

## Troubleshooting

### `docker exec` from inside the container fails with permission denied

Container user must be in a group matching the host's docker socket GID.
Check on host:

```bash
stat -c '%g' /var/run/docker.sock
```

If different from `HOST_DOCKER_GID` (default 1001), rebuild with the right
value:

```bash
HOST_DOCKER_GID=999 drydock build
```

The CLI auto-detects on each build by default — manual override only if
needed.

### `claude` not found inside container

The binary lives at `~/.local/bin/claude` on host, bind-mounted into
container. If PATH doesn't include `~/.local/bin`, check `ENV PATH` in the
Dockerfile.

### "Claude configuration file not found at: /home/rai/.claude.json" / settings don't persist

Claude Code reads config from TWO locations: the `~/.claude/` **directory**
(skills, plugins, settings.json) AND the `~/.claude.json` **file** (project
list, onboarding flags, MCP servers, OAuth). drydock must mount both. If
`~/.claude-container.json` doesn't exist on host, Claude Code inside the
container can't find `~/.claude.json`, creates a fresh one on the container's
ephemeral filesystem, and any config you do (onboarding, theme, hints) is
lost when the container exits.

Fix:

```bash
cp -a ~/.claude.json ~/.claude-container.json    # or: drydock setup
```

`drydock setup` auto-creates it. `drydock sync` refreshes it from host. The
compose file mounts `~/.claude-container.json:/home/rai/.claude.json:rw`.

### Engram returns "no memories" inside container

Verify `~/.engram-container/engram.db` exists on host with size > 0:

```bash
ls -la ~/.engram-container/
```

If empty, re-init:

```bash
rm -rf ~/.engram-container
drydock setup
```

### Files created from container appear as `root` on host

UID/GID mismatch. Check on host:

```bash
id            # UID/GID must match what drydock build used
```

Rebuild:

```bash
USER_UID=$(id -u) USER_GID=$(id -g) drydock build
```

### gh CLI fails with "failed to write config after migration"

`~/.config/gh` must be RW (it migrates `hosts.yml` schema on first run).
This is the default in drydock. If you changed it to `:ro`, revert.

### Image doesn't pick up changes to Dockerfile

`drydock build` always rebuilds. If you suspect a stale cache:

```bash
docker image rm drydock:latest
drydock build
```

## Roadmap

drydock today is Claude Code-focused. Adapter pattern for other agents is on
the table:

- [ ] **Codex CLI** adapter — different config dir, different settings schema
- [ ] **OpenCode** adapter
- [ ] **pi.dev** adapter
- [ ] **Multi-agent rotation** — same `drydock` infra, switch between agents
  on demand
- [ ] **Per-project drydock profiles** — different deny lists / mount sets
  for sensitive vs. public projects
- [ ] **Socket-proxy integration** — optional `cetusguard` / `Tecnativa`
  layer for adversarial threat models
- [ ] **macOS support** — Docker Desktop quirks around `/var/run/docker.sock`
  and gRPC FUSE perf
- [ ] **Cloud sandbox mode** — same architecture but in a remote VM

PRs welcome. The architecture (engram split + state split + hooks RO + DooD)
is agent-agnostic; only the mount paths and config formats differ per agent.

## License

(decide per maintainer — MIT recommended)

## Acknowledgments

Built as part of the [Sideralith](https://sideralith.com) toolchain. Inspired
by long days losing sleep over what an unsupervised AI agent might do to
`~/.ssh` if you blinked.
