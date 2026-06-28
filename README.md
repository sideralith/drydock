<div align="center">

<img src="assets/drydock-logo.svg" alt="drydock" width="128" />

# drydock

**A defense-in-depth sandbox for AI coding agents.**

</div>

> Containerized workspace with isolated memory and config from the host —
> contained by default, with an opt-in Docker-out-of-Docker mode for stack
> tooling. Multi-project, single-image.
>
> Currently supports **Claude Code**. Adapters for other agents are on the
> [roadmap](#roadmap).

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
- **Contained by default; opt-in Docker-out-of-Docker (DooD)** — by default the
  container has no Docker socket and no host networking (contained mode). Opt a
  project into dood mode (`drydock dood <proj>`) and the agent talks to your host
  Docker daemon, so it can bring your project's stack up, `docker exec` into a
  running service, and run its tests or migrations against the host containers,
  exactly as from the host. In contained mode the agent reaches the network only
  through a drydock-managed deny-by-default domain allowlist (egress jail) —
  extend it via `~/.config/drydock/egress-allowlist`.

> **Threat model**: defense against agent **accidents**, not against an
> adversarial agent. In opt-in dood mode the Docker socket is root-equivalent on
> the host; contained mode (the default) removes the socket and host networking
> and jails egress behind a deny-by-default domain allowlist (named residual gaps
> in [docs/security.md](docs/security.md)). Read it before relying on it.

### Claude Code's sandbox mode vs. drydock

> They work at different scopes and are not interchangeable. Claude Code's sandbox mode contains individual **commands**; drydock containerizes the whole **session** and gives it an environment.

| | Claude Code sandbox mode | drydock |
|---|---|---|
| **What it is** | A feature *inside* Claude Code (off by default; enable via the `/sandbox` panel or `sandbox.enabled` in settings) | The workspace Claude Code runs *inside* (you launch it with the `drydock` CLI) |
| **Scope** | Each Bash command and its subprocesses | The whole session and its environment |
| **What it's for** | Contain a command's blast radius; cut permission prompts (in auto-allow mode) | A reproducible, credential-isolated dev environment |
| **Filesystem** | Writes limited to the working directory; reads allowed everywhere by default — including credential files like `~/.ssh/` and `~/.aws/credentials` unless you add `denyRead` entries | Host `~/.ssh`, `~/.gnupg`, `~/.aws`… are not mounted at all — invisible, not merely write-protected |
| **Network** | Session-wide domain allowlist (shared across all Bash commands); new domains prompt on first use, or pre-allow via `allowedDomains` in settings | Contained by default (no host network, no socket; egress via a per-session deny-by-default domain allowlist — static, no prompts); opt-in dood mode shares the host network |
| **Reproducible environment** | No — it restricts the host you already have | Yes — pinned Debian image + defined toolchain |
| **State** | Uses the host's Claude state as-is — no separation | Separate container state — host and container sessions don't race |
| **Mechanism** | OS sandbox — Seatbelt (macOS), bubblewrap (Linux) | Docker container |
| **Threat model** | A real OS boundary for a command's writes/network (the network proxy does not inspect TLS) | Accidents, not adversaries — contained by default (no socket); in opt-in dood mode the Docker socket is root-equivalent on the host (INV-6) |

**Which one applies.** In practice you use one, by context. Running Claude Code directly on the host — its sandbox mode contains each Bash command. Running it through drydock — the container is the containment. Claude Code's sandbox does **not** run inside a drydock container as drydock ships today: the image includes no bubblewrap, and the container does not permit the unprivileged user namespaces the Linux sandbox is built on.

**drydock's security layers:**

- **Credential isolation** — the host's SSH and GPG keys are never mounted into the container (INV-1).
- **Tamper-proof guardrails** — an image-baked `permissions.deny` policy plus a read-only `PreToolUse` hook; the agent cannot edit its own guardrails (INV-3).
- **Container hardening** — dropped Linux capabilities, `no-new-privileges`, and a size-bounded `/tmp` (INV-8).
- **Egress jail (contained mode)** — the default mode reaches the network only through a drydock-managed deny-by-default domain allowlist: a per-session proxy sidecar on an `internal: true` bridge, with no Docker socket and no host networking (INV-9). This is L4 hostname-based filtering — see [docs/security.md](docs/security.md) for the named residual gaps.

These raise the floor against agent *accidents* — not an adversarial sandbox. Full detail in [docs/security.md](docs/security.md).

## Requirements

### Host OS

| Platform | Support |
|----------|---------|
| **Linux** (native) | First-class. Tested on Debian/Ubuntu. |
| **WSL2** (Linux distro inside Windows) | First-class. Engineered around its quirks (9P FS, drvfs path translation). |
| **macOS** | Supported but **not first-class** — community-tested. Expect rougher edges around bind-mount performance and TTY latency (see [troubleshooting](docs/troubleshooting.md#claude-code-output-feels-slightly-slower-than-running-on-host-tty-latency)). |
| **Windows** (native, no WSL2) | NOT supported. Use WSL2 instead. |

### Host tooling (mandatory)

| Tool | Why | How to check |
|------|-----|--------------|
| **Docker** running on host | drydock is Docker-out-of-Docker; the container needs the host daemon. Use Docker Engine on Linux/WSL2 (recommended for performance), Docker Desktop on macOS. | `docker info` returns successfully |
| **`docker compose` v2** | drydock uses `docker compose` (subcommand), not the legacy `docker-compose` binary. Ships with modern Docker installs. | `docker compose version` works |
| **Bash ≥ 4** | The CLI (`bin/drydock`), the installer (`install.sh`), and lib scripts use arrays + modern parameter expansion. | `bash --version` |
| **`git`** | The clone/curl install paths both clone the repo. | `git --version` |
| **`jq`** | Used by drydock to filter the engram MCP entry out of the container's `.claude.json` when engram is unavailable (INV-4). | `jq --version` |
| **`rsync`** | Used by `drydock sync` / `ensure_synced` to refresh the container's Claude config from the host. | `rsync --version` |
| **`curl`** | Only needed if you use the one-line installer. | `curl --version` |

The Homebrew install path (`brew install sideralith/tap/drydock`) handles
`jq` and `rsync` automatically as formula deps. The clone and curl install
paths assume both are already on `PATH` and exit clearly if not.

### Claude Code on host (strongly recommended)

drydock seeds the container's Claude config from the host's `~/.claude/`.
Most users already have Claude Code installed on host — that's the
expected starting point. Without a host `~/.claude/`, drydock still
bootstraps but the container starts with no inherited settings, no MCP
servers, no project list. You'd have to configure those inside the
container by hand. Install Claude Code on host first.

OAuth credentials (`~/.claude/.credentials.json`) are deliberately NOT
synced into the container (INV-2 — prevents OAuth refresh race). Each
session inside drydock logs in once — see
[troubleshooting](docs/troubleshooting.md) for why.

### Optional

| Tool | What it adds |
|------|--------------|
| **`engram`** on host `PATH` | Persistent memory MCP server. Auto-detected per INV-4; everything works without it. |
| **`codegraph`** on host `PATH` | Code-graph MCP server (`codegraph_explore`). Auto-detected like engram (Linux host only): the host install dir `~/.codegraph` is mounted so the binary resolves, and the per-repo `.codegraph/` index rides the project mount. Everything works without it. |
| **`gh`** CLI authenticated | Needed if you want the agent (or you) to do GitHub work from inside the container. Also required by the Homebrew tap publish script for maintainers. |
| **GPG agent** + key | Only needed if you want signed commits inside the container; enabled via the GPG overlay. |
| **[`gum`](https://github.com/charmbracelet/gum)** | Premium interactive session selector (arrow navigation, colors, borders). Install: `brew install gum` or `apt install gum`. Falls back to `fzf` or built-in ANSI selector if absent. |
| **[`fzf`](https://github.com/junegunn/fzf)** | Fallback interactive session selector (incremental search). Install: `brew install fzf` or `apt install fzf`. Used when `gum` is absent. |

## Quick start

drydock is a per-user, host-side tool — no system-wide install.

**Recommended — clone first, then install (real terminal):**

```bash
git clone https://github.com/sideralith/drydock.git ~/drydock
cd ~/drydock && ./install.sh
```

This is the preferred path for security-conscious users: you can audit
`install.sh`, the compose files, and the managed-settings drop-ins before
running anything. When run in a terminal, the installer prompts to:
(a) enable shared engram mode (native Linux only — INV-5),
(b) build the Docker image now (~5 min), and
(c) add `~/.local/bin` to your shell rc file. Every prompt defaults to
"no" — pressing Enter keeps the safe defaults.

**Via Homebrew (macOS + Linux, from v0.2.1):**

```bash
brew tap sideralith/tap
brew install sideralith/tap/drydock
```

Brew handles `jq`/`rsync` deps and PATH; Docker is not a brew dep — install
it separately (Docker Desktop on macOS, Docker Engine on Linux). After
install, run `drydock build` once. The Homebrew tap source and the
publish script live at `packaging/homebrew/`.

**One-line / fresh-machine install:**

```bash
curl -fsSL https://raw.githubusercontent.com/sideralith/drydock/main/install.sh | bash
```

The piped install is fully non-interactive — no prompts. It clones the repo
and creates the symlink, then stops. Run `drydock build` and add
`~/.local/bin` to PATH yourself (the installer prints the exact export line).
If you'd rather inspect the installer before executing it, use the clone
flow above.

**After any install:**

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
# In any project — drydock works out of the box, no per-project setup needed:
cd ~/projects/myproject && drydock

# Other commands:
drydock shell [DIR]      # bash inside the container — for debugging
drydock new              # start a new session alongside existing ones (skips prompt)
drydock attach [NAME]    # reconnect to a live session (claude --resume)
drydock list             # list live sessions for the current project
drydock stop [NAME]      # stop a session (removes the container)
drydock status           # short health snapshot
drydock doctor           # detailed diagnostics + cwd context
drydock sync             # refresh container's ~/.claude/ + ~/.claude.json from host
drydock build            # rebuild the image
```

Sessions follow an **exit-vs-detach** model: **closing the terminal**
(disconnect) leaves the container running — your work is never lost — while
**exiting Claude cleanly** (`/exit`, Ctrl-D) tears the container down
automatically. Re-running `drydock` for the same project opens an interactive
selector (attach to existing / start new / stop+new / cancel) — the
selector uses [`gum`](https://github.com/charmbracelet/gum) if installed,
falls back to [`fzf`](https://github.com/junegunn/fzf), and finally to a
built-in ANSI renderer. To remove a persisted (disconnected) session,
reconnect with `drydock attach` — it resumes the exact prior conversation —
or run `drydock stop` to discard it.

drydock's safety policy is image-baked (`/etc/claude-code/managed-settings.d/`,
INV-3) and applies to every project automatically. You don't need to "initialize"
a project before launching `drydock` in it — `.claude/settings.json` is created
by Claude Code on demand (when you add MCP servers, hooks, or permissions),
and stays optional.

By default drydock runs in **contained mode**: no Docker socket and no host
networking, with egress jailed behind a deny-by-default domain allowlist. The
agent still reaches allowlisted hosts — the shipped baseline plus anything you add
to `~/.config/drydock/egress-allowlist` — while a request to a non-allowlisted
host returns 403. Stack-dependent commands that need the host daemon or host
network — `docker compose` against your stack, `docker exec` into a service,
`curl http://localhost:PORT/...`, `make shell-api` — do **not** work in contained
mode. They require **dood mode** (opt-in), which bind-mounts the host Docker socket
(root-equivalent on the host, INV-6) and shares the host network:

```bash
drydock dood <proj>            # pin this project to dood mode (stack tooling works)
drydock dood --remove <proj>   # drop the pin (follow the global default)
drydock default dood           # make dood the default for all new/unpinned projects
drydock contain <proj>         # pin back to contained (mutually exclusive with dood)
```

Resolution is most-specific-wins (`DRYDOCK_DOOD=1` env > per-project pin > global
default > factory contained), ties fail closed to contained, and the active mode +
reason print at container creation and in `drydock doctor`. See INV-9 in CLAUDE.md
and [docs/security.md](docs/security.md).

| Command | What it does |
|---|---|
| `drydock` / `drydock run [DIR]` | Launch Claude Code in DIR (or cwd), sandboxed. Closing the terminal persists the session; exiting Claude cleanly (`/exit`) tears it down. Re-running `drydock` for the same project opens an interactive selector (attach existing / start new / stop+new / cancel). |
| `drydock new` | Start a new session alongside any existing ones — skips the attach prompt |
| `drydock attach [NAME]` | Reconnect to a persisted session — resumes the exact prior conversation by UUID (picker fallback if no record). With N>1 sessions and a TTY, opens an interactive selector. |
| `drydock list` | List live sessions for the current project (columns: NAME, STATUS, AGE) |
| `drydock stop [NAME]` | Stop a session (force-removes the container). With no arg and N>1 sessions, prompts. |
| `drydock shell [DIR]` | Bash shell inside the container at DIR |
| `drydock link [--rw] [--mirror] <PATH> [CONTAINER-PATH]` | Mount a sibling project inside the container at `/workspace-siblings/<name>` (or a custom path). Without `--rw`: read-only mount, no key needed. With `--rw`: read-write mount; generates a per-sibling deploy key and managed SSH config so the agent can `git push` from the sibling without exposing `~/.ssh/`. With `--mirror`: mount at the same host path inside the container (host-path-mirror — fixes in-project skill symlinks to external paths). |
| `drydock unlink [--rw\|--mirror] PATH` | Remove a sibling mount from the current project's list (`--rw` and `--mirror` are accepted and ignored — the entry is keyed by host path) |
| `drydock links` | Show all sibling mounts configured for the current project |
| `drydock default <dood\|contain>` | Set the global default network/socket mode for new/unpinned projects |
| `drydock dood <proj> [--remove]` | Pin a project to dood mode (host Docker socket + host network; INV-6 root-equivalent) |
| `drydock contain <proj> [--remove]` | Pin a project to contained mode (no socket, no host network) |
| `drydock sync` | Refresh container config (`~/.claude/`, `~/.claude.json`) from host — runs automatically when the container copy is stale (set `DRYDOCK_SKIP_AUTOSYNC=1` to disable) |
| `drydock build [--no-cache]` | Build/rebuild `drydock:latest`; `--pull` is always applied to refresh the base image, `--no-cache` forces a full layer rebuild |
| `drydock status` / `doctor` | Health snapshot / full diagnostics |
| `drydock setup` | (advanced) Force host-side init — auto-triggered; rarely explicit |
| `drydock setup-token` | (advanced) One-time: generate a 1-year Claude OAuth token so container sessions start without a login prompt. See [Persistent auth](#persistent-auth-oauth-token). |
| `drydock revoke-token` | Delete the local OAuth token file. Also revoke server-side at claude.ai → Settings. |
| `drydock version` / `help` | Self-explanatory |

## Multi-mount projects

Some projects have sub-directories that are separate filesystem mounts — for
example, an Obsidian vault bind-mounted via WSL2's 9P drvfs layer:

```bash
# Example: ~/projects/myproject/docs is a drvfs bind from Windows
ls ~/projects/myproject/docs   # works on host — files visible
drydock shell
ls ~/projects/myproject/docs  # empty without sub-mount propagation!
```

drydock automatically detects sub-mounts under `${PROJECT_DIR}` and generates
a temporary compose overlay that propagates them into the container. Run
`drydock doctor` to see what was detected:

```
── sub-mounts under /home/you/projects/myproject ──
  ✓ /home/you/projects/myproject/docs → /mnt/c/Users/You/Documents/Obsidian/Vaults/MyProject (drvfs auto-translated)
  ✓ /home/you/projects/myproject/data → /data/foo (Linux-native bind)
  ⚠ /home/you/projects/myproject/nfsmount → server:/export (nfs, may not propagate)
```

Three classes of sub-mount:

| Class | Example | Behaviour |
|---|---|---|
| **drvfs** (WSL2 9P) | Obsidian vault, OneDrive folder | Auto-translated to `/mnt/<drive>/...` — Docker Desktop reads it |
| **Linux-native** | `mount --bind /data/src ~/projects/proj/bind` | Source path translated via `/proc/self/mountinfo` lookup |
| **Exotic** (nfs, cifs, fuse, tmpfs) | NFS share, SSHFS mount | Passed through with a warning — propagation not guaranteed |

If a sub-mount does not appear inside the container, see
[docs/troubleshooting.md](docs/troubleshooting.md#sub-mount-not-visible-inside-the-container).

> **Optional — engram memory:** drydock integrates the [engram](docs/engram.md)
> persistent-memory MCP server if it is already installed on your host. Entirely
> optional — see [docs/engram.md](docs/engram.md).

> **Optional — codegraph:** drydock exposes the `codegraph` code-graph MCP server
> inside the container when it is installed on your host (`~/.local/bin/codegraph`,
> Linux only). The host install dir `~/.codegraph` is bind-mounted so the binary
> resolves; the per-repo `.codegraph/` index travels in with the project mount.
> Auto-detected and entirely optional — when codegraph is absent its MCP entry is
> filtered from the container's config, exactly like engram.

## Persistent auth (OAuth token)

By default each drydock session starts with a login prompt — the container's
Claude credentials are isolated from the host's (INV-2: prevents OAuth refresh
races). To skip the login prompt across all sessions, generate a 1-year OAuth
token once:

```bash
drydock setup-token
```

drydock runs `claude setup-token` interactively — you complete the browser flow
and see the token printed by claude. drydock then prompts you to paste that
token, validates it, and writes it atomically to
`~/.config/drydock/claude-oauth-token` with mode `0600`. Every future session
auto-includes the token via `docker-compose.oauth.yml`.

Note: the token is visible in plaintext via `docker inspect` — see [docs/security.md](docs/security.md#claude-oauth-token-docker-composeoauthyml) for details and mitigations.

**When to use it:** you want frictionless session starts and don't need per-session
credential isolation for this particular host.

**Revoking:**

```bash
drydock revoke-token               # removes the local token file
# Then also: claude.ai → Settings → revoke the token server-side
```

`drydock revoke-token` only removes the local file. To fully revoke the token
(prevent any client using it from authenticating), visit claude.ai → Settings and
revoke it there. drydock has no API surface to do this server-side.

See [docs/troubleshooting.md](docs/troubleshooting.md#claude-prompts-for-login-every-session) for the full setup walkthrough.

## Persistent container config

Config files placed inside the container under `~/.claude/` (MCP server entries,
plugin configs, custom settings files) revert on every `drydock run` — the
per-session config dir is re-seeded from the prototype each time. To persist a
config file across all future runs, place it in the **container-config overlay**:

```
~/.config/drydock/claude-overlay/
```

This directory mirrors `~/.claude/` inside the container. Any file you place here
is copied on top of the freshly-seeded config dir before the container starts, on
every run — surviving re-seeds and garbage collection.

**Example**: to pre-configure a Playwright MCP server for every container session:

```bash
mkdir -p ~/.config/drydock/claude-overlay/mcp-servers
cp ~/.claude/mcp-servers/playwright.json ~/.config/drydock/claude-overlay/mcp-servers/
```

**Forbidden set** — these are rejected fail-loud (drydock aborts before container start,
naming the offending path):

| Forbidden | Reason |
|-----------|--------|
| `.claude.json` at overlay root | INV-2: last-writer-wins clobber hazard |
| `.credentials.json` at overlay root | INV-2: OAuth refresh race hazard |
| Symlinks (any depth) | Eliminates path-resolution bypass class |
| Non-regular files (FIFOs, devices) | Only plain dirs and files are allowed |

The overlay is **unidirectional**: host → container only. Files written inside the
container to paths that came from the overlay are not written back to the overlay or
to `~/.claude/` on the host. To stop applying a config, remove it from
`~/.config/drydock/claude-overlay/`.

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
engram MCP server (see [docs/engram.md](docs/engram.md)). The network/socket
posture is per-session (INV-9): in opt-in dood mode the host Docker socket is
bind-mounted (Docker-out-of-Docker — talks to the host's daemon, no nested
daemon) and the host network is shared; in contained mode (the default) neither
is present. Host config lives in two places (`~/.claude/` directory and
`~/.claude.json` file); drydock mounts per-session container-specific siblings
of both (seeded from a shared prototype each run) and the project tree. Hooks
are RO. The image is universal — only
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
`.claude/settings.json`. A per-project `.claude/settings.json` is optional — Claude Code
creates it lazily when you add MCP servers, hooks, or permissions, and the image-baked
policy applies regardless of whether the file exists.

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
