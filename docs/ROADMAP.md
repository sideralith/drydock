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
- A discarded item stays listed, with its reason, so it is not silently
  re-proposed.

## Summary

| Item | Scope | Issue | Status |
|------|-------|-------|--------|
| [link-sibling-projects](#link-sibling-projects) | v0.2.0 | — | Planned |
| [install-interactive](#install-interactive) | v0.2.0 | — | Planned |
| [auto-sync](#auto-sync) | v0.2.0 | — | Planned |
| [self-awareness](#self-awareness) | v0.2.0 | [#8][i8] | Planned |
| [concurrent-sessions](#concurrent-sessions) | v0.2.0 | [#9][i9] | Planned |
| [ci-commit-lint](#ci-commit-lint) | v0.2.1 | [#10][i10] | Planned |
| [toolchain-mise](#toolchain-mise) | v0.3.0 | — | Planned |
| [agent-adapter](#agent-adapter) | v0.3.0 | — | Planned |
| [unreal-template](#unreal-template) | — | — | Discarded |

Release themes — **v0.2.0**: ergonomics & dogfooding · **v0.2.1**: CI hygiene ·
**v0.3.0**: drydock as agent-agnostic infrastructure.

Resolution order within a release is not yet decided.

[i8]: https://github.com/sideralith/drydock/issues/8
[i9]: https://github.com/sideralith/drydock/issues/9
[i10]: https://github.com/sideralith/drydock/issues/10

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

## v0.3.0 — drydock as agent-agnostic infrastructure

### toolchain-mise

**Problem.** drydock's base image is intentionally minimal — one toolchain.
Multi-language projects (Python, Go, Rust) have no per-project toolchain story,
and adding toolchains to the image would balloon it from ~250 MB to multi-GB,
violating the "image stays minimal" rule (§3, Docker).

**Proposed solution.** Use `mise` (formerly `rtx`) as the primitive: a ~12 MB
binary in the image; toolchains themselves live in a host-mounted volume, not the
image. Per-project `.mise.toml`, matching drydock's per-project declarative
pattern.

**Why this scope.** Pairs with `agent-adapter` as the "agent-agnostic
infrastructure" release. It touches the Dockerfile and volume layout — a
different kind of change from v0.2.0's ergonomics items. (Moved here from v0.2.0
by an explicit decision: keeping the pair together gives both releases a clean
identity.)

**Invariants touched.** §3 Docker convention — `mise` is the design chosen
*because* it keeps the image minimal.

**Open questions.** macOS volume-mount performance for the mise cache; pin the
`mise` version vs. always-latest; coexistence with project-native version
managers.

**Provenance.** engram #1010.

### agent-adapter

**Problem.** drydock is currently a Claude Code-specific workspace. Other coding
agents (Codex, OpenCode, pi.dev) cannot use it without per-agent assumptions
baked into the CLI.

**Proposed solution.** An adapter layer abstracting the agent-specific pieces —
config paths, container state layout, MCP wiring — so drydock can host more than
one agent.

**Why this scope.** The headline of the agent-agnostic release; pairs with
`toolchain-mise`.

**Invariants touched.** INV-2 (each agent needs its own container-state split);
INV-4 (the engram-optional principle generalizes — no agent should be
hard-required).

**Open questions.** This item has **no design memo yet** and needs a proper
exploration before it is actionable — currently the least-defined item on the
roadmap.

**Provenance.** Referenced as v0.3.0-paired work in engram #1010 and #1053; no
dedicated memo.

---

## Discarded

### unreal-template

**What it was.** An `examples/unreal/` template with deny-list entries for Unreal
Engine's generated directories (`Saved/`, `Intermediate/`, `Build/`, `Binaries/`).

**Why discarded.** No acceptance criteria and no demonstrated demand. Recorded
here so it is not silently re-proposed; revivable if a real Unreal Engine user
asks.

**Provenance.** v0.2.0 handoff (optional item).
