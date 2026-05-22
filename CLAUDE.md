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
  `~/.claude.json`, and `~/.engram/` MUST NEVER be mounted into the container.
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
- **Where this lives in code**: the `HOST_CLAUDE` / `CONTAINER_CLAUDE` / `*_JSON` / `*_ENGRAM` path-constants block in `lib/paths.sh`;
  the `${DRYDOCK_SESSION_CLAUDE_DIR}` / `${DRYDOCK_SESSION_CLAUDE_JSON}` mount lines in `docker-compose.yml`;
  the `${HOME}/.claude-container/projects:${HOME}/.claude/projects:rw` sub-mount line in
  `docker-compose.yml`; `export_compose_env()` in `lib/compose.sh` (generates and exports the
  per-session discriminator paths); `migrate_projects_to_shared_store()` in `lib/compose.sh`
  (one-time sentinel-gated upgrade sweep).
- **Deep dive**: [docs/architecture.md](docs/architecture.md)

### INV-3: Hooks Read-Only Overlay

- **Rule**: `~/.claude/hooks/` MUST be bind-mounted `:ro` on top of the container's `.claude`
  mount. The agent MUST NOT have write access to its own hook scripts. Additionally, drydock's
  agent policy — the `permissions.deny` block and the `hooks.SessionStart` entry — MUST be
  delivered via a Claude Code managed-settings drop-in baked into the image and owned by root.
  The agent MUST NOT have write access to these policy files.
- **Why**: The hooks directory and the managed-settings layer together form the tier-1 defense.
  The hook scripts (guardrails, block-destructive) are RO via bind-mount. The deny block and the
  SessionStart hook entry are tamper-proof via image-layer ownership: they live at
  `/etc/claude-code/managed-settings.d/` (root-owned, non-root container user), loaded by Claude
  Code at highest precedence and not overridable from project settings. Both protections are
  structural, not advisory. Before v0.2.0, the deny block and hook entry lived in a per-project
  `settings.json` that a sufficiently instruction-following agent could overwrite, silently
  weakening the guardrails for the remainder of the session.
- **Consequence of violating**: A buggy or prompt-injected agent disables its own guardrails
  mid-session. Hook-based protections are silently bypassed for the remainder of the session
  with no indication to the operator.
- **Where this lives in code**: the `${HOME}/.claude/hooks` `:ro` bind-mount line in `docker-compose.yml`;
  `Dockerfile` (COPY+RUN block that bakes `templates/managed-settings.d/` into the image);
  `templates/managed-settings.d/` (policy drop-ins: `00-secrets.json`, `10-git-safety.json`,
  `20-hooks.json`, `30-os-safety.json`, `40-guardrails-hook.json`);
  `templates/hooks/drydock-block-destructive.sh` (PreToolUse guardrail hook, RO bind-mount).
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
enforces `--no-verify`/`--force` inside sandboxed sessions. Conventional-commit format and
trailer rules are soft norms — not CI-enforced yet. They live here because the agent is the
primary commit author.

See `→ CONTRIBUTING.md` for the full testing/lint contract.

## 6. Personality / Tone

- Neutral English; warm but direct. No slang or regional expressions.
- Push back when asked for code without sufficient context or problem framing; ask for the
  "what" and "why" before writing the "how."
- Correct errors with technical WHY reasoning — not just "that's wrong." Show evidence.
- Lead with the answer; tables and checklists over prose where applicable.
- Length is a cost: prefer the shorter, clearer statement.
- Respond in the user's language (CLAUDE.md specifies tone, not language override).
