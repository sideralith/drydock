<div align="center">

<img src="assets/drydock-logo.svg" alt="drydock" width="128" />

# drydock

**A defense-in-depth sandbox for AI coding agents.**

</div>

> Containerized workspace, host Docker socket access for project tooling,
> isolated memory and config from the host. Multi-project, single-image.
>
> Currently supports **Claude Code** (engram-aware). Adapters for other agents
> are on the [roadmap](#roadmap).

<!-- badges placeholder: CI · license · version -->

## What problem it solves

AI coding agents on the host can touch anything `$HOME` can touch. That's fine
most of the time, but accidents at scale add up. `drydock` runs the agent in a
Debian 12 slim container that:

- **Mounts only your project** — `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`,
  and every other unrelated project under `~/` aren't visible from inside.
- **RO-overlays the agent's hooks** — it can't self-edit its own guardrails.
- **Splits memory and config** — the container has its own
  [engram](https://github.com/Gentleman-Programming/engram) DB (optional —
  see [Using drydock without engram](#using-drydock-without-engram)) and its own
  `~/.claude/` + `~/.claude.json` siblings, so concurrent host sessions on
  other projects don't race.
- **Bind-mounts the Docker socket (DooD)** — the containerized agent talks to
  your host Docker daemon, so it can bring your project's stack up, `docker exec`
  into a running service, and run its tests or migrations against the host
  containers, exactly as from the host.

> **Threat model**: defense against agent **accidents**, not against an
> adversarial agent — Docker socket access ≈ root-equivalent on the host.
> Read [docs/security.md](docs/security.md) before relying on it.

## Quick start

drydock is a per-user, host-side tool — no system-wide install.

```bash
# 1. Get the repo into ~/drydock/ (or anywhere; the CLI follows the symlink)
git clone <repo-url> ~/drydock

# 2. Symlink the CLI into your PATH
mkdir -p ~/.local/bin
ln -s ~/drydock/bin/drydock ~/.local/bin/drydock
drydock version          # verify

# 3. Build the image (~5-10 min first time)
drydock build

# 4. Run it on a project
cd ~/git/myproject
drydock                  # launches Claude Code in this project, sandboxed
```

Host-side runtime state (`~/.engram-container/`, `~/.claude-container/`,
`~/.claude-container.json`) is auto-created on first run. You never call
`drydock setup` directly unless you want to.

## Usage

```bash
# Existing project (already has .claude/settings.json):
cd ~/git/myproject && drydock

# New project — seed a minimal .claude/settings.json stub (git-init mental model):
drydock init ~/git/newproject
cd ~/git/newproject && drydock

# Other commands:
drydock shell [DIR]      # bash inside the container — for debugging
drydock status           # short health snapshot
drydock doctor           # detailed diagnostics + cwd context
drydock sync             # refresh container's ~/.claude/ + ~/.claude.json from host
drydock build            # rebuild the image
```

Inside the container, everything works as on host: `docker compose` against
your stack, `docker exec` into a service, `curl http://localhost:PORT/...`,
`git`, `gh`, etc. Whatever your project wraps those in (a Makefile, npm
scripts, a justfile) runs the same way.

| Command | What it does |
|---|---|
| `drydock` / `drydock run [DIR]` | Launch Claude Code in DIR (or cwd), sandboxed |
| `drydock init [DIR]` | Per-project setup: seed a minimal `.claude/settings.json` stub for your own customization (drydock's deny policy is image-baked, applies automatically) |
| `drydock shell [DIR]` | Bash shell inside the container at DIR |
| `drydock sync` | Refresh container config (`~/.claude/`, `~/.claude.json`) from host |
| `drydock build` | Build/rebuild `drydock:latest` |
| `drydock status` / `doctor` | Health snapshot / full diagnostics |
| `drydock setup` | (advanced) Force host-side init — auto-triggered; rarely explicit |
| `drydock version` / `help` | Self-explanatory |

## Multi-mount projects

Some projects have sub-directories that are separate filesystem mounts — for
example, an Obsidian vault bind-mounted via WSL2's 9P drvfs layer:

```bash
# Example: ~/git/myproject/docs is a drvfs bind from Windows
ls ~/git/myproject/docs   # works on host — files visible
drydock shell
ls ~/git/myproject/docs  # empty without sub-mount propagation!
```

drydock automatically detects sub-mounts under `${PROJECT_DIR}` and generates
a temporary compose overlay that propagates them into the container. Run
`drydock doctor` to see what was detected:

```
── sub-mounts under /home/you/git/myproject ──
  ✓ /home/you/git/myproject/docs → /mnt/c/Users/You/Documents/Obsidian/Vaults/MyProject (drvfs auto-translated)
  ✓ /home/you/git/myproject/data → /data/foo (Linux-native bind)
  ⚠ /home/you/git/myproject/nfsmount → server:/export (nfs, may not propagate)
```

Three classes of sub-mount:

| Class | Example | Behaviour |
|---|---|---|
| **drvfs** (WSL2 9P) | Obsidian vault, OneDrive folder | Auto-translated to `/mnt/<drive>/...` — Docker Desktop reads it |
| **Linux-native** | `mount --bind /data/src ~/git/proj/bind` | Source path translated via `/proc/self/mountinfo` lookup |
| **Exotic** (nfs, cifs, fuse, tmpfs) | NFS share, SSHFS mount | Passed through with a warning — propagation not guaranteed |

If a sub-mount does not appear inside the container, see
[docs/troubleshooting.md](docs/troubleshooting.md#sub-mount-not-visible-inside-the-container).

## Using drydock without engram

**Engram is optional.** drydock works cleanly without it:

- `drydock setup`, `drydock run`, `drydock build`, and `drydock sync` all
  work without engram installed.
- When engram is absent (or when the host is macOS), the engram volume overlay
  is not activated and the engram MCP server entry is removed from the
  container's `~/.claude-container.json` — Claude Code sees no startup errors.
- `drydock status` reports `engram: not detected (opt-in)` — not an error.

If you later install engram, re-run `drydock setup` and the overlay activates
automatically on the next `drydock run`.

### Shared vs isolated engram

By default, drydock gives the container its own engram DB (`~/.engram-container`,
isolated mode). This prevents SQLite lock contention between a host session and
a container session.

**Opt-in to shared mode** (host and container share one DB):
```bash
mkdir -p ~/.config/drydock
touch ~/.config/drydock/engram-shared
```

Remove the file to return to isolated mode.

**Warning**: switching isolated → shared is **lossy** without preparation. Any
memories accumulated in `~/.engram-container` won't automatically appear in the
shared `~/.engram`. Before switching, export the container memories first:
1. Inside the container: `engram sync` (exports new memories as chunks)
2. On the host: `engram sync --import` (absorbs them)

drydock does **not** provide a migration tool. If you skip this step, isolated
container memories are inaccessible in shared mode (the `~/.engram-container`
directory is orphaned but not deleted — you can import from it later).

**Safety gate**: on WSL2 and macOS hosts, POSIX file locks over the
host↔container bind-mount layer are unreliable. drydock automatically downgrades
shared mode to isolated on these hosts and emits a warning. To override:
`DRYDOCK_ENGRAM_SHARED=force drydock run` (bypasses the safety check — you
accept the risk of SQLite WAL corruption if host and container Claude write
concurrently).

**macOS note**: engram ships native macOS Mach-O builds
(`brew install gentleman-programming/tap/engram`) and the DB directory can be
bind-mounted. However, the macOS binary cannot run inside the Debian Linux
container. drydock v0.1.0 treats macOS as engram-effectively-absent for the
container; future releases may ship a Linux engram in the image or bridge via
its HTTP API.

## Three rules to know

1. **Engram memories diverge between host and container (isolated mode).** The
   container has its own engram DB (`~/.engram-container/`). Memories don't
   auto-sync between host and container. Consolidate with `engram sync --import`
   / `engram sync --export`. This is intentional — it prevents SQLite
   contention when running host Claude concurrently.

2. **Skills/plugins/hooks installed on host need an explicit `drydock sync`.**
   Until you sync, the container has its snapshot. Plugins installed *from
   inside* the container stay container-only — handy as a reversible
   playground. (Details: [docs/lifecycle.md](docs/lifecycle.md).)

3. **Don't edit the same file in host and container concurrently.** The
   project tree is mounted RW both ways; concurrent writes to the same file
   can tear, especially over 9P drvfs (WSL2 docs case). Close the host-side
   editor before letting the agent edit, or wait for an idle moment.

## Architecture

The container runs the Claude CLI + engram MCP + your plugins/skills, with the
Docker socket bind-mounted (Docker-out-of-Docker — talks to the host's daemon,
no nested daemon). Host config lives in two places (`~/.claude/` directory and
`~/.claude.json` file); drydock mounts container-specific siblings of both, an
engram DB sibling, the project tree, and the docker socket. Hooks are RO. The
image is universal — only env vars (`PROJECT_DIR` etc.) change per project; a
dynamically-generated overlay propagates sub-mounts under `$PROJECT_DIR`.

Full mount map, the two-config-location detail, the split rationale, and the
sub-mount propagation design: **[docs/architecture.md](docs/architecture.md)**.

**Container hardening (v0.1.1+):** `docker-compose.hardening.yml` is auto-applied on every
invocation (caps dropped, no-new-privileges, `/tmp` size-bounded to 1 GB by default). Two
env-var knobs:

| Env var | Effect |
|---|---|
| `DRYDOCK_NO_HARDENING=1` | Nuclear opt-out — disables the hardening overlay entirely for one invocation |
| `DRYDOCK_TMPFS_SIZE=<size>` | Override `/tmp` size cap (e.g. `4g`, `512m`) — hardening otherwise active |

See [docs/security.md](docs/security.md) for the cap list rationale.

**Managed-settings layer (v0.2.0+):** drydock's tier-1 agent policy — the `permissions.deny`
secret/git-safety block and the `hooks.SessionStart` entry — ships image-baked as a Claude Code
managed-settings drop-in (`/etc/claude-code/managed-settings.d/`, root-owned). It applies
automatically with zero per-project setup and cannot be weakened from a project's
`.claude/settings.json`. `drydock init` seeds a minimal per-project stub for your own
customization; the policy itself lives in the image.

## Documentation

- **[docs/architecture.md](docs/architecture.md)** — mount map, storage split
  rationale, hooks RO overlay, DooD, UID/GID matching, conditional overlays.
- **[docs/lifecycle.md](docs/lifecycle.md)** — where to update what (binaries
  vs. plugins vs. skills vs. config), the engram-update recipe, mental model.
- **[docs/security.md](docs/security.md)** — what drydock does and does NOT
  protect against; when to layer a socket proxy.
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — common failures
  and fixes.
- **[docs/ROADMAP.md](docs/ROADMAP.md)** — the canonical backlog: what is
  planned, why, and in which release.

## Roadmap

See **[docs/ROADMAP.md](docs/ROADMAP.md)** — the canonical backlog: what is
planned, why, and in which release.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the testing
and lint contract, the PR flow, and how to file a bug.

## License

MIT — see [LICENSE](LICENSE).

## Credits

Built as part of the [Sideralith](https://sideralith.com) toolchain. Born from
losing sleep over what an unsupervised AI agent might do to `~/.ssh` if you
blinked.
