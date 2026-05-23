# drydock — Project Constitution

> Architecture, invariants, and conventions for agents and contributors working on drydock itself.

## 1. Project Identity

drydock is a containerized Claude Code workspace: Docker-out-of-Docker (DooD) via a bind-mounted
host socket, credential isolation via `~/.config/drydock/`, and container-specific Claude / engram
state so host and container sessions never race. Threat model A: drydock defends against agent
accidents (typos, runaway loops, footguns), not adversaries. Non-goals: no adversarial sandbox, no
macOS first-class support until tested, no Windows native support.

This file is the architecture constitution — read by agents at session start and by contributors
when evaluating a PR or proposal. It is not user documentation. See `→ README.md` for user-facing
setup and usage.

## 2. Architectural Invariants

Eight invariants, each following the next pattern — Rule, Why (with a specific falsifiable
failure mode), Consequence — ordered outside-in: credentials → state isolation → hooks defense →
optional features → DooD foundation → meta-rule → runtime hardening defaults. Stable identifiers
(`INV-N`) enable cross-artifact citation; section identifiers (`§N`) likewise.

### INV-1: Credential Isolation

- **Rule**: The compose stack MUST NOT bind-mount host `~/.ssh`, `~/.gnupg`, or the gpg-agent
  socket. SSH and GPG material MUST live exclusively under `~/.config/drydock/keys/<project>_deploy`
  and `~/.config/drydock/signing/`.
- **Why**: A compromised or instruction-following-too-literally agent has direct read access to the
  user's primary auth identities. A single `cat ~/.ssh/id_ed25519` or accidental `cp` to `/tmp/`
  leaks the host's primary identity — not just a deploy key. The credential blast radius extends to
  every system that trusts that key (GitHub personal account, servers, cloud providers).
- **Consequence of violating**: A buggy or prompt-injected agent exfiltrates the full SSH identity
  in one command, compromising every system tied to that identity — not merely the one project
  being worked on.
- **Where this lives in code**: `docker-compose.yml` mounts list (no `~/.ssh`, no `~/.gnupg`);
  `docker-compose.ssh.yml` and `docker-compose.gpg.yml` (credential overlays sourced from
  `~/.config/drydock/` exclusively). For RW sibling mode: `lib/sibling_ssh.sh` (per-sibling
  key generation, managed SSH config regeneration, and `remote.origin.url` rewrite/restore
  helpers); the managed SSH config is written to `~/.config/drydock/ssh-config-<primary>` and
  RO bind-mounted into the container; the keys directory (`~/.config/drydock/keys/`) mounts as
  a single `:ro` directory (no per-key overlay enumeration — scales to N siblings without
  changing the compose files). All per-sibling key material stays under
  `~/.config/drydock/keys/` — already covered by the `__HOME__/.config/drydock/**` deny rule
  in `templates/managed-settings.d/00-secrets.json`.
- **Deep dive**: [docs/security.md](docs/security.md)

### INV-2: Container State Split

- **Rule**: Container mounts MUST point at container-specific state — the per-session
  `~/.claude-container-<disc>/` directory and `~/.claude-container-<disc>.json` file (each
  seeded from the `~/.claude-container/` prototype), `~/.engram-container/`, **and the shared
  container-specific append-only conversation store at `~/.claude-container/projects/`** — never at
  the host's `~/.claude/`, `~/.claude.json`, or `~/.engram/`. The host's `~/.claude/`,
  `~/.claude.json`, and `~/.engram/` MUST NEVER be the source of any container mount —
  writable or read-only. (INV-3's `:ro` hooks overlays — both the per-session
  `~/.claude-container-<disc>/hooks/` subpath (mount #1) AND the per-session
  `~/.claude-container-<disc>/drydock-hooks/` subpath (mount #3) — source from per-session
  paths, not from host `~/.claude/hooks/` or `~/.claude/drydock-hooks/`, so they are
  consistent with this rule — no carve-out required.)
- **Why**: Container mounts point at container-specific Claude and engram state for four reasons.
  Reasons 1 and 2 are universal — they apply to every drydock user. Reasons 3 and 4 apply only
  when engram is in use (engram is optional per INV-4; a user without engram is unaffected by them).
  (1) **Universal — `~/.claude.json` hot last-writer-wins clobber.** `~/.claude.json` is a plain
  JSON file Claude Code constantly rewrites (changelog timestamps, per-project `lastUsed`, MCP
  state). Two concurrent sessions performing read-modify-write on it have no merge step; the later
  `write()` wins and silently discards the other session's changes.
  (2) **Universal — `~/.claude/.credentials.json` OAuth refresh race.** This file holds the OAuth
  token. When a host session and a container session refresh concurrently, each re-mints and writes
  a token, invalidating the other's — both sessions get logged out.
  (3) **When engram is in use — divergent MCP config.** The container's Claude config has the engram
  MCP entry filtered out via `jq 'del(.mcpServers.engram, ...)'` (`cmd_setup()` and `cmd_sync()` in `lib/commands.sh`). If the
  container shared the host's live `~/.claude.json`, that filter would destructively mutate it —
  stripping the engram MCP entry from the host's own config.
  (4) **When engram is in use — `~/.engram/engram.db` SQLite WAL corruption.** The hazard is NOT
  concurrency alone: SQLite WAL is explicitly designed for concurrent access. Corruption requires
  concurrency PLUS a filesystem where `fcntl` advisory locks are UNRELIABLE — the WSL2 9P bridge,
  macOS virtiofs, or a bind-mount crossing the Docker Desktop VM boundary. On a native filesystem
  with working `fcntl` locks, multiple sessions are safe; the cross-VM-boundary mount is what breaks
  the lock guarantee. (The engram DB lock semantics are governed in detail by INV-5.)
  **Container-vs-container (v0.2.0+).** Concurrent same-project sessions introduce a second
  consumer class: container-vs-container alongside host-vs-container. Two drydock containers
  running concurrently for the same project engage INV-2 for exactly the same reasons as reasons
  (1) and (2) above — `~/.claude.json` last-writer-wins clobber and the OAuth token refresh race
  apply equally when both writers are containers. The mechanism that keeps INV-2 satisfied in this
  case is per-session config isolation: each invocation mounts its own `~/.claude-container-<disc>/`
  directory and `~/.claude-container-<disc>.json` file (where `<disc>` is a 4-character random hex
  discriminator). No two concurrent containers ever share a `~/.claude*` source path with write
  access, so neither failure mode can occur between sessions.
- **Consequence of violating**: Sharing host `~/.claude/`, `~/.claude.json`, and `~/.engram/` with
  the container produces silent failure across all four reasons: concurrent sessions clobber
  `~/.claude.json` writes (last-writer-wins, lost config — no error); trigger an OAuth lockout
  requiring re-authentication of both sessions via `.credentials.json`; have the container's MCP
  filter destructively mutate the host's live config, destroying the host's engram MCP entry; and —
  on an unreliable-`fcntl`-lock filesystem (WSL2 9P, macOS virtiofs, Docker Desktop VM boundary) —
  silently corrupt `~/.engram/engram.db` via a WAL page clash. Every failure mode is silent: data
  loss or auth loss with no obvious cause.
- **Carve-out — shared `projects/` conversation store**: `~/.claude-container/projects/` is mounted
  `:rw` and shared across concurrent sessions — an intentional, scoped exception to per-session
  isolation. It is safe because none of INV-2's four hazards apply: conversation history is
  `projects/<slug>/<uuid>.jsonl` — one append-only file per conversation UUID. There is no
  read-modify-write on a shared single file (hazards 1 and 3 — the `~/.claude.json` clobber and
  the MCP-filter mutation — are RMW on one shared file), and there is no SQLite database (hazards
  2 and 4 — the OAuth refresh race and `engram.db` WAL corruption — require a DB on an
  unreliable-lock filesystem). Two concurrent containers write DIFFERENT `<uuid>.jsonl` files;
  there is no shared writer of any single file. The carve-out is scoped to `projects/` only;
  all other INV-2 protections remain absolute.
- **Carve-out — host-authored container-config overlay**: `~/.config/drydock/claude-overlay/` is
  an OPTIONAL host-side directory that mirrors the `~/.claude/` tree. When present, drydock copies
  it whole-file and recursively on top of the freshly re-seeded per-session
  `~/.claude-container-<disc>/` dir — host-authored, container-consumed, unidirectional. It is an
  intentional, scoped exception to per-session prototype-only seeding. It is safe because none of
  INV-2's four hazards apply: (1) the `~/.claude.json` last-writer-wins clobber requires
  read-modify-write on one shared file — the overlay is a one-way host→session-dir copy with a
  single writer per session, and `~/.claude.json` is in the overlay's forbidden set (rejected
  fail-loud); (2) the `.credentials.json` OAuth refresh race requires the OAuth token file —
  `.credentials.json` is likewise in the forbidden set; (3) the divergent MCP-filter mutation is a
  RMW on the host's live `~/.claude.json` — the overlay never writes the host's `~/.claude/` at
  all (unidirectional) and cannot deliver `~/.claude.json`; (4) the `engram.db` WAL corruption
  requires a SQLite database on an unreliable-lock filesystem — the overlay carries plain config
  files only. The scope limit is structural: the overlay mechanism rejects `~/.claude.json`,
  `.credentials.json`, and any symlink fail-loud, aborting `drydock run` before container start.
  All other INV-2 protections remain absolute.
- **Where this lives in code**: the `HOST_CLAUDE` / `CONTAINER_CLAUDE` / `*_JSON` / `*_ENGRAM` path-constants block in `lib/paths.sh`;
  the `${DRYDOCK_SESSION_CLAUDE_DIR}` / `${DRYDOCK_SESSION_CLAUDE_JSON}` mount lines in `docker-compose.yml`;
  the `${HOME}/.claude-container/projects:${HOME}/.claude/projects:rw` sub-mount line in
  `docker-compose.yml`; `export_compose_env()` in `lib/compose.sh` (generates and exports the
  per-session discriminator paths); `migrate_projects_to_shared_store()` in `lib/compose.sh`
  (one-time sentinel-gated upgrade sweep); `apply_claude_overlay()` in `lib/compose.sh` (the
  overlay step in `seed_session_config_dir`); the `HOST_CLAUDE_OVERLAY` constant in `lib/paths.sh`.
- **Deep dive**: [docs/architecture.md](docs/architecture.md)

### INV-3: Hooks Read-Only Overlay

- **Rule**: The per-session `~/.claude-container-<disc>/hooks/` subpath MUST be bind-mounted
  `:ro` on top of the container's `.claude` mount, and the per-session
  `~/.claude-container-<disc>/drydock-hooks/` subpath MUST likewise be bind-mounted `:ro` at
  `~/.claude/drydock-hooks` to seal the inode-alias exposure introduced by the parent `:rw`
  mount. The agent MUST NOT have write access to its own hook scripts. Additionally, drydock's
  agent policy — the `permissions.deny` block, the `hooks.SessionStart` entry, and the
  `hooks.PreToolUse` entry — MUST be delivered via a Claude Code managed-settings drop-in baked
  into the image and owned by root. The agent MUST NOT have write access to these policy files.
- **Why**: drydock's tier-1 defense is composed of three layers, ALL sealed before or at session
  startup — layers (a) and (b) via image-layer ownership at build time, layer (c) via per-session
  seeding at startup. No layer is a live host bind-mount.
  (a) The `permissions.deny` block lives in `templates/managed-settings.d/00-secrets.json` and
  is baked into the image at `/etc/claude-code/managed-settings.d/00-secrets.json` (root-owned,
  non-root container user, loaded by Claude Code at highest precedence and not overridable from
  project settings). (b) The `hooks.SessionStart` and `hooks.PreToolUse` entries (in
  `20-hooks.json` and `40-guardrails-hook.json`) are baked into the image at the same path with
  the same root ownership; each entry references an absolute command under `/opt/drydock/hooks/`.
  (c) The hook scripts themselves (`drydock-session-start.sh`, `drydock-block-destructive.sh`)
  are bind-mounted `:ro` into `/opt/drydock/hooks/` from a per-session seeded directory
  (`${DRYDOCK_SESSION_HOOKS_DIR}` — populated by `seed_session_config_dir()` from
  `${DRYDOCK_HOME}/templates/hooks/`). Likewise, the per-session `~/.claude-container-<disc>/hooks/`
  subpath is bind-mounted `:ro` into `~/.claude/hooks/` so the agent cannot rewrite its own
  Claude-side hook scripts. The `~/.claude/drydock-hooks` `:ro` overlay (mount #3) seals the
  inode-alias gap: because `DRYDOCK_SESSION_HOOKS_DIR` is a subpath of `DRYDOCK_SESSION_CLAUDE_DIR`,
  the parent `:rw` mount exposes it as writable; the third `:ro` overlay closes that gap.
  All three per-session bind-mounts source from session-local dirs (NOT
  host `~/.claude/hooks/` or host `${DRYDOCK_HOME}/templates/hooks/` directly), which keeps
  INV-2's "container never reads host `~/.claude/` directly" rule unconditional and bounds the
  blast radius of accidental host edits: a fat-fingered change does not propagate to running
  sessions, only to future ones (after the next `drydock sync` / `drydock run`). All three
  layers are structural, not advisory. Before v0.2.0, the deny block and hook entries lived in
  a per-project `settings.json` that a sufficiently instruction-following agent could overwrite,
  silently weakening the guardrails for the remainder of the session.
- **Consequence of violating**: A buggy or prompt-injected agent disables its own guardrails
  mid-session. Hook-based protections are silently bypassed for the remainder of the session
  with no indication to the operator.
- **Where this lives in code**: three `:ro` bind-mount lines in `docker-compose.yml` — mount #1
  `${DRYDOCK_SESSION_CLAUDE_DIR}/hooks → ${HOME}/.claude/hooks` (Claude-side hooks), mount #2
  `${DRYDOCK_SESSION_HOOKS_DIR} → /opt/drydock/hooks` (drydock-side hook scripts referenced by
  the baked hook entries), and mount #3 `${DRYDOCK_SESSION_HOOKS_DIR} → ${HOME}/.claude/drydock-hooks`
  (inode-alias seal — re-mounts the same source `:ro` to override the parent `:rw` exposure);
  the `hooks` entry in `cmd_setup`'s `mkdir -p` list in
  `lib/commands.sh` (guarantees the prototype always has the Claude-side hooks subdir so Docker
  never has to auto-create the bind-mount source as root on fresh-init for mount #1);
  `ensure_runtime_dirs` in `lib/compose.sh` (unconditional `mkdir -p "$CONTAINER_CLAUDE/hooks"`
  — upgrade-path defense for pre-existing prototypes that predate the Claude-side hooks
  subdir); `seed_session_config_dir` in `lib/compose.sh` (propagates `hooks/` from the
  prototype into the per-session Claude-side dir, AND populates the per-session drydock-side
  dir from `${DRYDOCK_HOME}/templates/hooks/`); `export_compose_env` in `lib/compose.sh`
  (exports `DRYDOCK_SESSION_HOOKS_DIR=$HOME/.claude-container-<disc>/drydock-hooks` paired with
  `DRYDOCK_SESSION_CLAUDE_DIR`); `Dockerfile` (COPY+RUN block that bakes
  `templates/managed-settings.d/` into the image); `templates/managed-settings.d/` (policy
  drop-ins: `00-secrets.json`, `10-git-safety.json`, `20-hooks.json`, `30-os-safety.json`,
  `40-guardrails-hook.json`, `50-prod-ops.json`); `templates/hooks/drydock-session-start.sh`
  and `templates/hooks/drydock-block-destructive.sh` (source-of-truth for the drydock-side
  scripts; sealed via per-session seed + `:ro` bind-mount, NOT image-baked).
- **Deep dive**: [docs/security.md](docs/security.md)

### INV-4: Engram is Optional

- **Rule**: The engram MCP server, compose overlay, and all engram-dependent code paths MUST be
  gated behind `engram_usable()`. Absence of engram MUST be a supported, tested configuration.
  When engram is not usable, its MCP config MUST be filtered from the container's Claude config.
- **Why**: Engram is one MCP memory plugin among many; users may prefer alternatives (Mem0, custom
  RAG, no persistent memory). Hard-requiring it makes drydock a niche tool tied to one plugin
  ecosystem. Contributor barrier-to-entry increases if contributors must install and configure
  engram simply to run the project.
- **Consequence of violating**: drydock loses portability and becomes a wrapper around one specific
  MCP memory stack rather than general-purpose containerized Claude infrastructure — exactly the
  "niche tool instead of portable infrastructure" failure mode the project is designed to avoid.
- **Where this lives in code**: `engram_usable()` in `lib/compose.sh`;
  `cmd_setup()` and `cmd_sync()` in `lib/commands.sh` (MCP filter).
- **Deep dive**: [docs/architecture.md](docs/architecture.md)

### INV-5: Engram Shared-Mode Opt-In, Force-Isolated on Unreliable Locks

- **Rule**: Shared-mode (reusing the host `~/.engram/` DB inside the container) MUST require an
  explicit opt-in sentinel at `~/.config/drydock/engram-shared`. On hosts where
  `host_fs_locks_unreliable()` is true (WSL2, macOS), shared-mode MUST be force-downgraded to
  isolated regardless of the sentinel, unless `DRYDOCK_ENGRAM_SHARED=force` is set explicitly.
- **Why**: Same SQLite WAL `fcntl` lock problem as INV-2, applied to the engram DB specifically.
  Concurrent host + container writes to `~/.engram/engram.db` over WSL2 9P or macOS virtiofs
  produce silent WAL corruption. The force-downgrade is the only safe default; the `force` override
  exists for power users who understand the risk.
- **Consequence of violating**: A user on WSL2 who enables shared mode without force-downgrade
  protection loses engram data silently — conversation memory, project decisions, accumulated
  observations — with no error message, only degraded or wrong recall.
- **Where this lives in code**: the engram shared-mode block in `export_compose_env()` in `lib/compose.sh`;
  `host_fs_locks_unreliable()` in `lib/paths.sh`.
- **Deep dive**: [docs/architecture.md](docs/architecture.md)

### INV-6: Docker Socket = Root-Equivalent on Host

- **Rule**: Documentation, error messages, and proposals MUST NOT describe the container as
  adversarially isolated. The bind-mounted Docker socket (`docker-compose.yml:53`) gives any
  process inside the container with socket access the ability to run
  `docker run -v /:/host --privileged` and read the entire host filesystem.
- **Why**: This is THE foundational reason the threat model is A (accidents), not B (adversarial).
  A contributor who believes the container is a security sandbox will run untrusted code or allow
  adversarial prompt-injection under that false mental model. The socket-escape command is one
  line (`docker run -v /:/host --privileged`), not a sophisticated exploit.
- **Consequence of violating**: Contributors onboarded with the wrong threat model run untrusted
  workloads or allow prompt-injection attempts inside the container. The eventual outcome is host
  compromise via the Docker socket — a high-severity trust-loss incident against the project.
- **Where this lives in code**: `docker-compose.yml:53` (the socket mount line).
- **Deep dive**: [docs/security.md](docs/security.md)

### INV-7: Threat Model A — Defense Against Accidents, Not Adversaries

- **Rule**: drydock defends against agent accidents (typos, runaway loops, footguns), not
  adversaries. Proposals adding adversarial protections (socket-proxy, gVisor, user-namespace
  isolation, rootless Docker) MUST justify against the actual use case AND show the maintenance
  cost they impose on contributors.
- **Why**: Scope creep into adversarial sandboxing turns drydock into a sandbox-platform
  meta-project, competing with mature sandboxing tools (gVisor, sysbox, firecracker) on their turf
  rather than solving the developer-ergonomics problem it was built for. This boundary is
  reopened only by documented real demand — a concrete use case from a real user — never by
  release cadence or speculative interest.
- **Consequence of violating**: drydock drifts from its niche — a minimal, ergonomic containerized
  dev workspace — into a maintenance-heavy sandbox platform. The resulting complexity drives away
  contributors and the tool is abandoned in favor of simpler alternatives.
- **Where this lives in code**: `N/A — project-policy invariant, enforced socially via §4`
- **Deep dive**: [docs/security.md](docs/security.md)

### INV-8: Container Hardening Defaults

- **Rule**: The container service MUST run with `cap_drop: [ALL]` plus the documented minimum
  `cap_add` set (`DAC_OVERRIDE`, `CHOWN`, `FOWNER`, `SETUID`, `SETGID`),
  `security_opt: [no-new-privileges:true]`, and a size-bounded tmpfs on `/tmp`. These defaults
  ship via the auto-included `docker-compose.hardening.yml` overlay and MAY be disabled
  per-invocation via `DRYDOCK_NO_HARDENING=1` (nuclear opt-out, literal value `"1"` only) or
  tuned via `DRYDOCK_TMPFS_SIZE` (granular tmpfs sizing). Removing any of the three default
  protections from the overlay itself requires re-opening this invariant.
- **Why**: Under threat model A (INV-7) — accidents, not adversaries — a buggy or
  prompt-injected agent issuing `mount -o bind` against unintended host paths succeeds silently
  without `cap_drop: ALL` (`SYS_ADMIN` dropped makes it EPERM instead). A misguided
  invocation of any setuid-root binary present in the base image (`su`, `mount`, `passwd`)
  bypasses the cap drop unless `no-new-privileges:true` is active — a setuid binary can
  re-acquire dropped caps without this guard. A runaway test or build loop writing to `/tmp`
  fills the host's memory-backed tmpfs and stalls the developer's WSL2 VM or macOS host;
  the size cap bounds that accident class at 1g by default. Each defense is sub-10 lines of
  YAML and the marginal cost to contributors is zero.
- **Consequence of violating**: An accident-class agent failure fills the host's memory via `/tmp`,
  escalates via a setuid binary that should have been a no-op, or completes a privileged syscall
  that should have returned EPERM. The failure mode is silent success of the wrong-by-default
  operation — exactly the accident class drydock exists to defend against.
- **Where this lives in code**: `docker-compose.hardening.yml` (overlay definition);
  `lib/compose.sh` (`COMPOSE_HARDENING` constant + the `compose_files()` conditional that includes
  the overlay unless `DRYDOCK_NO_HARDENING` is set to the literal value `"1"`).
- **Deep dive**: [docs/security.md](docs/security.md)

## 3. Code / Tooling Conventions

### Bash

- **Rule**: Every script MUST start with `set -euo pipefail`. No `eval` over user-supplied input.
  No `bash -c "$untrusted"`.
- **Why**: Bash continues silently on errors by default; a failed expansion or unbound variable
  produces a CLI bug invisible at test time and surfaces only in user reports.
- **Consequence of violating**: Production-impacting CLI bugs — wrong cleanup, skipped steps,
  silent data corruption — that ship undetected because `set -e` wasn't active.

### Compose

- **Rule**: Every path in compose files MUST be parameterized via environment variables (`${HOME}`,
  `${USER_NAME}`, `${DRYDOCK_*}`). No literal user-specific path (e.g., `~/<username>/projects`)
  anywhere.
- **Why**: drydock is multi-user infrastructure; hardcoded paths silently break for every
  contributor whose username differs from the one embedded in the file.
- **Consequence of violating**: Blocks contributors entirely — `docker compose up` fails
  immediately with a volume mount error pointing at a path that does not exist on their machine.

### Docker

- **Rule**: No daemon-in-container. The image stays minimal. DooD via the host Docker socket is
  the contract.
- **Why**: Running a nested daemon defeats the DooD model and breaks `make shell-api` against the
  host stack because the container's daemon has no knowledge of the host's running services.
- **Consequence of violating**: `make shell-api` and all compose-targeting commands stop working;
  the container becomes an isolated bubble disconnected from the host dev stack drydock augments.

See `→ CONTRIBUTING.md` for the testing and lint contract.

## 4. Threat Model Boundary

"Accidents" means: typo-in-path deleting the wrong directory, a runaway loop filling disk, a
confused agent writing to the wrong project, an inadvertent `git push --force`. It does NOT mean:
a motivated attacker who controls the agent's input and is trying to escape the container.

- **Rule**: drydock defends against agent accidents, not adversaries. Proposals adding adversarial
  protections — socket-proxy, gVisor, user-namespace remapping, rootless Docker — MUST justify
  against the actual use case AND show the maintenance cost they impose.
- **Why**: Scope creep destroys minimal tools. Every adversarial defense compounds the testing
  matrix (new kernel features, OS compatibility), onboarding friction, and maintenance surface.
  This boundary is reopened only by documented real demand — a concrete use case from a real
  user — never by release cadence or speculative interest.
- **Consequence of violating**: drydock becomes a sandbox-platform meta-project, drifts from its
  ergonomic-dev-workspace niche, and fails to ship because it is competing on sandboxing with
  gVisor and firecracker rather than solving the problem it was built for.

See `→ docs/security.md`.

## 5. Tracking & Contribution

### Issues + Pull Requests

GitHub issues and PRs are the contribution surface. drydock is public open-source; issue
discoverability matters for contributors finding bugs. No separate mailing list or external tracker.

### Commit Conventions

| Convention | Rule |
|---|---|
| Format | `type(scope): subject` |
| Valid types | `feat`, `fix`, `docs`, `refactor`, `test`, `style`, `chore` |
| Co-Authored-By trailers | Prohibited — trailers reflect human collaborators; auto-attribution is noise |
| `--no-verify` | Never — hooks and CI exist for a reason |
| `--force` on shared branches | Never |

CI enforcement gap (v0.1.0): shellcheck enforces Bash conventions; the hook-based deny-list
enforces `--no-verify`/`--force` inside sandboxed sessions. The conventional-commit format
is CI-enforced (v0.2.2+). The `Co-Authored-By` trailer rule remains a §5 soft norm.
They live here because the agent is the primary commit author.

See `→ CONTRIBUTING.md` for the full testing/lint contract.

## 6. Personality / Tone

- Neutral English; warm but direct. No slang or regional expressions.
- Push back when asked for code without sufficient context or problem framing; ask for the
  "what" and "why" before writing the "how."
- Correct errors with technical WHY reasoning — not just "that's wrong." Show evidence.
- Lead with the answer; tables and checklists over prose where applicable.
- Length is a cost: prefer the shorter, clearer statement.
- Respond in the user's language (CLAUDE.md specifies tone, not language override).
