# drydock architecture

How the container is wired, what gets mounted, and why the storage is split
the way it is.

## Mount map

```
HOST                                CONTAINER (debian:12-slim)
─────────────────────────────────  ─────────────────────────────────
~/.engram-container/   (optional)   ~/.engram/  ← isolated mode (default)
  or ~/.engram/        (opt-in)         overlay active only when engram is
  (see "engram" section below)          usable (Linux host + binary on PATH)

~/.claude/                          ~/.claude/  (container-specific)
  (host Claude's config dir)          ← bind from ~/.claude-container-<disc>/
                                       (seeded per-session from the
                                        ~/.claude-container/ prototype)
                                       Skills, plugins, hooks, settings visible

~/.claude.json                      ~/.claude.json  (container-specific)
  (project list, onboarding flags,    ← bind from ~/.claude-container-<disc>.json
   MCP servers, OAuth account)          (seeded per-session from the
                                        ~/.claude-container.json prototype)
                                        Without this, Claude Code in the
                                        container can't find its config file,
                                        creates a fresh ephemeral one, and
                                        "settings don't persist". MUST mount.

~/.claude/hooks/  ─────────────────→ ~/.claude/hooks/ :ro
  (authoritative)                     (RO overlay — agent can't self-edit)

~/.local/  ───────────────────────→ ~/.local/  :rw
  (binaries: claude, engram, etc.)    (shared — host upgrades propagate)

$PROJECT_DIR/  ───────────────────→ $PROJECT_DIR/  :rw
  (target project)                    (same path inside, so Makefile works)
$PROJECT_DIR/docs/ ───────────────→ $PROJECT_DIR/docs/  :rw
  (if 9P drvfs / sub-mount)           (explicit re-mount overlay)

~/git/sibling/     (optional)    ──→ /workspace-siblings/sibling  :ro  (or :rw)
  (any path via `drydock link`)       (:ro by default; :rw when `flags=rw` in
                                       the .list entry — set by `drydock link --rw`)
                                       Overlay generated per-launch from
                                       ~/.config/drydock/links/<project>.list

~/.config/drydock/ssh-config-<primary>   ──→ same path  :ro
  (managed SSH config; host-only;             (conditional — only when one or
   regenerated atomically on every             more RW siblings are linked;
   link/unlink of an RW sibling)               routes GIT_SSH_COMMAND through
                                               per-sibling alias blocks)

~/.config/drydock/keys/  ─────────────────→ same path  :ro
  (per-sibling ed25519 deploy keys;           (conditional — directory mount;
   host-only; left on disk after               scales to N siblings without
   unlink — see dual-hint message)             overlay enumeration changes)

/var/run/docker.sock  ────────────→ /var/run/docker.sock
  (host daemon)                       Container CLI → host daemon
                                       → `docker exec serendipilink-api …`

~/.gitconfig, ~/.config/gh/   ────→ same paths (gitconfig RO, gh RW)

NOT MOUNTED (by default):
~/.ssh, ~/.aws, ~/.gnupg, ~/.kube, ~/.bash_history;
other projects under ~/ — mountable explicitly via `drydock link` (see above)
```

**Env passthrough**: `GITHUB_PERSONAL_ACCESS_TOKEN` is forwarded from the
invoking shell (if set) so the GitHub MCP server and `gh` PAT auth work inside
the container — the only host env var drydock passes through. `docker compose
run` does not inherit the host environment, so this is an explicit
`environment:` entry in `docker-compose.yml`. `~/.config/gh` (mounted above)
covers `gh` CLI OAuth separately; the env var covers tools that read it directly.
See [security.md — host token passthrough](security.md#host-token-passthrough-github_personal_access_token)
for the `docker compose config --no-interpolate` debug-rendering guidance.

## Two config locations

Claude Code reads its configuration from **two** places, and drydock mounts
both:

| Location | Type | Contains | Container sibling |
|---|---|---|---|
| `~/.claude/` | directory | skills, plugins, agents, commands, hooks, `settings.json`, `CLAUDE.md`, `mcp/*.json` | `~/.claude-container-<disc>/` (per-session, seeded from `~/.claude-container/` prototype) |
| `~/.claude.json` | single file | project registry, onboarding flags, "seen hints", `mcpServers`, OAuth account, various caches | `~/.claude-container-<disc>.json` (per-session, seeded from `~/.claude-container.json` prototype) |

Forgetting the second one is a classic mistake: the container can't find
`~/.claude.json`, Claude Code creates a fresh one on the container's
ephemeral filesystem, and everything you configure in a session evaporates
on exit. `cmd_setup` and `cmd_sync` maintain the `~/.claude-container/`
prototype; each `drydock run` seeds a per-session `~/.claude-container-<disc>/`
pair from it via `seed_session_config_dir`.

## engram (optional)

> For the user-facing setup guide — installation, shared vs isolated mode,
> migration — see [engram.md](engram.md). This section covers the architecture.

engram is **not required**. drydock detects it and activates the overlay only
when both conditions are true: the `engram` binary is on the host's `$PATH`
AND the host OS is Linux. On a macOS host the binary is a native Mach-O
executable — it cannot run inside the Debian container, so drydock treats it as
absent regardless of `$PATH`.

When engram is not detected, `drydock setup`, `drydock run`, and all other
commands work without engram-related errors or startup noise. The engram MCP
server entry is removed from the container's `~/.claude-container.json` so
Claude Code doesn't try to spawn a missing binary.

### Topologies

| Mode | DRYDOCK_ENGRAM_SOURCE | When |
|------|----------------------|------|
| **Not detected** | — (overlay omitted) | No `engram` on PATH or macOS host |
| **Isolated** (default) | `~/.engram-container` | engram usable, no sentinel |
| **Shared** (opt-in) | `~/.engram` | engram usable + `~/.config/drydock/engram-shared` exists |

Isolated is the default and is always safe. Shared mounts the host's live DB
directly — the host and container agents share the same memories — but it
carries risk on WSL2 and macOS because POSIX file locks over those filesystems'
container bind-mount layers are unreliable.

### Enabling shared mode

On a native Linux host, `install.sh` (run interactively in a terminal) will ask
whether to enable shared mode and create the sentinel automatically. Shared mode
is suppressed without prompting on WSL2 and macOS, where file locks are
unreliable (INV-5). `install.sh` carries a standalone copy of the WSL2/macOS
lock detection (function `_host_shared_safe`), an intentional duplicate of
`lib/paths.sh:host_fs_locks_unreliable`, because a piped `curl | bash` install
cannot source `lib/`.

To enable it manually:
```bash
mkdir -p ~/.config/drydock
touch ~/.config/drydock/engram-shared
```

Remove it to return to isolated mode. Switching isolated → shared is **lossy**
if you accumulated memories in the isolated DB: they won't appear in the shared
DB until you export them from the container DB (`engram export <file>`) and
import the snapshot on the host (`engram import <file>`). drydock provides no
migration tool — this is your responsibility.

Switching shared → isolated is safe: `drydock setup` re-seeds
`~/.engram-container` from the current `~/.engram` (a fresh point-in-time
copy). Memories saved on the host during shared-mode sessions are already in
`~/.engram` and will be in the seed copy.

### Safety downgrade (WSL2 / macOS + shared requested)

When shared mode is requested but the host's container bind-mount layer has
unreliable POSIX file locks — detected when `/proc/sys/kernel/osrelease`
contains `microsoft` (WSL2) or `uname -s` returns `Darwin` — drydock
automatically falls back to isolated mode and emits a `warn` explaining why.
Set `DRYDOCK_ENGRAM_SHARED=force` to override the downgrade (the sentinel must
still be present; `=force` alone does nothing).

### macOS limitation and future paths

On macOS, the host `engram` binary is a Mach-O executable and cannot run in
the Debian Linux container. Two paths that would fix this for a future release:

1. **Linux engram in image** — build a `linux_amd64`/`linux_arm64` engram
   binary into the image at build time (adds ~10 MB, pins the version).
2. **HTTP-API bridge** — run `engram` on the host with
   `ENGRAM_CLOUD_HOST=0.0.0.0` (port 7437) and configure the container's MCP
   server to reach it via the host network (already shared via `network_mode:
   host`). No binary inside the container needed.

Neither is implemented in v0.1.0.

## Why the storage is split (host vs. container)

The container does **not** use the host's `~/.claude/`, `~/.claude.json`, or
`~/.engram/` directly. Claude config uses per-session container-specific
siblings (`~/.claude-container-<disc>/`, `~/.claude-container-<disc>.json`),
seeded from the `~/.claude-container/` prototype on each run via
`seed_session_config_dir`. Engram uses `~/.engram-container/` when isolated
mode is active, or the host's `~/.engram/` directly when shared mode is active.

Reasons (Claude config split — always applies):

1. **`~/.claude.json` is hot**: Claude Code rewrites it constantly (changelog
   fetch timestamps, "have you seen X", project `lastUsed` times, etc.).
   Shared between any two concurrent sessions = constant last-writer-wins
   churn. Each session gets its own per-session copy → no churn.

2. **OAuth refresh**: `~/.claude/.credentials.json` and `~/.claude.json`
   carry auth state. Concurrent refresh from two sessions = one invalidates
   the other. Per-session copies avoid this.

3. **Plugin install isolation**: `/plugin install foo` from inside the
   container lands in `~/.claude-container-<disc>/plugins/` only — the host
   doesn't know. Useful as a reversible playground (see [lifecycle.md](lifecycle.md)).

**Per-session config isolation (v0.2.0+).** Concurrent same-project sessions
— whether host-vs-container or container-vs-container — engage reasons 1 and
2 equally. Two drydock containers running concurrently for the same project
both perform read-modify-write on `~/.claude.json` and can refresh
`.credentials.json`. The mechanism that keeps this safe is per-session config
isolation: each invocation mounts its own `~/.claude-container-<disc>/`
directory and `~/.claude-container-<disc>.json` file (where `<disc>` is a
4-character random hex discriminator). No two concurrent sessions ever share
a `~/.claude*` source path with write access, so neither failure mode can
occur between sessions.

Reasons (engram isolated — the default):

1. **SQLite/WAL contention**: engram's DB is SQLite in WAL mode. On WSL2,
   fcntl POSIX locks crossing the host↔container 9P boundary are historically
   unreliable. If host Claude (on another project) and container Claude both
   write to the same `engram.db` concurrently, worst case is WAL corruption.
   Separate DBs → zero contention. On native Linux the bind mount is a local
   filesystem path and locking is reliable, which is why shared mode is allowed
   there (with a caveat warn).

Trade-off: the copies **diverge over time**. Skills/plugins/config installed
on host don't appear in the container until `drydock sync`. Engram memories
saved in isolated mode don't appear in the host DB (consolidate via `engram
sync --import`). This is intentional — divergence is the price of
contention-free concurrent host + container sessions.

## The hooks RO overlay

`~/.claude/hooks/` is bind-mounted **`:ro`** on top of the `.claude-container-<disc>`
mount (the second mount masks that subpath of the first). Effect: the agent
inside the container can read its hooks (e.g. `block-destructive.sh`, which
is a PreToolUse guardrail) but **cannot edit them**. Without this, the agent
could in principle disable its own guardrails — the protection would be
illusory under both adversarial behavior and ordinary bugs.

This means hook updates must happen on host. The container always sees the
host's authoritative hooks.

## The managed-settings layer (v0.2.0+)

Complementing the hooks RO overlay, drydock delivers its agent policy via Claude
Code's managed-settings mechanism.

**What it is.** Claude Code on Linux auto-loads `/etc/claude-code/managed-settings.d/`
at startup with no flags required. Files in that directory are merged at highest
precedence: deny arrays are concatenated and deduplicated; hook entries are
deduplicated by command string. Managed settings cannot be weakened or overridden
from project-level `settings.json` files.

**How drydock delivers it.** The drop-in files live in `templates/managed-settings.d/`
in the drydock repository. During `drydock build`, the Dockerfile COPYs them into the
image at `/etc/claude-code/managed-settings.d/` (root-owned) and resolves the
`__HOME__` placeholder to `/home/${USER_NAME}` via a `RUN sed`. The non-root
container user cannot write to `/etc/` — the policy is tamper-proof by image-layer
ownership, not merely by a bind-mount flag.

**Drop-in files and what each covers:**

| File | Layer | Contents |
|------|-------|----------|
| `00-secrets.json` | Tier 1 — deny | Secret-file read deny — credential dirs/files use root-anchored `//**/<path>` patterns (effective at any mount depth, including inside sibling projects); drydock-state paths use `__HOME__`-anchored patterns |
| `10-git-safety.json` | Tier 1 — deny | Git destructive-ops deny (force-push, protected-branch delete/rename, history-rewrite, GitHub API destructive ops) |
| `20-hooks.json` | Tier 2 — hook wiring | `hooks.SessionStart` entry — wires `drydock-session-start.sh` |
| `30-os-safety.json` | Tier 1 — deny | OS destructive-ops deny (rm system paths, disk destruction, package purge, firewall flush, docker host-escape) |
| `40-guardrails-hook.json` | Tier 2 — hook wiring | `hooks.PreToolUse` entry — wires `drydock-block-destructive.sh` with matcher `"Bash"` |

The deny layers (Tier 1) are evaluated by Claude Code **before** any hook runs.
The hook wiring drop-ins (Tier 2) register the shell scripts that handle cases
the declarative deny cannot express.

**INV-2 compliance.** The managed-settings directory lives at `/etc/claude-code/` —
outside `$HOME`. It is drydock-owned policy config, not host `~/.claude/` state. The
host/container state-split boundary (INV-2) is never crossed.

**INV-3 strengthening.** Before v0.2.0, the deny block and hook entry lived in the
per-project `settings.json` seeded by `drydock init` — a writable file the agent
could overwrite. The managed-settings layer closes this gap: the same policy is now
structural (image-layer immutable) rather than advisory. The hooks RO overlay (hook
*scripts*) and the managed-settings layer (policy *rules* + hook *wiring*) together
make drydock's full tier-1 defense structural.

**Refresh cadence.** Policy updates (new deny entries, hook changes) take effect after
`drydock build`. Users already rebuild after pulling drydock when Dockerfile or MCP
binary changes land — the marginal cost is zero.

## The destructive-command guardrail layer (v0.2.0+)

drydock ships a two-tier defense against accident-class destructive commands,
both tiers image-baked and tamper-proof. Full coverage details and known
limitations are in [security.md](security.md#destructive-command-guardrail-layer-v020).

**Tier 1 — declarative deny.** `10-git-safety.json` and `30-os-safety.json`
cover the deny-expressible classes: protected-branch operations, history-rewrite,
GitHub destructive API calls, `rm -rf` to system paths, disk/partition tools,
package purge, firewall flush, and docker host-escape (`--privileged` /
`-v /:` mount). Deny patterns use strict word-boundary shapes; the B9/B10 matrix
loops 8 protected branches × up to 6 flag forms to eliminate false positives.

**Tier 2 — PreToolUse hook.** `templates/hooks/drydock-block-destructive.sh`
covers the five residue classes the deny mechanism cannot express (ssh to
production host, fork bomb, `rm` of `.` or `.git`, parent-traversal `rm`,
curl/wget pipe to shell). It is wired by `40-guardrails-hook.json` as a
`hooks.PreToolUse` handler with matcher `"Bash"`. The hook applies regex checks
to the full command string — no tokenization, no `eval`. For docker-wrapped
commands (`docker exec <ctr> <cmd>` / `docker run [opts] <image> <cmd>`), the
dangerous substrings are present in the full string regardless of the wrapper,
so no special docker branch is needed.

**Data flow:**
```
Claude Code: Bash tool call
    │
    ▼
[Tier 1] permissions.deny  (10-git-safety.json + 30-os-safety.json)
    │  match → DENIED, hook never runs
    ▼  no match
[Tier 2] PreToolUse hook  (40-guardrails-hook.json wires it)
    │  → sh -c guard → /opt/drydock/hooks/drydock-block-destructive.sh (RO bind-mount)
    │  → reads {tool_name, tool_input.command} JSON on stdin
    │  → 5 residue regexes, full-string match
    │  match → exit 2 (blocked) │ no match → exit 0 (allowed)
    ▼
Command executes
```

**Accident-class boundary.** This layer inspects command strings. Raw Docker
socket calls, the Docker SDK, or base64-obfuscated payloads bypass it. This is
a documented non-goal per INV-6 and INV-7 — drydock defends against accidents,
not adversaries.

## How drydock decides what to mount

Each `drydock run` invocation reads the **current project directory** (cwd or
arg) and exports it as `PROJECT_DIR` to compose. The compose file uses
`${PROJECT_DIR}` for the project mounts. The image is universal — only the
env vars change per project (`PROJECT_DIR`, `PROJECT_NAME`, `USER_UID`,
`USER_GID`, `HOST_DOCKER_GID`, `COMPOSE_PROJECT_NAME`).

**Sub-mount propagation overlay**: on each `drydock run`, the CLI calls
`detect_submounts "$PROJECT_DIR"` which reads `/proc/self/mountinfo` and emits
one pipe-delimited record per sub-mount of `$PROJECT_DIR` in the format
`<docker-source>|<mount-point>|<class>`. Three classes are recognised:

- **drvfs** (`9p` fstype with `aname=drvfs` in super-options): WSL2 9P
  drvfs share from Windows. The Windows drive letter (`path=X:\` in
  super-options) is extracted, and the docker-source is translated to
  `/mnt/<letter>/<fsroot>` — the path Docker Desktop's own WSL2 channel
  can read.
- **linux-native** (`ext4`, `btrfs`, `xfs`, `zfs`, `f2fs`, `reiserfs`,
  `ext3`, `ext2`): block-backed bind mounts. The source filesystem root
  is located via a major:minor reverse-lookup against `/proc/self/mountinfo`
  rows where `fsroot == "/"`. If no such row exists (orphan major:minor),
  the row is emitted with an empty docker-source and `generate_submount_overlay`
  skips it with a stderr warning.
- **exotic** (all other fstypes including `nfs`, `cifs`, `fuse.*`, `tmpfs`,
  `overlay`): source passed through as-is with a stderr warning that
  propagation may not work. `tmpfs` and `overlay` are explicitly in this
  bucket — their major:minor reverse-lookup would resolve to unrelated
  mountpoints (`/run`, Docker layer FS), producing a wrong translation.

When at least one non-empty-source row is detected, `generate_submount_overlay`
writes a temporary YAML overlay to `${TMPDIR:-/tmp}/drydock-submounts-$$.yml`
(PID-namespaced) and `compose_files` adds `-f $SUBMOUNT_OVERLAY` to the
compose invocation. The overlay is cleaned up by a `trap ... EXIT` registered
inside `main()`.

**Sibling-links overlay** (v0.2.0+): `drydock link <host-path> [container-target]`
appends a pipe-delimited entry to `~/.config/drydock/links/<project>.list`
(format: `<host_path>|<container_target>|<flags>`). On every `drydock run`/`shell`,
`generate_links_overlay` reads the list and writes `${TMPDIR:-/tmp}/drydock-links-$$.yml`
with a `services.drydock.volumes` block. Each entry is mounted `:ro` by default; when
the `flags` field is `rw` (set by `drydock link --rw`), the entry is mounted `:rw`
instead. The overlay is simpler than sub-mount propagation — no `environment:` block,
no env-var passthrough (all paths are static literals). `drydock unlink` removes
entries; `drydock links` shows the current list. The feature is config-command-only:
`link`/`unlink`/`links` do NOT invoke `export_compose_env`, so they work without a
running container.

**The host-path-mirror pattern.** The optional custom container target lets a
sibling be mounted at the **same absolute path inside the container as it has on
the host**. For example:

```bash
drydock link ~/git/shared-lib /home/rai/git/shared-lib
```

Inside the container, `shared-lib` appears at `/home/rai/git/shared-lib` — the
same path the host shell resolves. This is useful when stack traces, language
server output, IDE configs, or build tool output embed absolute paths: the paths
are stable and match what is on disk. Devcontainers use the same convention.

The reason this works without a special flag is that `home` is intentionally
**not** in the system-directory reject list at `lib/commands.sh:753`. Targets
under `$HOME` (e.g. `/home/<user>/git/foo`) are valid; only `$HOME` itself and
its ancestors are rejected. See [docs/links.md](links.md#the-host-path-mirror-pattern)
for the full pattern guide.

**INV-3 and the link guard.** The hooks RO overlay covers two paths:
`${HOME}/.claude/hooks:ro` at `docker-compose.yml:70` and
`/opt/drydock/hooks:ro` at `docker-compose.yml:84`. A linked sibling mounted
over either path would silently remove the `:ro` protection. `drydock link`
defends against both:

- **`/opt/drydock/hooks`** is explicitly rejected by guard (d) at
  `lib/commands.sh:745-751` — this path gets a named guard because it is a
  specific drydock-internal path that does not fall under the broader
  system-directory class (which covers `opt` generally but not the hooks
  subpath specifically).
- **`~/.claude/hooks`** shadowing is prevented by guard (e)'s
  `$HOME/.claude*` pattern, which rejects any target that would shadow the
  home-relative Claude state directories.

See [security.md](security.md).

Because `lib/commands.sh` uses `exec docker compose run` for `run`/`shell`
(which replaces the bash process and fires no EXIT trap), `bin/drydock` also
performs a **startup orphan reap**: on each invocation it globs for both
`/tmp/drydock-submounts-*.yml` and `/tmp/drydock-links-*.yml`, extracts the PID
from each filename, checks liveness with `kill -0`, and removes any orphaned files
from past `exec`'d invocations. Concurrent invocations are safe — a live PID's
file is left untouched.

## Docker-out-of-Docker (DooD), not Docker-in-Docker

drydock bind-mounts `/var/run/docker.sock`. The `docker` CLI inside the
container talks to the **host's** daemon — it does NOT run a nested daemon.
So sibling containers in any project's `docker-compose` stack are visible:
`docker exec serendipilink-api …`, `make shell-api`, project Makefile
targets all work transparently.

Consequence: socket access ≈ root-equivalent on the host. This is why
drydock's threat model is "defense against accidents, not adversaries" — see
[security.md](security.md).

## Container base + UID/GID matching

Base image: `debian:12-slim`. Tooling installed: `docker-ce-cli`,
`docker-compose-plugin` (+ a `docker-compose` v1-name shim), `gh`, `make`,
`git`, `rsync`, `jq`, `curl`, plus `procps`/`vim-tiny`/`less` for
ergonomics. `sudo` is intentionally NOT installed — `no-new-privileges:true`
(INV-8) would make it a no-op anyway, so it would only be image weight.

The image is built with `USER_UID` / `USER_GID` / `HOST_DOCKER_GID` build
args (the CLI auto-detects from `id` and `stat /var/run/docker.sock`). The
container user `rai` is created with the matching UID/GID and added to a
group with the host's docker-socket GID. This ensures files created from
inside the container land on host with the user's ownership (not `root`) and
the docker socket is readable. Defensive `groupmod`/`groupadd` handles GID
collisions in the base image.
