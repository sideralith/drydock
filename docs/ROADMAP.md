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
- **Status flips in the shipping PR.** When a roadmap item ships, its Status in the Summary table flips to `Done` and the linked GitHub issue is closed **in the same PR that delivers the change** — never deferred to a later commit or cleanup pass. A merged item still marked `Planned` is a bug in this file.
- A rejected idea is closed as a `wontfix` issue, with the reason in the issue —
  not kept as a tombstone here.

## Summary

| Item | Scope | Issue | Status |
|------|-------|-------|--------|
| [link-sibling-projects](#link-sibling-projects) | v0.2.0 | [#13][i13] | Done |
| [rw-sibling-mode](#rw-sibling-mode) | v0.2.0 | [#47][i47] | Done |
| [install-interactive](#install-interactive) | v0.2.0 | [#14][i14] | Done |
| [auto-sync](#auto-sync) | v0.2.0 | [#15][i15] | Done |
| [self-awareness](#self-awareness) | v0.2.0 | [#8][i8] | Done |
| [managed-settings-layer](#managed-settings-layer) | v0.2.0 | — | Done |
| [destructive-command-guardrails](#destructive-command-guardrails) | v0.2.0 | [#30][i30] | Done |
| [concurrent-sessions](#concurrent-sessions) | v0.2.0 | [#9][i9] | Done |
| [claude-oauth-token](#claude-oauth-token) | v0.2.1 | [#58][i58] | Done |
| [doctor-staleness-warning](#doctor-staleness-warning) | v0.2.1 | [#60][i60] | Done |
| [container-config-overlay](#container-config-overlay) | v0.2.1 | [#77][i77] | Done |
| [session-awareness-state-model](#session-awareness-state-model) | v0.2.1 | [#79][i79] | Done |
| [guardrail-deny-layer-port](#guardrail-deny-layer-port) | v0.2.1 | [#76][i76] | Done |
| [ci-commit-lint](#ci-commit-lint) | v0.2.2 | [#10][i10] | Done |
| [hooks-mount-source](#hooks-mount-source) | v0.2.2 | [#71][i71] | Done |
| [integration-in-ci](#integration-in-ci) | v0.2.2 | [#74][i74] | Done |
| [session-persistence](#session-persistence) | v0.3.0 | [#64][i64] | Done |
| [session-management-ui](#session-management-ui) | v0.3.0 | [#67][i67] | Not planned (closed; successor: external [drydock-zellij-plugin][i97], post-v0.3.0) |
| [toolchain-mise](#toolchain-mise) | v0.4.0 | [#16][i16] | Planned |
| [per-project-image-layer](#per-project-image-layer) | v0.4.0 | [#17][i17] | Planned |
| [agent-adapter](#agent-adapter) | v0.5.0 | [#18][i18] | Planned |
| [sandcastle-sandbox-provider](#sandcastle-sandbox-provider) | v0.6.0 | [#66][i66] | Planned |

Release themes — **v0.2.0**: ergonomics & dogfooding · **v0.2.1**: CI hygiene & post-v0.2.0 polish ·
**v0.2.2**: CI hygiene & infrastructure polish · **v0.3.0**: session persistence & multi-session UX ·
**v0.4.0**: per-project environment customization · **v0.5.0**: drydock as agent-agnostic infrastructure ·
**v0.6.0**: programmatic agent orchestration.

Resolution order — **v0.2.0**: install-interactive → auto-sync →
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
[i31]: https://github.com/sideralith/drydock/issues/31
[i47]: https://github.com/sideralith/drydock/issues/47
[i58]: https://github.com/sideralith/drydock/issues/58
[i60]: https://github.com/sideralith/drydock/issues/60
[i64]: https://github.com/sideralith/drydock/issues/64
[i66]: https://github.com/sideralith/drydock/issues/66
[i67]: https://github.com/sideralith/drydock/issues/67
[i71]: https://github.com/sideralith/drydock/issues/71
[i74]: https://github.com/sideralith/drydock/issues/74
[i76]: https://github.com/sideralith/drydock/issues/76
[i77]: https://github.com/sideralith/drydock/issues/77
[i79]: https://github.com/sideralith/drydock/issues/79
[i97]: https://github.com/sideralith/drydock/issues/97

---

## v0.2.0 — Ergonomics & dogfooding

### link-sibling-projects

**Status: Done (v0.2.0, issue #13).**

**Problem.** Cross-project work is blind. A drydock session sees only its primary
project; referencing a sibling repo — keeping a marketing site's CTAs consistent
with the app's routes, syncing copy, verifying deep links — today means exiting
drydock and re-launching against the other repo. Constant context switching.

**What shipped.** Read-only sibling linking: `drydock link <path>`,
`drydock unlink <path>`, `drydock links`. Siblings mount `:ro` at
`/workspace-siblings/<basename>` (or a custom path) inside the container.
Configuration persists in `~/.config/drydock/links/<project>.list` (pipe-delimited
3-column format: `<host>|<target>|<flags>`). On every `drydock run`/`shell`, the
list is projected to an ephemeral `drydock-links-$$.yml` overlay — same pattern as
submount-propagation. Path-rejection guards, basename collision detection, and
idempotent re-link are all implemented. INV-1 credential deny rules were rewritten
from `__HOME__`-anchored to `//**/`-root-anchored (credentials now denied at any
mount depth, protecting credentials inside mounted siblings).

**Provenance.** engram #1064 (2026-05-15). RW sibling mode shipped as a
follow-up change — see [rw-sibling-mode](#rw-sibling-mode) below.

### rw-sibling-mode

**Status: Done (v0.2.0, issue #47).**

**Problem.** Read-only sibling linking (`link-sibling-projects`) covers the most
common use case — cross-project reference — but blocks any workflow that needs to
write to a sibling: committing a fix in a shared library while iterating in the
primary project, or landing a docs PR in a separate docs repo. The existing `:ro`
mount prevents `git push` and all write operations.

**What shipped.** `drydock link --rw <path>`: per-sibling ed25519 deploy keys
generated at `~/.config/drydock/keys/<basename>_deploy{,.pub}`, a managed SSH
config at `~/.config/drydock/ssh-config-<primary>` with `Host github.com-<sibling>`
alias blocks, and `GIT_SSH_COMMAND` set to route through the managed config
inside the container. The keys directory mounts `:ro` as a directory — no
per-key overlay enumeration, scales to N siblings. A cross-project basename
collision check scans ALL `*.list` files at link time. `drydock unlink` prints
a dual hint covering both the local key path (for `rm`) and the GitHub-side
deploy key revocation URL, because drydock cannot revoke remote deploy keys.

Routing fix (#89, v0.2.2): URL aliasing happens inside the container via
`url.insteadOf` in a per-project gitconfig at
`~/.config/drydock/gitconfig-<primary>` (pointed at by `GIT_CONFIG_GLOBAL`).
The sibling's `.git/config` is never mutated, so the host's `git fetch` keeps
working with the canonical URL. v0.2.1's `remote.origin.url` rewrite (which
broke host git) was removed; the first `drydock run` after upgrading auto-
restores aliased URLs to canonical. See `docs/links.md` for the user-facing
workflow.

**Status.** Done — shipped in v0.2.0 (issue #47); host-contamination fix
shipped in v0.2.2 (issue #89).

**Provenance.** SDD artifacts in engram: spec #2442, design #2443, tasks #2444.

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

**Shipped.** Three prompts implemented (plus a conditional rc-file sub-prompt):
engram shared-mode (native Linux only, INV-5 trichotomy), build-image
(non-fatal, default N), and PATH rc-append (idempotent; when `$SHELL` is
ambiguous and multiple rc files exist, a numbered rc-file sub-prompt picks the
target). Non-interactive path (`curl | bash`, `DRYDOCK_INTERACTIVE=0`) is
byte-identical.

**Status.** Done — shipped in v0.2.0 (issue #14 closed).

### auto-sync

**Status.** Done — shipped in v0.2.0 (issue #15 closed).

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

**Open questions.** None — resolved. A read-only bind-mount of `settings.json`
was considered as an alternative delivery mechanism and dropped: auto-sync's
copy model supersedes it, and a bind-mount would reintroduce a host/container
write-back concern (INV-2) that the copy model avoids — the container's copy is
the container's, regardless of whether Claude Code writes to it.

**Provenance.** engram #1055.

### self-awareness

**Status.** Done — shipped in v0.2.0 (issue #8 closed).

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

**Status.** Done — shipped in v0.2.0.

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
settings.

**Follow-up note (v0.2.1).** With the deny entries and hook wiring relocated to
managed-settings, `drydock init` was reshaped to a stub-seeder for project-only
customization. v0.2.1 went further and removed `drydock init` entirely once it
lost its load-bearing role — Claude Code creates `.claude/settings.json` lazily
when the user adds MCP servers, hooks, or permissions through its own commands.
The `--update` flag (whose deny-merge logic became obsolete in v0.2.0) was also
removed.

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

**Status.** Done — shipped in v0.2.0 via PR #32 (issue #30 closed). The quoted-target follow-up ([#31][i31]) was also resolved in v0.2.0 — the guardrail hook now normalizes single and double quote pairs around path tokens before applying the anchored regex checks.

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

**Status.** Done — shipped in v0.2.0 (issue #9 closed).

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

## v0.2.1 — CI hygiene & post-v0.2.0 polish

### claude-oauth-token

**Status.** Done — shipped in v0.2.1 (issue #58 closed by PR #59).

**Problem.** Every `drydock run` session required a browser-based login to
authenticate Claude Code. There was no way to persist a Claude account OAuth
token so sessions start pre-authenticated.

**What shipped.** `drydock setup-token` prompts for a Claude OAuth token and
writes it to `~/.config/drydock/claude-oauth-token` with mode `0600`. A new
compose overlay (`docker-compose.oauth.yml`) injects the value as
`CLAUDE_CODE_OAUTH_TOKEN` when the token file is present and non-empty — Claude
Code picks it up at precedence level 5 (above `.credentials.json`). `drydock
revoke-token` removes the local file; full revocation also requires visiting
claude.ai → Settings. The token file is covered by the image-baked
`Read(__HOME__/.config/drydock/**)` deny rule — the agent cannot read it.
See [security.md — Claude OAuth token](security.md#claude-oauth-token-docker-composeoauthyml)
for the full security discussion.

**Provenance.** Issue [#58][i58], PR #59.

### doctor-staleness-warning

**Status.** Done — shipped in v0.2.1 (issue #60 closed by PR #61).

**Problem.** The Claude OAuth token (`claude-oauth-token`) has a ~1-year
lifetime. There was no built-in prompt for the approaching expiry — users
would discover it only when sessions stopped authenticating.

**What shipped.** `drydock doctor` (the existing health-check command) gained a
check that reads the token file's mtime. When the file is over 330 days old
(~35-day runway before expiry), the row shows `⚠` instead of `✓` and points
the user at `drydock setup-token --force` to refresh.

**Provenance.** Issue [#60][i60], PR #61.

### container-config-overlay

**Status: Done (v0.2.1, issue #77).**

**Problem.** Config edits made inside a drydock container under `~/.claude/`
(e.g. a plugin's `.mcp.json` flag — `--browser chromium` for the Playwright
MCP) worked for the session and vanished on the next `drydock run`: each
invocation re-seeds the per-session `~/.claude-container-<disc>/` from a
prototype, so any in-container edit not synced back to the host is lost.
INV-2 prohibits making the host's `~/.claude/` the writable source of the
container's state by design — so the obvious "just bind-mount it" path is
closed, leaving a class of container-only config (per-MCP flags,
per-skill state) without a persistence story.

**What shipped.** A host-authored overlay at `~/.config/drydock/claude-overlay/`
mirroring the `~/.claude/` tree. When present, drydock copies it whole-file
and recursively on top of the freshly re-seeded session dir —
host-authored, container-consumed, unidirectional. Scope is enforced
fail-loud: a two-pass validate-then-copy rejects `~/.claude.json`,
`.credentials.json`, and any symlinked overlay destination before any
copy runs, aborting `drydock run` with a clear error. INV-2 carve-out
documented with a four-hazard analysis showing none apply (no RMW on a
shared single file; no SQLite DB; no OAuth token file in scope). See
`docs/troubleshooting.md` for the end-user workflow.

**Provenance.** Issue [#77][i77], PR #78.

### session-awareness-state-model

**Status: Done (v0.2.1, issue #79).**

**Problem.** The `SessionStart` awareness hook (added in v0.2.0 as
`self-awareness`) framed credential isolation, the Docker socket
root-equivalence, GPG signing, and the `gh` CLI cache workaround — but
never told the agent that container-side `~/.claude/` and
`~/.claude.json` are per-session copies re-seeded from a prototype on
every `drydock run`. Edits inside the container under those paths
silently did not persist, and the agent had no way to know it.

**What shipped.** A "Container state model" section added to the
`SessionStart` awareness hook output: tells the agent that
`~/.claude/`/`~/.claude.json` are ephemeral per-session copies, names
the `~/.claude/projects/` shared conversation store as the durable
carve-out, and lists the three paths for config that MUST survive a
restart — host `~/.claude/` + `drydock sync` (synced to the prototype,
seeded every run), the project repo's own `.mcp.json` (bind-mounted,
immune to re-seed), and the host overlay above
([container-config-overlay](#container-config-overlay)).

**Provenance.** Issue [#79][i79], PR #80.

### guardrail-deny-layer-port

**Status: Done (v0.2.1, issue #76).**

**Problem.** The destructive-command guardrails shipped in v0.2.0
([destructive-command-guardrails](#destructive-command-guardrails))
covered the immediate accident class — `rm -rf` to system paths, disk
destruction, fork bombs, firewall flush, package-manager purges,
`curl | sh` — but left two adjacent classes uncovered: production-infra
ops (`terraform apply`/`destroy`, kubectl/helm destructive verb against a
prod context, a DB CLI pointed at a production host) and a tail of
residual sudo/OS forms (`sudo chown -R`, `userdel`, account-lock
`usermod`, `systemctl` teardown, `sudo crontab -r`, `sudo kill -9 1`,
`sudo init 0`, `sudo chmod` world-writable). A confused agent could
issue any of these today with nothing stopping it.

**What shipped.** A new `templates/managed-settings.d/50-prod-ops.json`
drop-in (terraform apply/destroy globs), residual sudo/OS entries added
to `30-os-safety.json`, and four new PreToolUse residue rules in
`drydock-block-destructive.sh`:

- **A2** — kubectl/helm destructive verb scoped to a production-context
  flag value (`--context`/`--kube-context`/`--namespace`/`-n`),
  case-insensitive, attached short-flag accepted (`-nprod`), segment
  pipe-split so a verb in a downstream command (`kubectl get … | grep
  delete`) is not misread.
- **A3** — DB CLI (`psql`/`mysql`/`mongo`/`mongosh`/`redis-cli`) whose
  `-h`/`--host` value points at a production host.
- **A4** — `terraform apply`/`destroy`, subcommand-anchored so
  read-only subcommands (`terraform plan`, `terraform show apply`, …)
  pass.
- **C7-residue** — `sudo chmod` with a world-writable mode, anchored to
  the mode argument so a numeric/clause-shaped filename does not false
  block.

The Laravel artisan rule was evaluated and deliberately left out as
scope creep for the project-agnostic image. The `usermod` deny is
scoped to the account-lock forms (`-L`/`--lock`/`--expiredate`), NOT a
blanket `usermod*` glob that would false-block the routine
`usermod -aG docker $USER` group-add. Hardened via four rounds of dual
adversarial review.

**Provenance.** Issue [#76][i76], PR #81.

---

## v0.2.2 — CI hygiene & infrastructure polish

### ci-commit-lint

**Status: Done — shipping in v0.2.2 (issue #10).**

**Problem.** `CLAUDE.md` §5 records that conventional-commit format is a soft
norm, not CI-enforced. A non-conforming subject can ship undetected.

**Solution shipped.** A hand-rolled Bash script (`scripts/lint-commits.sh`) and
a CI job `Lint (commit-message)` that lints the conventional-commit subject format
(`type(scope): subject`, allowed types per §5). **Scope deliberately narrowed:**
the `Co-Authored-By` trailer ban is *not* CI-enforced — it remains a §5 soft norm.
CI-enforcing a custom trailer ban is unusual in OSS and not worth the machinery.
`commitlint` (Node) was rejected in favour of a hand-rolled Bash check to keep
the image minimal (§3) and avoid a Node install step in CI (NFR-1).

**Why this scope.** Pure CI infrastructure, no user-facing change — kept out of
the v0.2.0 feature story and shipped as a small hygiene patch.

**Invariants touched.** None.

**Provenance.** The §5 enforcement gap; issue [#10][i10].

### hooks-mount-source

**Status: Done — shipping in v0.2.2 (issue #71).**

**Problem.** drydock's `:ro` hooks overlay was bind-mounted directly from
the host's `~/.claude/hooks/` (INV-3) — the only mount where the container
read directly from host `~/.claude/`, a lone exception to INV-2's
container-state-only rule. The original rationale (always-current hooks,
no sync lag) did not hold: `ensure_synced` runs on every `drydock run` /
`shell`, the rsync does not exclude `hooks/`, and the staleness probe does
not prune it — the synced copy is always current in normal operation.

**Resolution.** The `:ro` overlay now sources from the per-session
`${DRYDOCK_SESSION_CLAUDE_DIR}/hooks/` subpath (the seeded copy from the
prototype) — NOT from host `~/.claude/hooks/`. The `:ro` flag and the
"agent cannot write its own hooks" guarantee are unchanged. INV-2 becomes
unconditional ("the container never reads host `~/.claude/` directly")
with no carve-out for hooks. Bounded blast radius under threat model A:
a fat-fingered host hook edit no longer propagates live to running
sessions — only future sessions pick it up via the next sync + seed.
`cmd_setup` now `mkdir -p`s the prototype's `hooks/` so the bind-mount
source always exists even on a fresh host with no `~/.claude/hooks/`.

**Why this scope.** Infrastructure polish — no new user-visible behaviour;
the change is "where the hook scripts come from."

**Invariants touched.** INV-2 — the carve-out for the hooks overlay is
removed; the rule is now unconditional. INV-3 — the RO mount property
and the agent-cannot-write-its-own-hooks guarantee are preserved.

**Provenance.** Issue [#71][i71].

### integration-in-ci

**Status: Done (v0.2.2, issue #74).**

**Problem.** Integration tests (`test/integration/` and the
`DRYDOCK_INTEGRATION`-gated tests in `test/managed_settings.bats`) shipped
with the repo but did not run in CI. The unit suite caught most regressions,
but the INV-3 managed-settings bake step (deny rules baked root-owned into
`drydock:latest`) and the per-file `__HOME__` substitution were verified
only when a contributor ran the integration suite locally with the right
flag — and one corner of that suite (T5 in `test/managed_settings.bats`)
was a permanent `skip` regardless of any flag.

**What shipped.** Two-flag namespace under a shared `DRYDOCK_INTEGRATION_*`
prefix, structurally separating CI-safe from local-only tiers:

- `DRYDOCK_INTEGRATION=1` — DooD-safe bats integration tests (T5 + the T19 family
  in `test/managed_settings.bats`). The smoke job sets this flag after
  `drydock build`, so every PR that touches the image, the compose stack,
  the CLI, the baked managed-settings drop-ins, or the per-session-sealed
  hook scripts under `templates/hooks/` gets the managed-settings bake
  verified end-to-end by smoke (seed behavior verified by the unit suite in CI).
- `DRYDOCK_INTEGRATION_HOSTNET=1` — local-only host-network tier (SR-9, the
  shared `projects/` sub-mount resolution test). Renamed from
  `RUN_INTEGRATION` for the unified namespace. Stays out of CI because
  `network_mode: host` is unreliable under GHA DinD.

The smoke job's path filter was extended to include
`templates/managed-settings.d/**` and `templates/hooks/**` so a PR touching
only the baked drop-ins still triggers the bake-verification job. T5 was
converted from an unconditional `skip` to the same `DRYDOCK_INTEGRATION=1`
guard the T19 tests use. CONTRIBUTING.md documents both flags and the
local invocation commands.

**Provenance.** Issue [#74][i74]. Resolves the flag-unification open
question and the in-CI-running question listed in the prior Planned entry.

---

## v0.3.0 — Session persistence & multi-session UX

### session-persistence

**Status: Done (v0.3.0, issue [#64][i64]).** Shipped across PRs #94 (Slice 1
foundation), #96 (Slice 1 cleanup, PR 1/2), and #98 (impl + polish, PR 2/2).

**Problem.** A `drydock run` session did not reliably survive the host
terminal closing. `cmd_run` launched Claude via `docker compose run --rm`
attached to the terminal; on terminal close the outcome was nondeterministic —
a clean `SIGHUP` was forwarded to `claude` (session died, `--rm` removed the
container), an abrupt teardown was not (the container survived orphaned in the
Docker VM). Survival was luck, not design.

**Solution shipped — Model X "Detect + Delegate".** Persistence is now
deterministic via Docker's native lifecycle, not an in-container multiplexer:

- **Container PID 1 = `sleep infinity`** (CMD-not-entrypoint). The container
  is a long-lived no-op; closing the terminal cannot kill it. `docker compose
  run drydock claude` still overrides the CMD for ephemeral nested mode.
- **Launcher = `docker compose up -d` + `docker compose exec -it ... claude`**.
  Sessions are persistent by default. All overlays (hardening, SSH, GPG,
  hooks RO, session dirs, engram) apply identically under `up -d`.
- **Host multiplexer detection** via env vars (`$ZELLIJ` / `$TMUX` / `$STY` /
  `$DRYDOCK_NESTED=1`) — nested invocations fall back to ephemeral `compose
  run --rm -it claude` so host multiplexers keep owning lifecycle.
- **New CLI surface**: `drydock new` (force-fresh session), `drydock attach
  [NAME]` (reconnect via `claude --resume`), `drydock list` (live sessions
  per project), `drydock stop [NAME]` (force-remove the container).
- **Interactive TUI selector** when `drydock` is re-invoked for a project with
  live sessions — 3-tier fallback: `gum` (preferred) → `fzf` (fallback) →
  built-in Bash ANSI renderer (safety net, zero deps). Override env:
  `DRYDOCK_DISABLE_GUM=1` / `DRYDOCK_DISABLE_FZF=1`.
- **Reattach mechanics**: `compose exec -it ... claude --resume` reads the
  per-uuid append-only `~/.claude-container/projects/<slug>/<uuid>.jsonl`
  (existing INV-2 carve-out — no schema change, no new shared writers).

Earlier Zellij-based design (engram `redesign-*`) was prototyped in Slice 1
and abandoned post-empirical-gate failures (TTY contamination via `script
-qec` + alternate-screen interactions, engram #2707). The Model X design is
strictly simpler: no inner Zellij, no wrapper PID 1, no stealth layouts —
just the standard Docker lifecycle.

**Why this scope.** Ergonomics — the in-container equivalent of `tmux` on the
host, delivered by Docker's own primitives instead of a bespoke layer.
Squarely threat model A (INV-7): a closed terminal losing an in-progress
agent task is the footgun class drydock exists to catch.

**Invariants touched.** All preserved. INV-2 — per-session
`~/.claude-container-<disc>/` config isolation is unchanged; the `projects/`
carve-out handles `--resume` via append-only-per-uuid (no RMW, no SQLite).
INV-3 — both `:ro` hook overlay mounts apply identically under `compose up
-d`. INV-7 — ergonomics only, no adversarial protection, no invariant
amendment. INV-1, INV-4, INV-5, INV-6, INV-8 — no impact.

**Pairs with.** [session-management-ui](#session-management-ui) below was
*re-scoped* to a separate plugin and externalized — see that section.

**Provenance.** Issue [#64][i64]. Surfaced from a container permissions audit
that also fixed root-owned `~/.cache` / `~/.config` and added the doctor
resume cheat-sheet (since updated from `claude --continue` to `drydock attach
<disc>` per the new lifecycle). Full SDD trail in engram under
`sdd/session-persistence/redesign3-*` topic keys; archive report at
`sdd/session-persistence/redesign3-archive-report`.

### session-management-ui

**Status: Not planned (closed as not-planned, issue [#67][i67]).** The
original v0.3.0 scope — an in-container multi-session UI built on top of the
[session-persistence](#session-persistence) substrate — was made obsolete by
the redesign3 pivot. Once persistence stopped depending on an in-container
multiplexer (Zellij), there was no substrate left to "build a sidebar on,"
and the in-CLI surface (`drydock list` + the interactive TUI selector on
`drydock`) already covers the navigation use cases the issue originally
called out. The plugin idea — a Zellij sidebar that drives drydock — is now
tracked as the external repository [drydock-zellij-plugin][i97], post-v0.3.0.

**What ships in v0.3.0 instead.** The CLI selector that opens when `drydock`
is re-invoked for a project with live sessions (attach / new / stop+new /
cancel) — see [session-persistence](#session-persistence) for the 3-tier
rendering chain (gum → fzf → built-in ANSI). For listing without launching,
`drydock list` shows the live session table. This covers the in-terminal
navigation use case that motivated #67 without an in-container UI layer.

**Provenance.** Issue [#67][i67] (closed not-planned). Successor: external
plugin issue [#97][i97], scoped post-v0.3.0. Surfaced from the same audit
that drove `session-persistence`.

---

## v0.4.0 — Per-project environment customization

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

## v0.5.0 — drydock as agent-agnostic infrastructure

### agent-adapter

**Problem.** drydock is currently a Claude Code-specific workspace. Other coding
agents (Codex, OpenCode, pi.dev) cannot use it without per-agent assumptions
baked into the CLI.

**Proposed solution.** An adapter layer abstracting the agent-specific pieces —
config paths, container state layout, MCP wiring — so drydock can host more than
one agent.

**Why this scope.** A release of its own — abstracting the agent boundary is a
large, distinct effort, separate from the per-project-environment theme of v0.4.0.
Sequenced before [sandcastle-sandbox-provider](#sandcastle-sandbox-provider)
(v0.6.0) so drydock is already agent-agnostic at the per-session level before
the orchestration layer plugs in.

**Invariants touched.** INV-2 (each agent needs its own container-state split);
INV-4 (the engram-optional principle generalizes — no agent should be
hard-required).

**Open questions.** This item has **no design memo yet** and needs a proper
exploration before it is actionable — currently the least-defined item on the
roadmap.

**Provenance.** Referenced as future-release work in engram #1010 and #1053; no
dedicated memo.

---

## v0.6.0 — Programmatic agent orchestration

### sandcastle-sandbox-provider

**Status: Planned (v0.6.0, issue #66).**

**Problem.** drydock is a CLI today — a human types `drydock run` to start
an agent session. Programmatic orchestration (another agent or a dashboard
spawning N drydock sessions, observing them, killing them) is not a
first-class surface. Sandcastle, the agent-orchestration framework this
project's maintainer also works on, has a `SandboxProvider` abstraction
that drydock could implement, exposing drydock as one of the sandbox
backends sandcastle can target.

**Proposed solution.** A `SandboxProvider` adapter — a thin layer that
exposes the drydock session lifecycle (start, attach, exec, stop) as the
sandcastle interface expects. Implementation lives in this repo so drydock
remains the source of truth for its own session semantics.

**Why this scope.** A release of its own — drydock-as-library is a
distinct surface from drydock-as-CLI, and the sandcastle interface
contract is the authoritative shape. Sequenced after
[agent-adapter](#agent-adapter) (v0.5.0) so drydock is already
agent-agnostic at the per-session level before the orchestration layer
plugs in.

**Invariants touched.** INV-2 (each spawned session still needs its own
container-state split); INV-7 (sandcastle's orchestration loop is part of
the trusted control plane, not an adversary surface).

**Open questions.** Interface stability of `SandboxProvider`; whether the
adapter lives in this repo or in a sandcastle plugin; observability (how
does sandcastle inspect a running drydock session — logs, exit status,
the doctor JSON?).

**Provenance.** Issue [#66][i66].
