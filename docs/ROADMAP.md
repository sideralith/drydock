# drydock Roadmap

This file is the **single source of truth** for drydock's backlog — what is
planned, why, and in which release. Not GitHub issues, not session notes: this
file.

## How this file works

- This file is the **curated, accepted backlog** — what drydock has decided to
  build and roughly when. It is the single source of truth for the *plan*.
- **Ideas come in through GitHub issues.** Anyone can open one to report a bug or
  propose a feature — that is the front door, and where discussion happens (see
  [CONTRIBUTING.md](../CONTRIBUTING.md)). drydock's contribution surface is GitHub
  issues and PRs (`CLAUDE.md` §5).
- A maintainer **promotes** an accepted idea onto this file, with a scope and a
  rationale. Not every issue becomes a roadmap item — this file is the curated
  subset, not the raw intake. An item may link the issue it came from.
- Release scopes (`v0.2.0`, `v0.2.1`, …) are planning targets, not promises. An
  item moves between releases only by an explicit decision, recorded here.
- **GitHub milestones mirror this file** — a milestone is a derived grouping for
  the GitHub UI, not an authority. If a milestone and this file disagree, this
  file is right and the milestone is fixed.
- A rejected idea is closed as a `wontfix` issue, with the reason in the issue —
  not kept as a tombstone here.

## Summary

| Item | Scope | Issue | Status |
|------|-------|-------|--------|
| [link-sibling-projects](#link-sibling-projects) | v0.2.0 | [#13][i13] | Planned |
| [install-interactive](#install-interactive) | v0.2.0 | [#14][i14] | Planned |
| [auto-sync](#auto-sync) | v0.2.0 | [#15][i15] | Planned |
| [self-awareness](#self-awareness) | v0.2.0 | [#8][i8] | Planned |
| [managed-settings-layer](#managed-settings-layer) | v0.2.0 | — | Planned |
| [destructive-command-guardrails](#destructive-command-guardrails) | v0.2.0 | [#30][i30] | Planned |
| [concurrent-sessions](#concurrent-sessions) | v0.2.0 | [#9][i9] | Planned |
| [ci-commit-lint](#ci-commit-lint) | v0.2.1 | [#10][i10] | Planned |
| [toolchain-mise](#toolchain-mise) | v0.3.0 | [#16][i16] | Planned |
| [per-project-image-layer](#per-project-image-layer) | v0.3.0 | [#17][i17] | Planned |
| [agent-adapter](#agent-adapter) | v0.4.0 | [#18][i18] | Planned |

Release themes — **v0.2.0**: ergonomics & dogfooding · **v0.2.1**: CI hygiene ·
**v0.3.0**: per-project environment customization · **v0.4.0**: drydock as
agent-agnostic infrastructure.

Resolution order — **v0.2.0**: self-awareness → managed-settings-layer →
destructive-command-guardrails → install-interactive → auto-sync →
concurrent-sessions → link-sibling-projects.
Order for later releases is not yet decided.

[i8]: https://github.com/sideralith/drydock/issues/8
[i9]: https://github.com/sideralith/drydock/issues/9
[i10]: https://github.com/sideralith/drydock/issues/10
[i13]: https://github.com/sideralith/drydock/issues/13
[i14]: https://github.com/sideralith/drydock/issues/14
[i15]: https://github.com/sideralith/drydock/issues/15
[i16]: https://github.com/sideralith/drydock/issues/16
[i17]: https://github.com/sideralith/drydock/issues/17
[i18]: https://github.com/sideralith/drydock/issues/18
[i30]: https://github.com/sideralith/drydock/issues/30

---

## v0.2.0 — Ergonomics & dogfooding

### link-sibling-projects

**Problem.** Cross-project work is blind. A drydock session sees only its primary
project; referencing a sibling repo — keeping a marketing site's CTAs consistent
with the app's routes, syncing copy, verifying deep links — today means exiting
drydock and re-launching against the other repo. Constant context switching.

**Proposed solution.** Four commands — `drydock link <path>`, `link --rw <path>`,
`unlink <path>`, `links`. Siblings mount read-only by default (`--rw` opt-in) at
`/workspace-siblings/<name>/`, leaving `/workspace` untouched. Configuration
persists in `~/.config/drydock/links/<project>.list`, one absolute path per line.
The mount is delivered by a generated `docker-compose.links.yml` overlay — the
same pattern as submount-propagation.

**Why this scope.** Recurring, concrete maintainer friction; pure ergonomics.

**Invariants touched.** None weakened. A linked sibling is the same blast radius
as a project the agent could `cd` into directly — within threat model A (INV-7).
Hooks (INV-3) apply uniformly across primary and siblings.

**Open questions.** RW semantics need a design phase: which `CLAUDE.md` governs
edits inside a sibling, whether the primary's hooks cover sibling writes (likely
yes — hooks are container-global), and git identity for sibling commits.

**Provenance.** engram #1064 (2026-05-15).

### install-interactive

**Problem.** `install.sh` runs fully non-interactively. A user on a real terminal
is never asked about engram mode, building the image, or PATH setup — they get
defaults and discover the manual steps late or never.

**Proposed solution.** TTY-gated prompts: when stdin *and* stdout are TTYs, ask;
under `curl | bash` (pipe stdin) skip silently with current defaults. The gate is
`[ -t 0 ] && [ -t 1 ]`. High-value prompts: engram mode (Linux-native only),
build the image now, add `~/.local/bin` to the shell rc. Seven more items are
mapped at medium/low priority.

**Why this scope.** Ergonomics; small (~100 lines plus an `ask()` helper).

**Invariants touched.** INV-5 — the engram-mode prompt must respect the
force-isolated downgrade on WSL2/macOS (do not offer shared mode there).

**Open questions.** Which of the medium-priority items make the first cut.

**Provenance.** engram #1053.

### auto-sync

**Problem.** INV-2 splits host `~/.claude/` from the container's
`~/.claude-container/`. Host-side config changes (statusline, hooks, skills, MCP
config) do not reach the container unless the user remembers to run
`drydock sync`. The command is one line but undiscoverable.

**Proposed solution.** Opportunistic auto-sync at the start of `drydock run` /
`drydock shell`: an mtime check, silent on the happy path, running the existing
sync only when the container copy is stale. Escape hatch: `DRYDOCK_SKIP_AUTOSYNC=1`.

**Why this scope.** Ergonomics; roughly a mini-SDD.

**Invariants touched.** INV-2 — auto-sync must move config only, never the
SQLite-bound state the split exists to protect.

**Open questions.** None major. A read-only bind-mount of `settings.json` was
considered and rejected pending an empirical test of whether Claude Code writes
to that file.

**Provenance.** engram #1055.

### self-awareness

**Problem.** A Claude session inside a drydock container has nothing telling it
it is containerized — only the generic `/.dockerenv`. It assumes an ordinary host
and hits drydock-specific behavior blind: noexec `/tmp`, root-owned `~/.cache`,
absent `~/.ssh`.

**Proposed solution.** A detectable marker (`DRYDOCK=1` + `DRYDOCK_VERSION`,
and/or `/etc/drydock-release`) plus a `SessionStart` hook in the read-only hooks
overlay that injects the awareness as session context. The hook is tamper-proof
(INV-3) and can print live facts rather than text that goes stale.

**Why this scope.** Ergonomics / dogfooding. The friction in issue #3 is the
proof the gap is real.

**Invariants touched.** INV-3 (the hook lives in the read-only overlay); INV-6
(the injected text must frame the Docker socket as root-equivalent — *not* a
security sandbox).

**Open questions.** Exact hook output format; static marker text vs. a live probe.

**Provenance.** This session; issue [#8][i8].

### managed-settings-layer

**Problem.** drydock's `permissions.deny` block and `hooks.SessionStart` entry were
seeded by `drydock init` into a per-project `settings.json` — a writable file. An
instruction-following agent could overwrite that file mid-session, silently removing
the deny guardrails for the remainder of the session. The hook *scripts* were already
structural (RO bind-mount, INV-3), but the *policy rules* were only advisory.

**Proposed solution.** Deliver drydock's agent policy — the deny entries (secret
protection, git safety) and the `hooks.SessionStart` entry — as a Claude Code
managed-settings drop-in baked into the image. The files are COPYied into the
Dockerfile at `/etc/claude-code/managed-settings.d/` (root-owned) and `__HOME__`
is resolved via a `RUN sed` at build time. The non-root container user cannot write
to `/etc/`, so the policy is tamper-proof by image-layer ownership. Claude Code loads
managed settings at highest precedence; the rules cannot be weakened from project
settings. `drydock init` is reshaped to a lightweight stub-seeder (no deny entries,
no hook wiring — the stub is for project-specific customization only); the
`--update` flag (whose deny-merge logic is now obsolete) is removed.

**Why this scope.** Security / correctness. Closes an existing INV-3-spirit gap:
today the hook *script* is RO but the deny *list* and hook *entry* sit in a RW
project file. Pairs naturally with the `self-awareness` item (which added the
`SessionStart` hook this change relocates). Small, bounded change; no new external
dependencies.

**Invariants touched.** INV-3 strengthened — the deny block and hook entry become
structurally tamper-proof rather than advisory. INV-2 untouched — the
managed-settings dir lives at `/etc/claude-code/`, outside `$HOME`, never crossing
the host/container state-split boundary.

**Open questions.** None for v0.2.0. A `--migrate` subcommand to strip redundant
deny+hook blocks from existing project `settings.json` files is a post-v0.2.0
nice-to-have if demand surfaces.

**Provenance.** engram exploration #1159 + proposal #1160.

### destructive-command-guardrails

**Problem.** drydock's shipped guardrails cover a narrow slice of the accident
class its threat model targets. `managed-settings.d/10-git-safety.json` holds 11
declarative `permissions.deny` patterns — all git — and `00-secrets.json` covers
secret reads. Nothing ships for the broader accident class: `rm -rf` against
system paths, disk destruction (`dd`, `mkfs`, `wipefs`), fork bombs, firewall
flush, package-manager purges, `curl | sh` pipes. Users who want that coverage
hand-roll a personal `PreToolUse` hook; drydock protects such a hook read-only
(INV-3) but does not provide one.

**Proposed solution.** A shipped guardrail layer, deny-first. Every command class
expressible as an exact pattern becomes a `permissions.deny` entry — the
mechanism `10-git-safety.json` already uses — because declarative patterns are
precedence-correct and carry no regex false-positive surface. A `PreToolUse`
regex hook is added only for the residue that deny patterns genuinely cannot
express (multi-token / contextual matches), wired via the managed-settings layer
to a script in drydock's read-only hooks overlay (INV-3), never via the
user's `~/.claude/hooks/`. Source
material is triaged from an existing hand-rolled `block-destructive.sh`: keep
universal threat-model-A rules, drop stack-specific ones, translate messages to
English (§6). Known regex false positives are fixed in the shipped version — the
`git branch` rule mismatching long flags (`--merged`, `--no-merged`) as
deletions, and the force-push rule matching protected names as substrings
(`fix/main-bug`). Overlap with `10-git-safety.json` is resolved to one mechanism
per command class.

**Why this scope.** Security / correctness, squarely threat model A (INV-7) —
`rm -rf /`, a filled disk, a flushed firewall are the footgun class drydock
exists to catch. Pairs with `managed-settings-layer`, whose deny mechanism this
extends. Exit criterion: a drydock user can delete their personal
`block-destructive.sh` and rely on what drydock ships.

**Invariants touched.** INV-3 — a hook, if one is needed, lives in the
managed-settings layer / RO overlay, tamper-proof rather than advisory. INV-7 —
the scope boundary: accident-class coverage only, no adversarial protections.
INV-2 untouched.

**Open questions.** The deny-vs-hook split — exactly which command classes can be
expressed as deny patterns and which genuinely need the hook. Whether the git
section of the source hook is dropped entirely in favour of the existing
`10-git-safety.json`. The test-suite shape for ~30 rules.

**Provenance.** This session; issue [#30][i30].

### concurrent-sessions

**Problem.** `cmd_run` names the container deterministically `drydock-<project>`.
A second `drydock` in the same project collides on that name and is refused — no
parallel sessions on one repo.

**Proposed solution.** A name discriminator so concurrent same-project sessions
get distinct containers.

**Why this scope.** Ergonomics.

**Invariants touched.** None. The v0.1.2 friendly diagnostic that refuses to kill
a running container must be preserved — this allows a *second* container, it does
not reuse or kill the first.

**Open questions.** The discriminator scheme (numeric suffix, branch-derived, …).

**Provenance.** v0.1.2-era engram follow-up; issue [#9][i9].

---

## v0.2.1 — CI hygiene

### ci-commit-lint

**Problem.** `CLAUDE.md` §5 records that conventional-commit format is a soft
norm, not CI-enforced. A non-conforming subject can ship undetected.

**Proposed solution.** A CI job that lints the conventional-commit subject format
(`type(scope): subject`, allowed types per §5). **Scope deliberately narrowed:**
the `Co-Authored-By` trailer ban is *not* CI-enforced — it remains a §5 soft norm.
CI-enforcing a custom trailer ban is unusual in OSS and not worth the machinery.

**Why this scope.** Pure CI infrastructure, no user-facing change — kept out of
the v0.2.0 feature story and shipped as a small hygiene patch.

**Invariants touched.** None.

**Open questions.** `commitlint` with a conventional config vs. a hand-rolled
check.

**Provenance.** The §5 enforcement gap; this session; issue [#10][i10].

---

## v0.3.0 — Per-project environment customization

### toolchain-mise

**Problem.** drydock's base image is intentionally minimal — one toolchain.
Multi-language projects (Python, Go, Rust) have no per-project toolchain story,
and adding toolchains to the image would balloon it from ~250 MB to multi-GB,
violating the "image stays minimal" rule (§3, Docker).

**Proposed solution.** Use `mise` (formerly `rtx`) as the primitive: a ~12 MB
binary in the image; toolchains themselves live in a host-mounted volume, not the
image. Per-project `.mise.toml`, matching drydock's per-project declarative
pattern.

**Why this scope.** Pairs with `per-project-image-layer` under the "per-project
environment customization" theme — `mise` handles language runtimes, the image
layer handles system packages. Co-designed so the two do not become overlapping
"add stuff" mechanisms. Touches the Dockerfile and volume layout — a different
kind of change from v0.2.0's ergonomics items.

**Invariants touched.** §3 Docker convention — `mise` is the design chosen
*because* it keeps the image minimal.

**Open questions.** macOS volume-mount performance for the mise cache; pin the
`mise` version vs. always-latest; coexistence with project-native version
managers.

**Provenance.** engram #1010.

### per-project-image-layer

**Problem.** `drydock build` builds one shared image for every project
(`cmd_build`). A heavy, optional dependency that one project needs — the Chromium
runtime libraries for the Playwright MCP, ~150 MB — was hardcoded into that
shared image, so every project inherits the bloat whether it does browser
automation or not. This is a §3 ("the image stays minimal") drift, and the next
heavy optional dependency will repeat it.

**Proposed solution.** A per-project derived image. drydock keeps building the
minimal shared base; a project that declares extra needs gets a thin
`drydock-<project>` image built `FROM` the base. Two tiers:

- **Declarative (the common case)** — a file committed in the project repo
  listing extra Debian packages, and optionally extra apt sources *as data*
  (repo URL + signing key). drydock turns it into image layers. Declarative data
  only, never arbitrary commands — so a committed file is not a root-code
  execution vector.
- **Escape hatch (advanced)** — a project may instead ship its own Dockerfile
  `FROM` the drydock base for arbitrary build steps. Explicit opt-in, full power,
  owned by the dev. This is why the declarative file does *not* need to grow a
  "run any command" capability.

Both tiers produce the per-project derived image; Docker layer caching keeps
rebuilds cheap.

**Why this scope.** Pairs with `toolchain-mise` under the "per-project
environment customization" theme — `mise` handles language runtimes (userspace,
host-mounted volume), this handles system packages (root, image build).
Co-designed so the two do not become overlapping "add stuff" mechanisms.

**Invariants touched.** §3 Docker convention — *restores* "the image stays
minimal" for the base (the bloat moves per-project); the v0.1.x Playwright
hardcoding is the concrete drift this undoes. INV-8 — packages install at build
time because the running container is non-root with `no-new-privileges` (runtime
`apt` is impossible). INV-7 — the declarative file is data, not commands, so a
committed file is not an execution vector; the BYO-Dockerfile escape hatch is an
explicit advanced opt-in (standard Docker, owned by the dev).

**Open questions.** File format and name; whether the declarative file and a BYO
project Dockerfile are alternatives or composable; per-project image naming and
cache invalidation; whether a per-dev layer in `~/.config/drydock/` is a
follow-up.

**Provenance.** This session — exploration triggered by the Playwright Dockerfile
addition (engram #1129) bloating the shared image.

---

## v0.4.0 — drydock as agent-agnostic infrastructure

### agent-adapter

**Problem.** drydock is currently a Claude Code-specific workspace. Other coding
agents (Codex, OpenCode, pi.dev) cannot use it without per-agent assumptions
baked into the CLI.

**Proposed solution.** An adapter layer abstracting the agent-specific pieces —
config paths, container state layout, MCP wiring — so drydock can host more than
one agent.

**Why this scope.** A release of its own — abstracting the agent boundary is a
large, distinct effort, separate from the per-project-environment theme of v0.3.0.

**Invariants touched.** INV-2 (each agent needs its own container-state split);
INV-4 (the engram-optional principle generalizes — no agent should be
hard-required).

**Open questions.** This item has **no design memo yet** and needs a proper
exploration before it is actionable — currently the least-defined item on the
roadmap.

**Provenance.** Referenced as future-release work in engram #1010 and #1053; no
dedicated memo.
