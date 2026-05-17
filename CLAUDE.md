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

Eight invariants, each following the Mercadona pattern — Rule, Why (with a specific falsifiable
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
  `~/.config/drydock/` exclusively).
- **Deep dive**: [docs/security.md](docs/security.md)

### INV-2: Container State Split

- **Rule**: Container mounts MUST point at `~/.claude-container/`, `~/.claude-container.json`,
  and `~/.engram-container/` — never at the host's `~/.claude/`, `~/.claude.json`, or
  `~/.engram/`.
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
  MCP entry filtered out via `jq 'del(.mcpServers.engram, ...)'` (`commands.sh:110,244`). If the
  container shared the host's live `~/.claude.json`, that filter would destructively mutate it —
  stripping the engram MCP entry from the host's own config.
  (4) **When engram is in use — `~/.engram/engram.db` SQLite WAL corruption.** The hazard is NOT
  concurrency alone: SQLite WAL is explicitly designed for concurrent access. Corruption requires
  concurrency PLUS a filesystem where `fcntl` advisory locks are UNRELIABLE — the WSL2 9P bridge,
  macOS virtiofs, or a bind-mount crossing the Docker Desktop VM boundary. On a native filesystem
  with working `fcntl` locks, multiple sessions are safe; the cross-VM-boundary mount is what breaks
  the lock guarantee. (The engram DB lock semantics are governed in detail by INV-5.)
- **Consequence of violating**: Sharing host `~/.claude/`, `~/.claude.json`, and `~/.engram/` with
  the container produces silent failure across all four reasons: concurrent sessions clobber
  `~/.claude.json` writes (last-writer-wins, lost config — no error); trigger an OAuth lockout
  requiring re-authentication of both sessions via `.credentials.json`; have the container's MCP
  filter destructively mutate the host's live config, destroying the host's engram MCP entry; and —
  on an unreliable-`fcntl`-lock filesystem (WSL2 9P, macOS virtiofs, Docker Desktop VM boundary) —
  silently corrupt `~/.engram/engram.db` via a WAL page clash. Every failure mode is silent: data
  loss or auth loss with no obvious cause.
- **Where this lives in code**: `lib/paths.sh:23-33` (container path constants);
  `docker-compose.yml:61-62` (mounts).
- **Deep dive**: [docs/architecture.md](docs/architecture.md)

### INV-3: Hooks Read-Only Overlay

- **Rule**: `~/.claude/hooks/` MUST be bind-mounted `:ro` on top of the container's `.claude`
  mount. The agent MUST NOT have write access to its own hook scripts.
- **Why**: The hooks directory is the tier-1 defense layer — deny-lists, guardrails, and
  confirmation prompts live there. If the agent can write here, protection is advisory rather than
  structural. A sufficiently instruction-following agent can disable its own guardrails mid-session
  by overwriting the hook scripts, then proceed without them.
- **Consequence of violating**: A buggy or prompt-injected agent disables its own guardrails
  mid-session. All hook-based protections are silently bypassed for the remainder of the session
  with no indication to the operator.
- **Where this lives in code**: `docker-compose.yml:65` (the `:ro` override line).
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
- **Where this lives in code**: `lib/compose.sh:30-32` (`engram_usable` gate);
  `lib/commands.sh:107-126` (MCP filter).
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
- **Where this lives in code**: `lib/compose.sh:105-122` (shared-mode resolution);
  `lib/paths.sh:74-79` (`host_fs_locks_unreliable`).
- **Deep dive**: [docs/architecture.md](docs/architecture.md)

### INV-6: Docker Socket = Root-Equivalent on Host

- **Rule**: Documentation, error messages, and proposals MUST NOT describe the container as
  adversarially isolated. The bind-mounted Docker socket (`docker-compose.yml:51`) gives any
  process inside the container with socket access the ability to run
  `docker run -v /:/host --privileged` and read the entire host filesystem.
- **Why**: This is THE foundational reason the threat model is A (accidents), not B (adversarial).
  A contributor who believes the container is a security sandbox will run untrusted code or allow
  adversarial prompt-injection under that false mental model. The socket-escape command is one
  line (`docker run -v /:/host --privileged`), not a sophisticated exploit.
- **Consequence of violating**: Contributors onboarded with the wrong threat model run untrusted
  workloads or allow prompt-injection attempts inside the container. The eventual outcome is host
  compromise via the Docker socket — a high-severity trust-loss incident against the project.
- **Where this lives in code**: `docker-compose.yml:51` (the socket mount line).
- **Deep dive**: [docs/security.md](docs/security.md)

### INV-7: Threat Model A — Defense Against Accidents, Not Adversaries

- **Rule**: drydock defends against agent accidents (typos, runaway loops, footguns), not
  adversaries. Proposals adding adversarial protections (socket-proxy, gVisor, user-namespace
  isolation, rootless Docker) MUST justify against the actual use case AND show the maintenance
  cost they impose on contributors.
- **Why**: Scope creep into adversarial sandboxing turns drydock into a sandbox-platform
  meta-project, competing with mature sandboxing tools (gVisor, sysbox, firecracker) on their turf
  rather than solving the developer-ergonomics problem it was built for. v0.2.0 may revisit if
  there is documented real demand.
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
  v0.2.0 may revisit if real documented demand emerges — not speculative demand.
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
