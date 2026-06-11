# Changelog

All notable changes to drydock are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **BREAKING — network/socket mode is now contained by default** (#149). drydock
  no longer mounts the host Docker socket or shares the host network by default.
  A fresh install runs in **contained mode** (no Docker socket, no host network),
  shrinking the host blast radius for external-ingestion work. The previous
  always-on behavior is now **dood mode**, opt-in per project. In contained mode,
  egress is jailed behind a deny-by-default domain allowlist (see *Added* below);
  dood mode is unchanged.
  - **What stops working in contained mode**: `docker` / `docker compose` /
    `docker exec` against the host stack, `curl http://localhost:PORT/...`, and
    `make shell-api` — anything that needs the host Docker daemon or host network.
  - **Restore the previous behavior**: `drydock dood <proj>` (one project) or
    `drydock default dood` (global). Per invocation: `DRYDOCK_DOOD=1 drydock`.

### Added

- **Contained-mode egress jail** (#149). Contained mode now enforces a
  deny-by-default domain allowlist via a per-session proxy sidecar (tinyproxy): the
  agent attaches solely to an `internal: true` bridge and reaches the network only
  through the sidecar, which permits CONNECT to allowlisted hostnames on port 443.
  Zero new Linux capabilities (the sidecar runs `cap_drop: ALL`; INV-8 intact); dood
  mode is unchanged. Extend the shipped baseline (add-only) via
  `~/.config/drydock/egress-allowlist` (global) or `egress-allowlist-<project>`
  (per-project); a request to a non-allowlisted host returns 403. `drydock doctor`
  gains an EGRESS section that reports the active allowlist sources.
- **`drydock default <dood|contain>` / `drydock dood <proj> [--remove]` /
  `drydock contain <proj> [--remove]`** (#149). Manage the network/socket mode: a
  global default sentinel plus mutually-exclusive per-project pins. Resolution is
  most-specific-wins (env > per-project pin > global default > factory contained)
  and fails closed to contained.
- **Creation-time mode banner** (#149). `drydock run`/`new`/`shell` print the
  active mode + the reason it was chosen before the container starts (never on
  attach).
- **`drydock doctor` reports the active network/socket mode** (#149) in its
  COMPOSE OVERLAYS section.

### Fixed

- **Session-dir GC no longer reaps live sessions when the Docker daemon is
  unreachable.** A failed `docker ps -a` produced empty output that was
  indistinguishable from "no containers", so every session dir — including the
  bind-mounted `~/.claude` of RUNNING sessions — looked orphaned and was
  rm -rf'd. GC now checks the command's exit status and skips the pass with a
  warning when the daemon does not answer.
- **Session-dir GC survives an unremovable entry.** One entry that could not be
  removed (e.g. a root-owned file inside a session dir) aborted GC under
  `set -e` and with it every `drydock run` for every project. The reap loop now
  warns and continues, honoring GC's returns-0-always contract.
- **Image bake is immune to the builder's umask.** `COPY` preserves
  build-context file modes, so building with `umask 077` baked the
  managed-settings policy JSONs (and the sidecar's `tinyproxy.conf`) as 600
  root-owned files the non-root runtime user could not read — silently
  disabling the entire managed-settings guardrail layer (INV-3). Both `COPY`
  lines now pin `--chmod=644`, with directory traversal pinned explicitly.
- **A failure while assembling the compose `-f` list aborts the launch instead
  of silently dropping overlays.** The list was consumed through process
  substitution, which discards the producer's exit status: a generator dying
  mid-stream (full disk, unwritable `TMPDIR`) could launch a session with a
  truncated overlay list — in the worst case missing the hardening AND mode
  overlays, i.e. a "contained" session with open egress. Mandatory overlays
  (base, mode, hardening) are now emitted before any fallible generator, and
  all consumers check the producer's exit status and fail loud.
- **An invalid host `~/.claude.json` no longer truncates the container config
  or fakes a successful sync.** The jq filter wrote directly into the target,
  truncating it before parsing the source; a host config caught mid-rewrite
  left a 0-byte container config, and the auto-sync path still stamped the
  freshness marker and printed "Sync done". The refresh is now atomic
  (same-directory temp file + rename) with an explicit jq exit-status check;
  on failure the existing container config is left intact, a warning is
  printed, and no marker or success message is produced.
- **Fresh hosts no longer get a root-owned `~/.gitconfig` directory or
  `~/.local` created by the Docker daemon.** Both are unconditional bind-mount
  sources in the base compose file; when absent, the daemon auto-creates them
  as root-owned directories — `~/.gitconfig`-as-a-directory breaks host git
  until a manual `sudo rm`. `ensure_runtime_dirs` now pre-creates them
  user-owned (file touch / `mkdir -p`), alongside the same guard for the
  shared conversation-store dir on the upgrade path.

## [0.3.3] - 2026-06-03

Session-lifecycle completion plus release-hardening. Finishes the #131
persistent-session model (clean-exit teardown, disconnect-persist, exact-UUID
resume), clears the #135 / #139 / #140 fixes that accumulated on `dev`, and adds
three pre-release guardrail/concurrency hardening fixes surfaced by a Judgment
Day pass before tagging.

### Added
- **Session lifecycle + exact-session attach** (#131). A `drydock` session now
  tears down on clean exit (`/exit`) and persists on disconnect (terminal close
  / SIGHUP), and `drydock attach` resumes the *exact* prior session by its
  recorded UUID (`claude --resume <uuid>`, or `--session-id` for a zero-turn
  session) with an unconditional orphan reap of any stale `claude` left by a
  disconnected session.

### Fixed
- **Destructive-command guardrail — mask-first conditional quote-strip** (#135).
  A quoted DATA argument that merely contained a destructive pattern (e.g.
  `git commit -m "rm -rf /"`) was incorrectly blocked. The hook now masks quoted
  strings and exposes their content to a rule only when the segment actually
  invokes a command that rule inspects (closed introducer set), eliminating the
  data-quote false positives. (ADR-9.)
- **`drydock attach` resumes zero-turn sessions and preserves nested multiplexer
  sessions** (#139). A session with no recorded transcript used `--resume` and
  hit "session not found"; it now uses `--session-id`. A session launched inside
  a nested multiplexer is no longer mishandled on re-attach.
- **`.env` managed block is newline-terminated before its close marker** (#140,
  PR #142). When the preceding user content lacked a trailing newline, the
  drydock-managed sub-mount block was glued onto the last user line.
- **Destructive-command guardrail fails closed when its hook script is absent**
  (INV-3). The image-baked PreToolUse wrapper exited `0` (allow) when
  `/opt/drydock/hooks/drydock-block-destructive.sh` was missing. Combined with a
  concurrent-launch race that could reap a launching session's hook-overlay dir,
  a normal concurrent launch could silently disable the tier-1 destructive
  guardrail for the rest of the session. The wrapper now exits `2` (block) on a
  missing script — a missing guardrail is a visible broken session, not a silent
  disable.
- **Concurrent-launch race hardening** (INV-2 / INV-3). `export_compose_env`
  seeds `~/.claude-container-<disc>/` and returns before the container enters
  `docker ps -a`; in that window a concurrent `gc_orphan_session_dirs` could
  reap the launching dir (deleting the INV-3 hook-overlay sources) or the
  collision loop could re-mint the same discriminator (INV-2 `.claude.json`
  clobber). A `.launching` in-flight marker, a grace window in the GC liveness
  check (`DRYDOCK_SESSION_GC_GRACE`, default 300 s), and a session-dir-existence
  check in the collision loop close the common window; a needless
  `export_compose_env` + dead `compose_args` are dropped from `cmd_run`'s attach
  branch. The grace is heuristic; the fail-closed guardrail above covers the
  cold-start residual.
- **C12/C20 data-quote over-block** (INV-3). The fork-bomb (C12) and
  `curl`/`wget`-piped-to-a-shell (C20) rules scanned the raw command, so a benign
  commit message or search pattern that merely contained the shape (e.g.
  `git commit -m "use curl x | bash"`, or an agent's own `rg "curl|bash"`) was
  over-blocked. They now scan a data-stripped masked form; a new
  command-substitution arm flattens double-quoted `"$(…)"` / backtick so a real
  `echo "$(curl … | bash)"` still blocks (no bypass). A residual over-block for
  quoted data that itself contains a `;` (incl. the canonical fork bomb) is a
  documented non-goal under threat model A, tracked in #143. (ADR-9.)

### Documentation
- README session-lifecycle section aligned with #131 (exit-vs-detach semantics).
- `docs/security.md` ADR-9 extended with the C12/C20 masked-form routing, the
  command-substitution arm, and the `;`-in-quote over-block non-goal (#143).

### Tests
- `test/links.bats` declares a bats 1.5.0 minimum for its `run !` assertions.

## [0.3.2] - 2026-05-28

Link and skills polish. Sharpens cross-project linking for the host-path-mirror
case, hardens project-skill symlink handling, and corrects the SessionStart
awareness hook. Production changes touch `lib/commands.sh` and
`templates/hooks/drydock-session-start.sh`.

### Added
- **`drydock link --mirror <path>`** (#126). Syntactic sugar for the
  host-path-mirror mount (the `drydock link <path> <path>` double-path form),
  which mounts a sibling at its original host path so absolute symlinks under
  the project — e.g. `.claude/skills/*` pointing to an external host path —
  resolve inside the container. The double-path form was the only way to get a
  mirror mount before, and its discoverability was poor.
- **Pre-flight warning for broken project skill symlinks** (#127). Before
  launch, drydock detects symlinks under the project's `.claude/skills/` that
  point to host paths the container will not have and prints the exact
  `drydock link --mirror` command to fix each one. Non-blocking.

### Fixed
- **The SessionStart awareness hook now reports the live GPG signing state.**
  The hook stated signing was "disabled by default" unconditionally, which was
  wrong whenever the GPG overlay was active and signing commits with a sandbox
  key. The GPG section is now conditional on the live overlay environment
  (`GNUPGHOME` set and `commit.gpgsign=true`), so the agent is told signing is
  ENABLED when it actually is.
- **External symlinks are dereferenced during the host→container config seed**
  (#120). A symlink under `~/.claude/` pointing outside the seeded tree was
  copied as a dangling link inside the container; it is now dereferenced so the
  target content is seeded.
- **`drydock unlink` usage string includes `--rw`** (#129). The usage line
  omitted the `--rw` flag that the matching `link` command accepts.

### Documentation
- Host-path-mirror example added to the `drydock link` help output (#124).
- User-facing docs cover the link/skills polish (#128) and personal path
  placeholders are replaced in the public examples (#130).

## [0.3.1] - 2026-05-27

Session-persistence polish. Seven small fixes and test improvements layered on
top of v0.3.0; production changes are bounded to `lib/commands.sh` and
`lib/compose.sh`, the rest is test surface. No behavior change beyond the
seven listed items.

### Fixed
- **Session-discovery regex now matches exactly 4 hex chars** (#103). The
  session-name filters used `[0-9a-f]+` (one or more hex), which would
  admit any hex length even though `_gen_discriminator` always emits
  exactly 4. A manually created or stale `drydock-<proj>-<8char>`
  container would silently land in the session list and be subject to
  `list` / `stop` / `attach` actions. Tightened to `[0-9a-f]{4}` across
  the five production sites — `pre_flight_notice` (the shell pre-flight),
  `cmd_run`'s non-nested live-sessions probe, `_live_sessions`,
  `_all_sessions`, and the `doctor` ACTIVE SESSIONS section. Swept the
  test fixtures (`test/cmd_list.bats`,
  `test/cmd_stop.bats`, `test/cmd_attach.bats`, `test/cmd_new.bats`,
  `test/select_choice.bats`, `test/lib_commands.bats`) to use unambiguous
  4-char discriminators.
- **`drydock stop` error message no longer says "no live session" for an
  Exited container** (#102). The matcher already validated against both
  running and exited sessions (so a user could stop an Exited container by
  disc), but the not-found error still said "no live session" — misleading
  for someone trying to remove a stopped session by name. Reworded to
  "no session (running or exited) named …" so the message reflects what
  the matcher actually checks.
- **`drydock` with 0 sessions in a non-TTY shell no longer prints a
  `Launching Claude in …` progress line before the TTY guard rejects the
  invocation** (#104). `cmd_run`'s 0-session branch emitted `note()`
  before delegating to `_launch_new`, which then fired its own TTY guard
  and exited 2 — leaving the scripted caller with a misleading progress
  message ahead of the actual error. Added a caller-side TTY guard in
  `cmd_run` ahead of the `note()`, mirroring `_launch_new`'s existing
  guard as defense in depth.
- **`drydock run` no longer leaves a root-owned `~/.config/gh` on hosts
  without `gh` installed** (#109). `docker-compose.yml` bind-mounts
  `~/.config/gh` unconditionally; if the source directory doesn't exist,
  the Docker daemon (running as root) auto-creates it `root:root`-owned.
  `drydock run` itself worked fine, but a subsequent host-side
  `gh auth login` would then fail with permission denied trying to write
  into the user's own XDG config dir. `ensure_runtime_dirs` now
  pre-creates the directory under the invoking user before any compose
  call — same defensive class as the existing `~/.claude/hooks` mkdir.

### Tests
- **`test/integration/session_lifecycle_compose_exec.bats` L-C now compares
  container identity, not `/proc/1/stat`** (#105). The old assertion compared
  the first field of `/proc/1/stat` — always `1` in any container's PID
  namespace, so two execs landing in DIFFERENT containers would still have
  passed. Now captures `/etc/hostname` (Docker default = container short ID)
  from inside each exec and cross-checks against `compose ps -q drydock`, so
  the failure mode L-C exists to detect is actually falsified.
- **`test/cli_surface.bats` no longer risks killing a live container during
  test runs** (#112). The CLI-surface smoke tests invoked the real
  `bin/drydock` via subprocess for unrelated path coverage; if a developer
  happened to have a live `drydock-<proj>-<disc>` container while the suite
  ran, certain code paths would call `docker rm -f` against it. Added a
  `DOCKER` env-var seam so the tests redirect docker invocations to a stub
  by default, and the live-container kill path is structurally unreachable
  from the test process.
- **`test/cmd_attach.bats` covers the no-arg + 1 session + no-TTY case**
  (#106). With the v0.3.0 `cmd_attach` TTY guard in place, every other
  sub-scenario was asserted (explicit name + no-TTY, no-arg + N>1 + no-TTY,
  with-TTY paths) except this one. Added a test that asserts status 2 AND
  that the TTY guard fires before `docker compose exec` is invoked.

## [0.3.0] - 2026-05-25

Session persistence and multi-session UX. The container moves from
ephemeral-per-session to long-lived via Docker's native lifecycle, and the
CLI gains explicit session management commands. See #64.

### Added
- **New session subcommands** (`drydock new`, `drydock attach`, `drydock list`,
  `drydock stop`) for the persistent-container lifecycle model (#64).
  `drydock new` starts a fresh container without prompting (coexists with any
  live session). `drydock attach [disc]` reconnects via `compose exec … claude
  --resume`. `drydock list` shows live sessions for the current project in
  parseable format. `drydock stop [disc]` removes a container.
  All four support the disambiguation protocol: explicit name → direct action;
  no arg + 1 session → direct; no arg + N>1 + TTY → interactive selector;
  no arg + N>1 + no-TTY → list + exit 2.
- **`drydock` default command now detects live sessions** (REQ-9-M): nested
  (inside Zellij/tmux/screen or `DRYDOCK_NESTED=1`) → ephemeral `compose run
  --rm`; non-nested + no sessions → `compose up -d` + `compose exec`; non-nested
  + live sessions + TTY → interactive selector (attach / new / stop+new /
  cancel); non-nested + live sessions + no-TTY → list + exit 2.
- **Interactive TUI selector** for choosing between live sessions and actions.
  3-tier fallback chain: [`gum`](https://github.com/charmbracelet/gum) (preferred,
  premium UX) → [`fzf`](https://github.com/junegunn/fzf) (fallback, incremental
  search) → built-in Bash ANSI renderer (safety net, zero deps). Override env:
  `DRYDOCK_DISABLE_GUM=1` / `DRYDOCK_DISABLE_FZF=1`. Test seam via `GUM=` /
  `FZF=` env indirection. `drydock doctor` reports which tier is active and
  install hints for the others.
- Integration gate `test/integration/session_lifecycle_compose_exec.bats`
  (assertions L-A..L-D) gated by `DRYDOCK_INTEGRATION=1` — verifies PID 1 =
  `sleep`, SIGHUP survival of exec processes, re-exec to same container, and
  container removal cleanup.

### Changed
- **`drydock doctor` ACTIVE SESSIONS cheat-sheet** now shows `drydock attach
  <disc>` and `drydock list` instead of the old `docker exec -it … claude
  --continue` and INV-2 caveat (REQ-8-M, REQ-N11). The new `compose exec`
  model spawns a new `claude` process per attach. In normal use (terminal
  close → reattach), the previous `claude` has already exited, so a single
  writer exists at a time. Double-attach across two terminals can still
  produce concurrent writers on the same per-session config; users are
  responsible for one-attach-at-a-time discipline.
- **Container PID 1 changed** from `drydock-wrapper.sh` to `sleep infinity`
  (T-2, REQ-1-M). CMD (not ENTRYPOINT) so `compose run drydock claude` still
  overrides it for the ephemeral nested path.
- **README + ROADMAP + troubleshooting** aligned with the new lifecycle:
  README documents the four new subcommands and persistent-session model;
  ROADMAP flips #64 to `Done` and #67 to `Not planned` (closed; successor:
  external [drydock-zellij-plugin](https://github.com/sideralith/drydock/issues/97),
  post-v0.3.0); troubleshooting's TTY-latency section reflects the
  `compose up -d` + `exec` chain.

### Removed
- **Zellij scaffolding (Slice 1 debt) removed** (#64). The nested-Zellij stealth
  approach (Mode F) proved structurally impossible — the host Zellij intercepts
  all keystrokes before they reach an inner Zellij, leaving the container
  inaccessible regardless of mode config. The redesign replaces PID 1 with
  `sleep infinity` and delegates multiplexer behavior to the user's host
  environment. Removed: `templates/hooks/drydock-wrapper.sh`,
  `templates/hooks/drydock-claude-shim.sh`,
  `templates/zellij/config-nested.kdl`, `templates/zellij/layouts/drydock.kdl`,
  `test/integration/sighup_survival.bats`,
  `test/integration/nested_zellij_stealth.bats`. Zellij binary (~10-12 MB)
  removed from image. Smoke CI steps for Zellij binary presence and stealth
  config removed.

### Notes
- Issue #67 (session-management-ui) was closed as not-planned in this cycle —
  the substrate pivot away from in-container Zellij removed the dependency the
  issue assumed, and the CLI selector now covers the in-terminal navigation
  use cases that motivated it. The plugin idea is tracked externally at #97,
  post-v0.3.0.

## [0.2.2] - 2026-05-23

CI hygiene & infrastructure polish, plus a host-contamination fix for the
RW-sibling SSH flow.

### Added
- `scripts/lint-commits.sh` + CI job `Lint (commit-message)` enforce
  Conventional Commits on PR commits targeting `dev` (#10).
- Managed-settings integration tests now run in the smoke CI job; the
  `--integration` and `--smoke` bats flags are unified into a single
  selector (#74, #87).
- T19 ("INV-3 bake contract") in `test/managed_settings.bats` now covers the
  full drop-in set (all five `templates/managed-settings.d/*.json` files),
  asserts root ownership of baked drop-ins, and verifies the hook-stance
  contract end-to-end (#88, #90).

### Fixed
- **`drydock link --rw` no longer contaminates the host's git configuration**
  (#89). Pre-fix, link mutated the sibling's `remote.origin.url` from
  `git@github.com:owner/repo.git` to the container-only alias
  `git@github.com-<sibling>:owner/repo.git` so OpenSSH could route per-sibling
  deploy keys. That alias only resolved inside the container, so `git fetch`
  on the host failed immediately after linking and stayed broken until
  `drydock unlink`. The fix moves URL routing to `url.insteadOf` in a
  drydock-managed per-project gitconfig at
  `~/.config/drydock/gitconfig-<primary>` that the container reads via
  `GIT_CONFIG_GLOBAL`. Sibling `.git/config` is never touched — host `git
  fetch` keeps working with the canonical URL while the container resolves
  the alias in memory. Migration: the first `drydock run` after upgrading
  auto-restores any aliased URL left by v0.2.1 to canonical (idempotent,
  per-sibling, non-fatal on failure). INV-1 extended to capture the host
  gitconfig non-contamination rule.

### Changed
- **Hooks RO overlay sources from the per-session container-state dir** —
  `docker-compose.yml`'s `:ro` hooks mount now sources from
  `${DRYDOCK_SESSION_CLAUDE_DIR}/hooks` (the per-session seeded dir) instead
  of host `~/.claude/hooks/`. This eliminates the lone container-reads-host
  exception in INV-2: the rule is now unconditional ("the container never
  reads host `~/.claude/` directly") with no carve-out. The `:ro` flag and
  INV-3's "agent cannot write its own hooks" guarantee are unchanged.
  Behavior change under threat model A (INV-7): a fat-fingered host hook
  edit no longer propagates live to running sessions; only future sessions
  pick it up via the next sync + seed (bounded blast radius). The original
  argument for host-direct sourcing (always-current hooks) did not hold —
  `ensure_synced` runs on every `drydock run` / `shell`, the rsync does not
  exclude `hooks/`, and `~/.claude-container/hooks/` is always current
  before a session starts in normal operation. `cmd_setup` now `mkdir -p`s
  the prototype's `hooks/` so the bind-mount source always exists even on
  a fresh host with no personal `~/.claude/hooks/`. Closes #71.
- **Homebrew formula template uses a `__VERSION__` placeholder** instead of a
  hard-coded `v0.2.0` `url` line. `scripts/publish-homebrew-tap.sh` now
  substitutes `__VERSION__` alongside `__SHA256_PLACEHOLDER__` at publish
  time. The url-line regex substitution is retained as a safety net. This
  closes the silent-drift class where the template's static `v0.2.0` looked
  authoritative but was overridden at publish — every release left the
  template referencing a stale version. The dry-run output and the published
  formula are byte-for-byte identical to the prior behavior.

## [0.2.1] - 2026-05-22

OAuth token persistence, container-config overlay, expanded destructive-command
guardrails, conversation-history root fix, container-state-model awareness, and
post-v0.2.0 polish & hardening across `doctor` / `install.sh` / Dockerfile.

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
- **Container-config overlay** (#77) — a host-authored
  `~/.config/drydock/claude-overlay/` directory mirroring the `~/.claude/`
  tree is copied recursively (whole-file) on top of the freshly re-seeded
  per-session `~/.claude-container-<disc>/` dir. Config edits that previously
  vanished on the next `drydock run` (e.g. a plugin's `.mcp.json` flag) now
  survive — the overlay is host-authored, container-consumed, unidirectional.
  INV-2 carve-out with strict scope enforcement: a two-pass
  validate-then-copy rejects `~/.claude.json`, `.credentials.json`, and any
  symlinked overlay destination fail-loud before any copy runs.
- **SessionStart hook — container state model awareness** (#79). The
  awareness hook now tells the agent that container-side `~/.claude/` and
  `~/.claude.json` are per-session copies re-seeded from a prototype on every
  `drydock run` — edits inside the container do not persist. The hook also
  surfaces the three paths for config that must survive a restart (host
  `~/.claude/` + `drydock sync`, the project's `.mcp.json`, or the host
  overlay above).

### Fixed
- **Conversation history destroyed on the next `drydock run` (data loss)** —
  `gc_orphan_session_dirs` (`lib/compose.sh`) prunes per-session
  `~/.claude-container-<disc>/` dirs whose container is no longer in
  `docker ps -a`. Because `drydock run` uses `docker compose run --rm`, an
  `/exit`'d container leaves `docker ps -a` immediately — so the next
  `drydock run` saw the exited session's dir as orphaned and `rm -rf`'d it,
  destroying `projects/<slug>/<uuid>.jsonl` (the durable conversation
  history) and breaking `claude --resume` across sessions since v0.2.0.
  **Hotfix** harvests each orphan dir's `projects/` tree into the prototype
  `~/.claude-container/projects/` before pruning, copying each append-only
  `.jsonl` only when the prototype has no copy or the harvested one is
  larger — so a stale shorter copy can never clobber a more complete one.
  **Root fix** (#68) moves `projects/` to a shared `:rw` sub-mount —
  conversation history now lives outside the per-session dirs entirely, so
  GC cannot reach it. The hotfix harvest stays in as a belt-and-suspenders
  backstop. INV-2 amended with the append-only `projects/` carve-out
  (one append-only `.jsonl` per UUID — none of INV-2's four hazards apply).
- **SR-9 integration test pollutes the host home** (#73) — the sub-mount
  resolution integration test (`test/integration/test_projects_submount.sh`)
  used to create root-owned dirs under the real host `$HOME` when run inside
  a drydock container (DooD). Rewritten as hermetic: the test now runs under
  a per-test temp HOME and tears it down on exit.
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
- **Destructive-command guardrails — prod-ops & residual OS coverage** (#76).
  The tier-1 deny layer + the PreToolUse hook now also cover production-infra
  ops and the residual sudo/OS forms previously uncovered. New drop-in
  `templates/managed-settings.d/50-prod-ops.json` (terraform apply/destroy).
  `30-os-safety.json` extended with recursive `chown`, `userdel`,
  account-lock `usermod` (`-L`/`--lock`/`--expiredate`), `systemctl`
  teardown (`stop`/`disable`/`mask`/`reset-failed`), `sudo crontab -r`,
  `sudo kill -9 1`, `sudo init 0`. Four new PreToolUse residue rules in
  `drydock-block-destructive.sh`: **A2** (kubectl/helm destructive verb
  scoped to a production-context flag value — `--context`/`--kube-context`/
  `--namespace`/`-n`, case-insensitive, attached short-flag accepted,
  segment pipe-split so a verb in a downstream command is not misread);
  **A3** (a database CLI — `psql`/`mysql`/`mongo`/`mongosh`/`redis-cli` —
  whose `-h`/`--host` value points at a production host); **A4**
  (`terraform apply`/`destroy`, subcommand-anchored so read-only subcommands
  pass); **C7-residue** (`sudo chmod` with a world-writable mode, anchored
  to the mode argument so a numeric/clause-shaped filename does not false
  block). The Laravel artisan rule was evaluated and deliberately left out
  as scope creep for a project-agnostic image. Hardened via four rounds of
  dual adversarial review (Judgment Day).
- **Hook block messages — drop internal INV-N tokens** (`drydock-block-destructive.sh`).
  Rule codes (A1, C1-residue, C17, …) remain in the user-visible messages
  as cross-references; INV-N invariant tokens, which are design-doc-only
  identifiers with no user value, were removed.
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
- **`CONTRIBUTING.md` — dev/main two-branch model** (#72). The convention is
  now documented: feature PRs target `dev`, releases merge `dev` → `main`,
  and issues are closed manually on `dev` merge because GitHub does not
  auto-close issues from non-default-branch merges (the `close-on-dev`
  convention).
- **INV-2 carve-outs documented in `CLAUDE.md`.** The append-only `projects/`
  shared sub-mount and the host-authored `~/.config/drydock/claude-overlay/`
  overlay each get a "Carve-out" subsection with the hazard-class justification
  showing none of INV-2's four failure modes apply. Also documents the
  container-config overlay deep-dive in `docs/troubleshooting.md` and the
  agent-lifecycle docs.
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

[0.3.3]: https://github.com/sideralith/drydock/releases/tag/v0.3.3
[0.3.0]: https://github.com/sideralith/drydock/releases/tag/v0.3.0
[0.2.2]: https://github.com/sideralith/drydock/releases/tag/v0.2.2
[0.2.1]: https://github.com/sideralith/drydock/releases/tag/v0.2.1
[0.2.0]: https://github.com/sideralith/drydock/releases/tag/v0.2.0
[0.1.2]: https://github.com/sideralith/drydock/releases/tag/v0.1.2
[0.1.1]: https://github.com/sideralith/drydock/releases/tag/v0.1.1
[0.1.0]: https://github.com/sideralith/drydock/releases/tag/v0.1.0
