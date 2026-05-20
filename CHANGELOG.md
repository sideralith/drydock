# Changelog

All notable changes to drydock are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.1]: https://github.com/sideralith/drydock/releases/tag/v0.1.1
[0.1.0]: https://github.com/sideralith/drydock/releases/tag/v0.1.0
