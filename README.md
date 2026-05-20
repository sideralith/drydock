<div align="center">

<img src="assets/drydock-logo.svg" alt="drydock" width="128" />

# drydock

**A defense-in-depth sandbox for AI coding agents.**

</div>

> Containerized workspace, host Docker socket access for project tooling,
> isolated memory and config from the host. Multi-project, single-image.
>
> Currently supports **Claude Code**. Adapters for other agents are on the
> [roadmap](#roadmap).

<!-- badges placeholder: CI · license · version -->

## What problem it solves

AI coding agents on the host can touch anything `$HOME` can touch. That's fine
most of the time, but accidents at scale add up. `drydock` runs the agent in a
Debian 12 slim container that:

- **Mounts only your project** — `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`,
  and every other unrelated project under `~/` aren't visible from inside.
- **RO-overlays the agent's hooks, image-bakes its deny policy** — it can't self-edit either its hook scripts or its git/OS destructive-command guardrails.
- **Splits memory and config** — the container gets its own `~/.claude/` +
  `~/.claude.json` siblings, so concurrent host sessions on other projects don't
  race; and each concurrent session for the same project gets its own siblings
  too. If you use the optional [engram](docs/engram.md) memory server, it gets
  an isolated container DB too.
- **Runs multiple sessions on one project** — launch `drydock` several times for
  the same repo (a human session alongside an agent, or two parallel agents on
  different branches); each gets its own container and isolated Claude config, so
  concurrent sessions never clobber each other's settings or auth state.
- **Bind-mounts the Docker socket (DooD)** — the containerized agent talks to
  your host Docker daemon, so it can bring your project's stack up, `docker exec`
  into a running service, and run its tests or migrations against the host
  containers, exactly as from the host.

> **Threat model**: defense against agent **accidents**, not against an
> adversarial agent — Docker socket access ≈ root-equivalent on the host.
> Read [docs/security.md](docs/security.md) before relying on it.

### Claude Code's sandbox mode vs. drydock

> They work at different scopes and are not interchangeable. Claude Code's sandbox mode contains individual **commands**; drydock containerizes the whole **session** and gives it an environment.

| | Claude Code sandbox mode | drydock |
|---|---|---|
| **What it is** | A feature *inside* Claude Code (off by default; enable with `/sandbox`) | The workspace Claude Code runs *inside* (you launch it with the `drydock` CLI) |
| **Scope** | Each Bash command and its subprocesses | The whole session and its environment |
| **What it's for** | Contain a command's blast radius; cut permission prompts | A reproducible, credential-isolated dev environment |
| **Filesystem** | Writes limited to the working directory; reads allowed everywhere by default | Host `~/.ssh`, `~/.gnupg`, `~/.aws`… are not mounted at all — invisible, not merely write-protected |
| **Network** | Per-command domain allowlist | Inherits the container's network — not per-command |
| **Reproducible environment** | No — it restricts the host you already have | Yes — pinned Debian image + defined toolchain |
| **State** | Uses the host's Claude state as-is — no separation | Separate container state — host and container sessions don't race |
| **Mechanism** | OS sandbox — Seatbelt (macOS), bubblewrap (Linux) | Docker container |
| **Threat model** | A real OS boundary for a command's writes/network (the network proxy does not inspect TLS) | Accidents, not adversaries — the bind-mounted Docker socket is root-equivalent on the host by design (INV-6) |

**Which one applies.** In practice you use one, by context. Running Claude Code directly on the host — its sandbox mode contains each Bash command. Running it through drydock — the container is the containment. Claude Code's sandbox does **not** run inside a drydock container as drydock ships today: the image includes no bubblewrap, and the container does not permit the unprivileged user namespaces the Linux sandbox is built on.

**drydock's security layers:**

- **Credential isolation** — the host's SSH and GPG keys are never mounted into the container (INV-1).
- **Tamper-proof guardrails** — an image-baked `permissions.deny` policy plus a read-only `PreToolUse` hook; the agent cannot edit its own guardrails (INV-3).
- **Container hardening** — dropped Linux capabilities, `no-new-privileges`, and a size-bounded `/tmp` (INV-8).

These raise the floor against agent *accidents* — not an adversarial sandbox. Full detail in [docs/security.md](docs/security.md).

## Quick start

drydock is a per-user, host-side tool — no system-wide install.

**Recommended — interactive install (real terminal):**

```bash
git clone https://github.com/sideralith/drydock.git ~/drydock
cd ~/drydock && ./install.sh
```

When run in a terminal, the installer prompts to: (a) enable shared engram
mode (native Linux only — INV-5), (b) build the Docker image now (~5 min),
and (c) add `~/.local/bin` to your shell rc file. Every prompt defaults to
"no" — pressing Enter keeps the safe defaults.

**One-line / fresh-machine install:**

```bash
curl -fsSL https://raw.githubusercontent.com/sideralith/drydock/main/install.sh | bash
```

The piped install is fully non-interactive — no prompts. It clones the repo
and creates the symlink, then stops. Run `drydock build` and add
`~/.local/bin` to PATH yourself (the installer prints the exact export line).

**After either install:**

```bash
cd <project> && drydock   # launches Claude Code in this project, sandboxed
```

Host-side runtime state is auto-created on first run: `~/.engram-container/`
(engram DB, optional), `~/.claude-container/` + `~/.claude-container.json`
(the per-session config **prototype**), and a per-session
`~/.claude-container-<disc>/` + `~/.claude-container-<disc>.json` pair (the
live bind-mount sources for this run, seeded from the prototype). You never
call `drydock setup` directly unless you want to.

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
| `drydock` / `drydock run [DIR]` | Launch Claude Code in DIR (or cwd), sandboxed — run it again for the same project to get a second concurrent session |
| `drydock init [DIR]` | Per-project setup: seed a minimal `.claude/settings.json` stub for your own customization (drydock's deny policy is image-baked, applies automatically) |
| `drydock shell [DIR]` | Bash shell inside the container at DIR |
| `drydock link [--rw] <PATH> [CONTAINER-PATH]` | Mount a sibling project inside the container at `/workspace-siblings/<name>` (or a custom path). Without `--rw`: read-only mount, no key needed. With `--rw`: read-write mount; generates a per-sibling deploy key and managed SSH config so the agent can `git push` from the sibling without exposing `~/.ssh/`. |
| `drydock unlink PATH` | Remove a sibling mount from the current project's list |
| `drydock links` | Show all sibling mounts configured for the current project |
| `drydock sync` | Refresh container config (`~/.claude/`, `~/.claude.json`) from host — runs automatically when the container copy is stale (set `DRYDOCK_SKIP_AUTOSYNC=1` to disable) |
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

> **Optional — engram memory:** drydock integrates the [engram](docs/engram.md)
> persistent-memory MCP server if it is already installed on your host. Entirely
> optional — see [docs/engram.md](docs/engram.md).

## Two rules to know

1. **Skills/plugins/hooks installed on host need an explicit `drydock sync`.**
   Until you sync, the container has its snapshot. Plugins installed *from
   inside* the container stay container-only — handy as a reversible
   playground. (Details: [docs/lifecycle.md](docs/lifecycle.md).)

2. **Don't edit the same file in host and container concurrently.** The
   project tree is mounted RW both ways; concurrent writes to the same file
   can tear, especially over 9P drvfs (WSL2 docs case). Close the host-side
   editor before letting the agent edit, or wait for an idle moment. The same
   caveat applies to two concurrent drydock sessions on one project: their
   Claude config is per-session isolated and safe, but the shared project tree
   is not — coordinate edits.

## Architecture

The container runs the Claude CLI, your plugins/skills, and — optionally — the
engram MCP server (see [docs/engram.md](docs/engram.md)), with the Docker socket
bind-mounted (Docker-out-of-Docker — talks to the host's daemon, no nested
daemon). Host config lives in two places (`~/.claude/` directory and
`~/.claude.json` file); drydock mounts per-session container-specific siblings
of both (seeded from a shared prototype each run), the project tree, and the
docker socket. Hooks are RO. The image is universal — only
env vars (`PROJECT_DIR` etc.) change per project; a dynamically-generated overlay
propagates sub-mounts under `$PROJECT_DIR`. A second dynamically-generated overlay
mounts linked sibling projects (see `drydock link` and [docs/links.md](docs/links.md)).

Full mount map, the two-config-location detail, the split rationale, and the
sub-mount propagation design: **[docs/architecture.md](docs/architecture.md)**.

**Auto-sync (v0.2.0+):** `drydock run` / `drydock shell` check whether the container's `~/.claude/`
snapshot is stale (via an mtime sentinel) and run `drydock sync` automatically before starting the
session. Silent on the happy path. Set `DRYDOCK_SKIP_AUTOSYNC=1` to skip.

**Container hardening (v0.1.1+):** `docker-compose.hardening.yml` is auto-applied on every
invocation (caps dropped, no-new-privileges, `/tmp` size-bounded to 1 GB by default). Two
env-var knobs:

| Env var | Effect |
|---|---|
| `DRYDOCK_NO_HARDENING=1` | Nuclear opt-out — disables the hardening overlay entirely for one invocation |
| `DRYDOCK_TMPFS_SIZE=<size>` | Override `/tmp` size cap (e.g. `4g`, `512m`) — hardening otherwise active |

See [docs/security.md](docs/security.md) for the cap list rationale.

**Managed-settings layer (v0.2.0+):** drydock's tier-1 agent policy ships image-baked as Claude Code
managed-settings drop-ins (`/etc/claude-code/managed-settings.d/`, root-owned). It applies
automatically with zero per-project setup and cannot be weakened from a project's
`.claude/settings.json`. `drydock init` seeds a minimal per-project stub for your own
customization; the policy itself lives in the image.

The policy includes a **destructive-command guardrail layer**: a declarative deny set
(`10-git-safety.json`, `30-os-safety.json`) covering protected-branch ops, history-rewrite,
OS-level destruction, and docker host-escape, plus a `PreToolUse` hook
(`drydock-block-destructive.sh`) for the five residue classes the deny mechanism cannot express
(ssh-to-prod, fork bomb, `rm .`/`.git`, parent-traversal `rm`, pipe-to-shell). Both tiers are
tamper-proof by image-layer ownership. If you have a personal `~/.claude/hooks/block-destructive.sh`
from previous drydock guidance, **you can delete it** — the shipped version covers the same rules
plus docker-wrapped variants. See [docs/security.md](docs/security.md#if-you-have-a-personal-block-destructivesh-hook).

## Documentation

- **[docs/architecture.md](docs/architecture.md)** — mount map, storage split
  rationale, hooks RO overlay, DooD, UID/GID matching, conditional overlays.
- **[docs/lifecycle.md](docs/lifecycle.md)** — where to update what (binaries
  vs. plugins vs. skills vs. config), mental model.
- **[docs/links.md](docs/links.md)** — sibling project links (`drydock link`):
  the three commands, RO and RW modes, host-path-mirror pattern, list-file
  format, per-sibling deploy keys, managed SSH config, and unlink lifecycle.
- **[docs/engram.md](docs/engram.md)** — the optional engram persistent-memory
  integration: detection, shared vs isolated mode, setup, migration.
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
