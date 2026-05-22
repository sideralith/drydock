# Changelog

All notable changes to drydock are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed
- **`drydock init` command** — removed entirely. Pre-v0.2.0 it was load-bearing
  (it seeded `.claude/settings.json` with drydock's full deny policy + the
  `SessionStart` hook). In v0.2.0 the policy moved to the image-baked
  managed-settings layer (`/etc/claude-code/managed-settings.d/`, INV-3),
  leaving init as a vestigial empty-stub creator with no remaining
  load-bearing role. Claude Code creates `.claude/settings.json` on demand
  when the user adds MCP servers, hooks, or permissions through its own
  commands — so a dedicated drydock command for it no longer adds value.
  Cleaned up: removed `cmd_init` function, the dispatch case in
  `bin/drydock`, the `init` row from `usage()`, the `onboard` redirect
  (which pointed at init), the `templates/default-settings.json` file, the
  `DEFAULT_SETTINGS_TEMPLATE` constant in `lib/compose.sh`, the `drydock
  init .` line from `install.sh`'s next-steps output, and the corresponding
  tests (`test/init.bats` removed; `test/examples.bats`,
  `test/cli_surface.bats`, `test/source_guard.bats`, and
  `test/managed_settings.bats` cleaned up). `drydock doctor` no longer
  warns when `.claude/settings.json` is missing — it's reported as info,
  not a missing-piece. drydock is pre-1.0 with no known users yet, so no
  deprecation stub was kept.

### Added
- **`drydock setup-token` / `drydock revoke-token`**: frictionless persistent
  auth for container sessions. `drydock setup-token` runs `claude setup-token`
  on the host, captures the resulting 1-year OAuth token, and writes it
  atomically with mode `0600` to `~/.config/drydock/claude-oauth-token`. From
  then on a new `docker-compose.oauth.yml` overlay auto-injects the token as
  `CLAUDE_CODE_OAUTH_TOKEN` so every session starts without a browser login
  prompt. `drydock revoke-token` removes the local token file (also revoke
  server-side at claude.ai → Settings). `drydock doctor` shows the overlay as
  active when the file is present. Closes #58.
- **Homebrew packaging**: `packaging/homebrew/drydock.rb` formula source and
  `scripts/publish-homebrew-tap.sh` to publish/refresh the
  `sideralith/homebrew-tap` tap. Users install with
  `brew install sideralith/tap/drydock` once the tap is published. The
  generic `homebrew-tap` repo name (vs. `homebrew-drydock`) keeps the
  install command clean (`sideralith/tap/drydock` instead of the
  double-named `sideralith/drydock/drydock`) and leaves room for future
  sideralith formulae under the same tap.
- **`.env` secret protection**: `00-secrets.json` now denies `Read`, `Edit`,
  and `Write` on the common `.env` filename variants (`.env`, `.env.local`,
  `.env.production`, `.env.development`, `.env.test`, `.env.staging`) at any
  mount depth via `//**/`-anchored patterns. `.env.example` and other
  template suffixes are intentionally not covered (they should be readable).
  Closes the gap previously documented in `docs/security.md`'s "what drydock
  does NOT protect against" section.
- **`drydock doctor` — resume cheat-sheet for active sessions.** The ACTIVE
  SESSIONS section now prints, under each running container, the `docker exec`
  command to re-enter that live session and recover the work — `claude
  --continue` for run sessions, `bash` for `-shell` companions. Handy for
  rejoining a session whose terminal was closed. A `⚠` caveat notes that
  re-entering a live run session starts a second Claude against one shared
  per-session config (INV-2).

### Fixed
- **Conversation history destroyed on the next `drydock run` (data loss).**
  `gc_orphan_session_dirs` (`lib/compose.sh`) prunes per-session
  `~/.claude-container-<disc>/` dirs whose container is no longer in
  `docker ps -a`. Because `drydock run` uses `docker compose run --rm`, an
  `/exit`'d container leaves `docker ps -a` immediately — so the next
  `drydock run` saw the exited session's dir as orphaned and `rm -rf`'d it.
  That dir holds `projects/<slug>/<uuid>.jsonl`, the durable conversation
  history, so every conversation was destroyed on the next run and
  `claude --resume` had been broken across sessions since v0.2.0. Before
  pruning, the GC now harvests each orphan dir's `projects/` tree into the
  prototype `~/.claude-container/projects/`, copying each append-only
  `.jsonl` only when the prototype has no copy or the harvested one is
  larger — so a stale shorter copy can never clobber a more complete one.
  New sessions, seeded from the prototype, inherit it and `--resume` works
  again. Hotfix for #68 (root fix tracked separately).
- **Root-owned `~/.cache` and `~/.config` inside the container.** Docker
  creates any missing parent directory of a bind-mount target as `root:root`.
  The base compose mounts `~/.config/gh` and the ccstatusline overlay mounts
  `~/.cache/ccstatusline`, so their parent directories were created
  root-owned — leaving the non-root agent unable to write any other subdir
  under them (e.g. the Playwright MCP downloading Chromium to
  `~/.cache/ms-playwright`). The `Dockerfile` now pre-creates `~/.cache` and
  `~/.config` owned by the container user before the `USER` switch;
  bind-mounting into an already-existing directory leaves its ownership
  intact.

### Changed
- **`drydock doctor` — OAuth token staleness warning**: when the OAuth token
  file is present, `doctor` now computes its age from the file mtime and shows
  a `⚠` row instead of the `✓` row once the token is over 330 days old
  (~35-day runway before the ~1-year token expires), pointing the user at
  `drydock setup-token --force` to refresh. Closes #60.
- **`install.sh`**: the shared-engram-mode prompt now skips silently when
  `engram` is not on `PATH`. Previously the prompt appeared on every native
  Linux install regardless — useless for users without engram (INV-4: engram
  is optional). Also adds a comment explaining the gate.
- **README quick start**: the clone-first install path is now explicitly
  framed as the recommended audit-before-run option for security-conscious
  users; the curl one-liner remains for quick installs but now points back
  to the clone flow as an inspection alternative.
- **`drydock doctor` / `drydock status` / `drydock help` — modern visual
  redesign.** Switched to a hierarchical layout: uppercase section headers,
  indented items with consistent status icons (`✓` ok, `·` info, `⚠`
  warning, `✗` error), dim metadata column, and TTY-aware coloring. Pipes
  / non-TTY output is plain text. Respects the `NO_COLOR` env var
  convention (any non-empty value disables color). No Nerd-Font glyphs —
  uses Unicode-standard symbols so every UTF-8 terminal renders the same.
  Implementation: four reusable helpers (`_dr_init_style`, `_dr_section`,
  `_dr_item`, `_dr_help_row`) keep formatting consistent across all three
  commands.
- **`drydock doctor`** content expanded with four new sections:
  - **Linked siblings** — lists the `~/.config/drydock/links/<project>.list`
    entries for the current project (the same data `drydock links` prints).
    Empty case: `(none linked)` hint.
  - **Active drydock sessions (this project)** — surfaces any running
    `drydock-<project>-<disc>` (and `-shell` companion) containers for the
    current project. Awareness signal for concurrent-sessions (INV-2).
  - **Compose overlays that would activate now** — replicates the conditions
    in `compose_files()` (without side-effects — no temp overlays written)
    and prints which compose files would be included for an invocation from
    the current `cwd`/env. Surfaces base, hardening, sub-mounts, links, SSH,
    GPG, engram, mcp-auth, and ccstatusline overlays.
  - **`drydock` env flags (non-default)** — lists any `DRYDOCK_*` env var
    currently set (`DRYDOCK_NO_HARDENING`, `DRYDOCK_TMPFS_SIZE`,
    `DRYDOCK_ENGRAM_SHARED`, `DRYDOCK_SKIP_AUTOSYNC`). Safety-loosening
    flags marked `⚠`, neutral tunables `✓`. Empty: `(none — defaults
    active)`.

### Documentation
- **TTY latency on WSL2 and macOS**: new `docs/troubleshooting.md` section
  explaining the PTY chain (containerd → daemon → CLI → terminal) and why
  WSL2 + Docker Desktop / macOS + Docker Desktop add a per-byte VM-bridge
  hop. Includes a mitigations table (Docker Engine inside WSL2 for the
  biggest payoff; OrbStack/Colima/virtiofs notes for macOS).
- **`docs/security.md`**: the "what drydock does NOT protect against"
  section is updated — `.env` and common variants are now covered by the
  managed-settings deny, no per-user setup required.
- **README Requirements section**: new section between "What problem it
  solves" and "Quick start" that lists host OS support matrix, mandatory
  host tooling (Docker, `docker compose` v2, Bash ≥ 4, `git`, `jq`,
  `rsync`, `curl`), the strong recommendation to have Claude Code already
  installed on host, and the optional pieces (`engram`, `gh`, GPG).

## [0.2.0] - 2026-05-20

Managed-settings layer, concurrent-session isolation, destructive-command guardrails,
auto-sync, RW sibling mode, and several hardening + polish rollups.

### Added
- **self-awareness** (#8): image bakes a `drydock-release` marker file and a
  `SessionStart` hook that notifies the agent it is running inside a drydock container.
- **install-interactive** (#14): `install.sh` now detects a live TTY and presents
  interactive prompts for engram-shared mode and GPG commit-signing toggles; non-TTY
  installs remain fully unattended.
- **auto-sync** (#15): `drydock run` and `drydock shell` automatically sync
  `~/.claude/` into the container-specific state directory at launch, removing the
  need to run `drydock setup` after each host-side config change.
- **managed-settings layer**: policy drop-ins (`deny` rules + `SessionStart` hook
  entry) are now baked into the image under `/etc/claude-code/managed-settings.d/`
  and owned by root — tamper-proof, not overridable from project settings (INV-3).
- **destructive-command guardrails** (#30): two-tier defense — declarative
  `Bash(...)` deny patterns for the highest-risk commands (A1 class) plus a
  `PreToolUse` hook (`drydock-block-destructive.sh`) for residue rules that need
  context-aware matching (C1-residue, C12, C17, C18, C20).
- **concurrent-sessions** (#9): each `drydock run`/`drydock shell` invocation
  generates a 4-character hex discriminator and mounts its own
  `~/.claude-container-<disc>/` directory and `~/.claude-container-<disc>.json`,
  preventing `~/.claude.json` last-writer-wins clobber and OAuth-token refresh
  races across concurrent same-project sessions (INV-2).
- **link-sibling-projects** (#13): `drydock link`, `drydock unlink`, and
  `drydock links` commands for read-only cross-project sibling mounts; INV-1 deny
  rule rewritten to `//**/`-anchored patterns.
- **rw-sibling-mode** (#47): `drydock link --rw` provisions per-sibling deploy
  keys, writes managed SSH `Host` aliases, and rewrites `remote.origin.url` so the
  agent can push to sibling repositories without touching host SSH identity (INV-1).

### Changed
- Agent policy (deny rules + hook entry) moved from per-project `settings.json` to
  image-layer managed-settings drop-ins; the per-project file no longer carries
  policy (INV-3 hardening).
- `export_compose_env()` generates and exports per-session discriminator paths
  (`DRYDOCK_SESSION_CLAUDE_DIR`, `DRYDOCK_SESSION_CLAUDE_JSON`) for every
  invocation.

### Fixed
- Quoted-target bypass in `drydock-block-destructive.sh` (#31): hook now strips
  surrounding quotes before pattern-matching the tool target path.
- `GITHUB_PERSONAL_ACCESS_TOKEN` passthrough documented in `docs/security.md` (#22).
- Several judgment-day follow-up polish items (#51 #52 #53 #54).

## [0.1.2] - 2026-05-16

Project name sanitization, running-container diagnostic, and constitution correction.

### Added
- `sanitize_project_name()` pure helper in `lib/compose.sh` transforms a directory
  basename into a Docker Compose-safe project name: lowercases, maps non-`[a-z0-9_-]`
  characters to dashes, collapses repeated dashes, strips leading non-alphanumeric
  characters (dashes and underscores), and strips trailing dashes and underscores.
  Falls back to the literal string `project` if the result is empty.
- `is_container_running()` pure helper in `lib/commands.sh` that wraps
  `docker inspect --format '{{.State.Running}}'` to detect an already-running container
  by exact name match.
- Running-container conflict diagnostic: when `drydock run` or `drydock shell` detects
  a same-named container already running, it now prints a drydock-formatted message to
  stderr with the container name, an attach command (`docker exec -it <name> bash`),
  a stop command (`docker stop <name>`), and a collision-rename hint. The command exits
  non-zero without issuing the compose run.

### Changed
- `export_compose_env` now sets `PROJECT_NAME` through `sanitize_project_name`, making
  the sanitizer apply globally. Every downstream consumer — `COMPOSE_PROJECT_NAME`,
  the deploy-key path, and `cmd_run`/`cmd_shell` container names — inherits the clean
  value automatically with no per-consumer change.
- INV-2 "Why" and "Consequence" in `CLAUDE.md` corrected: the previous text attributed
  SQLite/fcntl/WAL contention to `~/.claude/` and `~/.claude.json` (those paths contain
  no SQLite files). The rewritten section states four reasons for the host-vs-container
  state split — two universal (`.claude.json` last-writer-wins clobber, OAuth refresh
  race) and two engram-specific (MCP config filter divergence, `~/.engram/engram.db`
  WAL corruption on unreliable-`fcntl`-lock filesystems).

### Fixed
- `drydock run` and `drydock shell` with a project directory whose basename contains
  dots, spaces, or other characters invalid in a Docker Compose project name no longer
  produce a raw Docker daemon error. The name is sanitized before use.
- `drydock run`/`drydock shell` now emit a friendly diagnostic instead of a raw Docker
  name-collision error when a same-named container is already running.

### Known limitations
- Two project directories whose basenames sanitize to the same name (e.g.
  `sideralith.com` and `sideralith-com` both become `sideralith-com`) share a
  container namespace and deploy-key path. No collision detection is added; the
  collision-rename hint in the conflict diagnostic is the recovery path.

### Migration notes
- Deploy keys named after a dotted project directory (e.g. `sideralith.com_deploy`)
  are no longer found automatically after this change — the deploy-key path now uses
  the sanitized name (`sideralith-com_deploy`). Rename the key file to the sanitized
  form to restore SSH deploy access. A warning is emitted at startup if a key exists
  under the old (unsanitized) filename.

## [0.1.1] - 2026-05-15

Container hardening defaults.

### Added
- Default container hardening, applied to every session via an auto-included
  `docker-compose.hardening.yml` overlay:
  - `cap_drop: ALL` plus a minimum `cap_add` set (`DAC_OVERRIDE`, `CHOWN`,
    `FOWNER`, `SETUID`, `SETGID`). Accidental privileged syscalls such as
    `mount -o bind` now return `EPERM`.
  - `security_opt: no-new-privileges:true`. Setuid binaries can no longer
    re-acquire dropped capabilities.
  - A size-bounded `tmpfs` on `/tmp` (1 GB default). A runaway loop can no
    longer fill the host's memory-backed tmpfs.
- `DRYDOCK_NO_HARDENING=1` — per-invocation opt-out that disables the hardening
  overlay entirely (literal value `1`).
- `DRYDOCK_TMPFS_SIZE` — tune the `/tmp` size cap (e.g. `4g`, `512m`) without
  disabling the rest of the hardening.

### Changed
- Syscalls requiring dropped capabilities (mount, raw-socket bind, cross-uid
  `ptrace`) now return `EPERM` inside the container.

### Removed
- `sudo` is no longer installed in the base image. No drydock code path invoked
  it, and with `no-new-privileges:true` it would be a no-op.

### Upgrade notes
- Rebuild the image with `drydock build`, then run as usual. No configuration
  changes are required for most workflows. If a workflow needs a dropped
  capability, run with `DRYDOCK_NO_HARDENING=1`.
- Rationale and failure modes: see INV-8 in [`CLAUDE.md`](CLAUDE.md) and
  [`docs/security.md`](docs/security.md).

## [0.1.0] - 2026-05-15

First public release. A defense-in-depth sandbox for AI coding agents: a
containerized Claude Code workspace with Docker-out-of-Docker via the host
socket, and memory and config isolated from the host.

### Added
- Containerized agent workspace — Claude Code, the engram MCP server, and
  plugins run in a Debian 12 slim container.
- Docker-out-of-Docker via the host socket — the containerized agent drives
  the host Docker daemon, with no nested daemon.
- Credential isolation — `~/.ssh`, `~/.gnupg`, `~/.aws`, and `~/.kube` are
  never mounted. SSH and GPG material lives under `~/.config/drydock/` and is
  activated only through opt-in overlays.
- Container-state split — the container has its own `~/.claude-container/`,
  `~/.claude-container.json`, and `~/.engram-container/`, so concurrent host
  and container sessions do not race over SQLite WAL.
- Hooks read-only overlay — `~/.claude/hooks/` is mounted `:ro`; the agent
  cannot edit its own guardrails.
- Engram is fully optional — auto-detected, and its absence is a supported,
  tested configuration with no startup error noise.
- Sub-mount auto-detection — sub-mounts under the project (WSL2 9P / drvfs,
  Linux-native binds, and NFS/CIFS/FUSE) are detected, classified, and
  propagated into the container.
- `install.sh` — curl-pipe and clone-and-run installation.
- Example projects — `examples/minimal/` and `examples/web-stack/`.
- MIT license.

[0.2.0]: https://github.com/sideralith/drydock/releases/tag/v0.2.0
[0.1.2]: https://github.com/sideralith/drydock/releases/tag/v0.1.2
[0.1.1]: https://github.com/sideralith/drydock/releases/tag/v0.1.1
[0.1.0]: https://github.com/sideralith/drydock/releases/tag/v0.1.0
