# drydock troubleshooting

Common failures and fixes. Run `drydock doctor` first — it shows versions,
paths, mount detection, and GIDs.

## `drydock build` / `run` aborts with "the Docker daemon is not responding"

Before building or starting a container, drydock probes the Docker daemon. If the
socket file exists but the daemon does not reply (for example, Docker Desktop left
degraded after host memory pressure), drydock now **fails fast** with this message
instead of hanging indefinitely. Restart your Docker engine, then retry:

- **Docker Desktop** (macOS / Windows / WSL2): restart it from the tray, or quit
  and reopen. Wait for "Engine running".
- **Docker Engine** (Linux / native WSL2): `sudo systemctl restart docker`
  (or `sudo service docker start`).

Verify with `docker ps` — it should return instantly — then retry. The probe
timeout is 12s by default; tune it with `DRYDOCK_DOCKER_PROBE_TIMEOUT` (seconds).

## Claude prompts for login every session

By design, each drydock container does not inherit the host's OAuth credentials
(`~/.claude/.credentials.json` is not synced into the container — INV-2 prevents
the concurrent-write race that would cause both sessions to get logged out).

**Friction-free fix — generate a 1-year OAuth token once:**

```bash
drydock setup-token
```

This runs `claude setup-token` interactively — you complete the browser
authorization flow and see the token printed by claude. drydock then asks you
to paste that token, validates it, and writes it atomically to
`~/.config/drydock/claude-oauth-token` with mode `0600`. From then on drydock
auto-includes a `docker-compose.oauth.yml` overlay that injects the token as
`CLAUDE_CODE_OAUTH_TOKEN` — every session starts without a prompt.

**If you prefer not to generate a long-lived token:** just log in when the prompt
appears. The credentials are stored in the per-session container config and
persist for the duration of that container's lifetime.

**Revoking the token:**

```bash
drydock revoke-token
```

This removes the local token file. The token itself remains valid server-side until
you revoke it at claude.ai → Settings. Always do both steps to fully revoke.

**Security note:** the OAuth token grants approximately 1 year of Claude account
access. It is stored at `~/.config/drydock/claude-oauth-token` (`0600`) and is
already covered by the deny rule `Read(__HOME__/.config/drydock/**)` in the
image-baked managed-settings layer — the agent inside the container cannot read
the file. The token value reaches the container only via the `CLAUDE_CODE_OAUTH_TOKEN`
environment variable; no bind-mount of the token file is ever created.

See also: [docs/security.md](security.md#claude-oauth-token-docker-composeoauthyml).

## Container config edits revert every run (plugin config, MCP entries, settings)

Config changes made inside the container — installing a plugin, editing
`settings.json`, adding an MCP server entry — do not persist across sessions by
default. Each `drydock run` seeds a fresh per-session `~/.claude-container-<disc>/`
directory from the prototype. Changes written inside the container stay in the
ephemeral session dir and are discarded when the session ends.

**Fix — use the persistent overlay:**

Place the files you want preserved into `~/.config/drydock/claude-overlay/`,
mirroring the layout of `~/.claude/`. drydock copies them on top of the freshly-seeded
session dir on every `drydock run` — before Claude Code starts.

```bash
mkdir -p ~/.config/drydock/claude-overlay/
# Example: persist a plugin's config
cp ~/.claude/plugins/my-plugin/config.json \
   ~/.config/drydock/claude-overlay/plugins/my-plugin/config.json
```

The overlay is **host → container only**. Changes made inside the container are not
written back. To update a persisted file, edit the copy under
`~/.config/drydock/claude-overlay/` on the host.

**Restrictions** — the overlay rejects and aborts with an error if:

- `~/.claude.json` or `.credentials.json` appear at the overlay root (INV-2 hazard).
- Any entry is a symlink (at any depth) — copy the real file instead.
- Any entry is not a regular file or directory (FIFOs, device nodes, etc.).

See also the [architecture.md INV-2 deep-dive](architecture.md) for the full rationale.

## "Claude configuration file not found at: ~/.claude.json" / settings don't persist

Claude Code reads config from TWO locations: the `~/.claude/` **directory**
(skills, plugins, `settings.json`, `CLAUDE.md`, hooks) AND the `~/.claude.json`
**file** (project list, onboarding flags, `mcpServers`, OAuth). drydock must
mount both. If the `~/.claude-container.json` prototype doesn't exist on host,
the per-session `~/.claude-container-<disc>.json` cannot be seeded, Claude Code
inside the container can't find `~/.claude.json`, creates a fresh one on the
container's ephemeral filesystem, and any config you do (onboarding, theme,
hints) is lost when the container exits.

Fix:

```bash
cp -a ~/.claude.json ~/.claude-container.json    # repair the prototype; or: drydock setup
```

`drydock setup` auto-creates the prototype. `drydock sync` refreshes it from
host. The compose file mounts a per-session `~/.claude-container-<disc>.json`
(seeded from the `~/.claude-container.json` prototype) at
`~/.claude.json:rw`.

## In contained mode, `docker`, `docker compose`, `curl localhost:PORT`, or `make shell-api` stopped working

As of v0.4.0 drydock runs **contained by default**: no Docker socket and no host
networking. That deliberately removes the two things stack tooling needs — the
host Docker daemon and the host network namespace — so these stop working in
contained mode:

- `docker` / `docker compose` / `docker exec` against your host stack
- `curl http://localhost:PORT/...` to a service published on the host
- `make shell-api` and anything else that reaches the host daemon or network

The agent's own internet access is jailed behind a deny-by-default domain
allowlist in contained mode — it reaches allowlisted hosts only (see the next
section to add one).

Switch the project to **dood mode**, which restores the host Docker socket and
host networking (the socket is root-equivalent on the host — INV-6):

```bash
drydock dood <proj>        # pin this project to dood mode
drydock default dood       # or make dood the default for all new/unpinned projects
DRYDOCK_DOOD=1 drydock     # or override for a single invocation
```

`drydock doctor` shows the active mode and why it was chosen; the mode also prints
at container creation. Revert with `drydock contain <proj>` (per project) or
`drydock default contain` (global, back to the factory default). See INV-9 in
CLAUDE.md and [docs/security.md](docs/security.md).

## In contained mode, a domain is not reachable (403 / connection refused)

Contained mode (the factory default, INV-9) jails egress behind a drydock-managed
deny-by-default domain allowlist: a per-session proxy sidecar only tunnels CONNECT
to allowlisted hostnames on port 443. A request to any other host fails — the
proxy returns **HTTP 403**, which most tools surface as a failed HTTPS connection.

The shipped baseline covers what Claude Code needs to authenticate and run under
drydock's default token auth (`api.anthropic.com` and friends); it is provisional
and finalized before v0.4.0 ships. To reach an additional host, add it to one of
the user allowlist files, then start a **new** session (the effective filter is
generated at session start):

```bash
# global — applies to every project
echo "example.com" >> ~/.config/drydock/egress-allowlist

# or per-project — applies only to <project>
echo "example.com" >> ~/.config/drydock/egress-allowlist-<project>
```

One host per line; `#` comment lines are allowed. User files only **add** to the
baseline — they cannot remove or weaken it. `drydock doctor` has an **EGRESS**
section that reports the active allowlist sources and the effective filter for the
current project.

If a tool still cannot reach the network but you did not get a 403, check that it
honors `HTTPS_PROXY` — a tool that ignores the proxy environment variables gets a
DNS SERVFAIL on the internal network (there is no NAT route off it), which is
breakage, not a bypass. If you genuinely need unrestricted egress and host-stack
access, opt the project into dood mode (`drydock dood <proj>`).

> **Upgrade note.** drydock never removes its Docker networks, so a machine that
> ran an earlier contained build keeps a now-unused `drydock_net` bridge after
> upgrading. It is harmless; remove it if you like with `docker network rm
> drydock_net`. The current topology uses `drydock_internal` and `drydock_egress`.

## `docker exec` from inside the container fails with permission denied

The container user must be in a group matching the host's docker-socket GID.
Check on host:

```bash
stat -c '%g' /var/run/docker.sock
```

If different from the `HOST_DOCKER_GID` baked into the image (default 1001),
rebuild with the right value:

```bash
HOST_DOCKER_GID=999 drydock build
```

The CLI auto-detects on each build by default — manual override only if the
detection is wrong for some reason.

## `claude` not found inside container

The binary lives at `~/.local/bin/claude` on host, bind-mounted into the
container. If `PATH` doesn't include `~/.local/bin`, check `ENV PATH` in the
Dockerfile.

## Engram returns "no memories" inside container

Verify `~/.engram-container/engram.db` exists on host with size > 0:

```bash
ls -la ~/.engram-container/
```

If empty, re-init:

```bash
rm -rf ~/.engram-container
drydock setup
```

If it has memories but they're stale (missing recent ones saved on host), the
container DB diverged from host's — that's by design (see
[architecture.md](architecture.md) § "Why the storage is split"). Consolidate
with `engram export` / `engram import`, or re-snapshot:

```bash
# WAL caveat: stop all Claude/engram processes first, or you risk a torn copy
rm -f ~/.engram-container/engram.db-wal ~/.engram-container/engram.db-shm
cp -a ~/.engram/engram.db ~/.engram-container/engram.db
```

For shared vs isolated mode and the migration recipe, see [engram.md](engram.md).

## Files created from container appear as `root` on host

UID/GID mismatch. Check on host:

```bash
id            # UID/GID must match what `drydock build` used
```

Rebuild:

```bash
USER_UID=$(id -u) USER_GID=$(id -g) drydock build
```

## gh CLI fails with "failed to write config after migration"

`~/.config/gh` must be RW (it migrates `hosts.yml` schema on first run in a
fresh environment). This is the default in drydock. If you changed the mount
to `:ro`, revert it.

## Image doesn't pick up changes to the Dockerfile

`drydock build` always rebuilds. If you suspect a stale layer cache:

```bash
docker image rm drydock:latest
drydock build
```

## Claude Code output feels slightly slower than running on host (TTY latency)

If you notice Claude Code's streaming text output is **a bit slower inside
drydock than running `claude` directly on the host**, this is a known
side effect of the container's PTY chain — not something drydock can
remove from its side without breaking the design.

### The chain

drydock (v0.3.0+) launches each session via `docker compose up -d` (the
container's PID 1 is `sleep infinity`) and attaches Claude via `docker
compose exec -it ... claude` — see `lib/commands.sh`. The PTY chain is the
same shape under `exec` as it was under the older `compose run --rm`
model. Every byte the `claude` process writes flows through:

```
claude (container)
  → containerd PTY
  → Docker daemon
  → docker compose CLI (host)
  → your terminal
```

On native Linux with a local Docker Engine, every hop in that chain lives
in the same kernel — added latency is microseconds, imperceptible.
On WSL2 + Docker Desktop or macOS + Docker Desktop, the Docker daemon
runs inside a **separate Linux VM** (HyperV on Windows, virtio on macOS).
That adds one extra IPC bridge per byte:

```
claude (container)
  → containerd PTY
  → Docker daemon IN VM
  → VM ↔ host bridge   ← extra hop here
  → docker compose CLI (host)
  → your terminal
```

Per-byte RTT goes up by ~5-15 ms depending on the bridge implementation.
Claude Code emits many small streamed chunks, so the sum is perceptible
as "feels a touch slower."

### Mitigations

| Host OS | Bridge | Best mitigation |
|---------|--------|-----------------|
| **Linux native** | None — same kernel | Already optimal. |
| **WSL2** (with Docker Desktop) | HyperV VM, 9P/named-pipe | Switch to **Docker Engine inside the WSL2 distro** (install `docker-ce` in WSL2 and disable Docker Desktop's WSL2 integration). Removes the HyperV hop. Largest payoff of any mitigation listed. |
| **macOS** (Docker Desktop, virtiofs) | virtio-VM | Modern Docker Desktop already uses **virtiofs** (much better than legacy gRPC-FUSE). Alternatives: **OrbStack** (paid, fast Rosetta-backed VM) or **Colima** (free, lima/QEMU). All still have a VM hop — macOS has no equivalent to "Linux in a Linux VM" so the bridge is unavoidable. |
| **macOS Apple Silicon** | virtio-VM | Same as above; ensure Docker Desktop uses VirtualizationFramework (Settings → General → "Use Virtualization framework"), not the legacy QEMU backend. |

### What drydock cannot easily change

The `compose up -d` + `exec` lifecycle (v0.3.0+) already removes the
per-session container-creation cost (~1 s) compared with the older `compose
run --rm`: subsequent `drydock attach` invocations reuse the live container
and only spawn a new `claude` process via `exec`. What it **does not**
change is the per-byte TTY latency — the daemon-to-host bridge is shared by
both `compose run` and `compose exec`, so the chain length is unchanged.
INV-2's per-session `~/.claude-container-<disc>/` config isolation is
preserved by the per-session discriminator (each persistent container has
its own session dir); the `~/.claude-container/projects/` shared store is
the documented INV-2 carve-out for `claude --resume` (append-only-per-uuid,
no RMW).

### What to check first

If the latency feels worse than the description above (multi-second pauses,
not just a faint streaming feel), the cause is probably **not** the PTY
chain. Look for:

- **`drydock build` not yet run** — the auto-sync step on first invocation
  can take seconds the first time.
- **Engram shared-mode misconfigured** on WSL2/macOS — should never trigger
  (INV-5 force-downgrade), but verify with `drydock doctor`.
- **A heavy MCP server in `~/.claude.json`** — every Claude Code start
  loads MCP servers in parallel; a slow one delays first output.

## `drydock attach` says my session is managed by zellij/tmux/screen

If you launched drydock from *inside* a terminal multiplexer (zellij, tmux, or
screen — or with `DRYDOCK_NESTED=1`), the session runs as an **ephemeral nested
session** (`docker compose run --rm`) that lives in the multiplexer pane where
you started it — not as a persistent `up -d` container. It still appears in
`drydock list` and the interactive selector, but it cannot be re-`exec`'d into
from a second terminal the way a persistent session can.

So when you select it (or run `drydock attach <name>`), drydock detects the
nested session and — instead of attaching — prints how to get back to it:

```
This is a nested drydock session in your zellij terminal.
To reattach, switch to that window or run:  zellij attach <session>
```

(the equivalent is `tmux attach -t <session>` or `screen -r <session>`). This
is expected — switch back to the multiplexer window, or run the printed
command. To start a *fresh* persistent session instead, run `drydock new` from
a terminal that is not inside a multiplexer.

## A command was unexpectedly blocked by the guardrail layer

drydock ships a two-tier guardrail layer. Both tiers are tamper-proof — Tier 1
(the deny policy) image-baked into the container, Tier 2 (the hook script)
read-only via bind-mount (INV-3). See
[security.md](security.md#destructive-command-guardrail-layer-v020).

**Tier 1 — declarative deny (`permissions.deny`).** Two managed-settings drop-ins
at `/etc/claude-code/managed-settings.d/` (root-owned, not overridable from project
`.claude/settings.json`):

- `10-git-safety.json` — git destructive ops: protected-branch delete/rename,
  history-rewrite, remote-delete refspecs, GitHub destructive API calls.
- `30-os-safety.json` — OS destruction: `rm -rf` to system paths, disk-destruction
  tools (`dd`, `mkfs`, `wipefs`), `sudo` + destructive verb, package-manager
  purge/remove, firewall flush, `docker system/volume prune`, `docker run --privileged`,
  host-root bind mounts, and more.

Claude Code evaluates the deny list before any hook runs — matched commands are
blocked at the framework level.

**Tier 2 — `PreToolUse` hook (`drydock-block-destructive.sh`).** Handles six rule
classes that deny patterns cannot express:

| Rule | Example blocked |
|---|---|
| C1-residue — `rm` with a recursive flag targeting a system path | `rm -Rf /etc` |
| A1 — ssh to production host | `ssh user@prod.example.com` |
| C12 — fork bomb | `:() { :|:& };:` |
| C17 — `rm` of `.` or `.git` | `rm -rf .` |
| C18 — `rm` of parent traversal | `rm -rf ../sibling` |
| C20 — curl/wget pipe to shell | `curl https://x.com/i.sh \| bash` |

**If the block is correct:** rephrase the command to a non-destructive form, or
run it from the host where drydock's guardrails do not apply.

**If you believe it is a false positive:** check the documented limitation classes
in [security.md](security.md#known-limitations). If your case is not listed, open
a GitHub issue. Do NOT edit the image-baked drop-ins locally — a `drydock build`
restores them from the image.

**To inspect active rules:** the drop-in JSON files are readable at
`/etc/claude-code/managed-settings.d/` inside the container (read-only), and in
the repo at `templates/managed-settings.d/`.

## Sub-mount not visible inside the container

drydock automatically detects sub-mounts under `$PROJECT_DIR` and propagates
them. Run `drydock doctor` to see the current detection:

```bash
cd ~/projects/yourproject && drydock doctor
# Look for the "sub-mounts under ..." section:
#   ✓ /home/you/projects/yourproject/docs → /mnt/c/.../docs (drvfs auto-translated)
#   ✓ /home/you/projects/yourproject/data → /data/src (Linux-native bind)
#   ⚠ /home/you/projects/yourproject/nfs → server:/share (nfs, may not propagate)
#   (none detected)
```

**If a sub-mount shows `✓` but content is still missing inside the container:**
- Restart `drydock shell` — the overlay is generated per-invocation; a running
  container from before the mount was added won't have it.
- For drvfs: ensure Docker Desktop is running and the WSL2 integration is
  enabled for the drive.

**If a sub-mount shows `⚠ (source FS root not found — will be skipped)`:**
- This is a linux-native bind where the source filesystem's root entry is
  missing from `/proc/self/mountinfo`. This can happen on some container
  runtimes or with unusual bind configurations. Diagnostic:
  `awk '{print $3, $4, $5}' /proc/self/mountinfo | sort` — look for the
  major:minor of the sub-mount and check if a row with `fsroot=/` exists.

**If a sub-mount is classified exotic and not propagating:**
- NFS, CIFS, FUSE, tmpfs, and overlay mounts may not propagate through
  Docker Desktop's WSL2 channel. The source path is passed through as-is,
  but Docker may reject or silently drop it. Consider bind-mounting a
  linux-native path instead.

**If `(none detected)` but you see a mount in `mount | grep your/path`:**
- Check that the mount appears in `/proc/self/mountinfo` (not just `/proc/mounts`
  which can be stale). drydock reads `mountinfo` exclusively.

## Sub-mount visible in drydock but NOT in containers launched via DooD

The sub-mount propagation overlay only applies to the **drydock container
itself**. When you (or the agent inside drydock) runs `docker compose up`
against a project's own stack (Docker-out-of-Docker), those child containers
talk to the host's Docker daemon — which does NOT see drvfs sub-mounts
created post-boot of its WSL2 shared filesystem. The path `./docs` in your
project's compose resolves to the same drvfs path the host daemon can't read,
so the child container sees the mount as empty.

**Symptom**: `drydock shell` lists `docs/` correctly, but
`docker exec your-project-api ls /var/www/docs` is empty.

**Fix**: drydock exports a translated host path as an env var for each
detected sub-mount: `DRYDOCK_SUBMOUNT_<UPPER_RELPATH>_HOST_PATH`. Reference
it in your project's `docker-compose.yml` with a portable fallback:

```yaml
# project-side docker-compose.yml
services:
  api:
    volumes:
      - ./backend:/var/www/html
      # Use the drydock-translated path inside drydock; fall back to ./docs
      # for collaborators without the bind mount (or running outside drydock).
      - ${DRYDOCK_SUBMOUNT_DOCS_HOST_PATH:-./docs}:/var/www/docs
```

The env var name is derived from the path of the sub-mount relative to
`$PROJECT_DIR`: uppercased, with non-alphanumeric characters replaced by `_`.
Examples:

| Sub-mount path inside project | Env var name |
|---|---|
| `docs/` | `DRYDOCK_SUBMOUNT_DOCS_HOST_PATH` |
| `vault/notes/` | `DRYDOCK_SUBMOUNT_VAULT_NOTES_HOST_PATH` |
| `data/shared/` | `DRYDOCK_SUBMOUNT_DATA_SHARED_HOST_PATH` |

The fallback `${DRYDOCK_SUBMOUNT_..._HOST_PATH:-./docs}` keeps the project's
compose portable: collaborators on machines without the bind mount (or
running `docker compose up` directly without going through drydock) use the
literal `./docs` path.

### How the env vars flow into compose substitution

drydock writes the env vars in three places automatically every time the
CLI runs against your project:

1. **Host CLI shell environment** — `export_compose_env()` sets each
   `DRYDOCK_SUBMOUNT_*_HOST_PATH` in the shell that invokes
   `docker compose run drydock …`.

2. **Container drydock environment (DooD passthrough)** — the generated
   submount overlay (`/tmp/drydock-submounts-<pid>.yml`) declares
   `environment:` entries (KEY-only) so docker compose inherits each value
   from the CLI shell into the container drydock. The inner `docker compose`
   (run by the agent inside drydock) then sees the env vars and substitutes
   them.

3. **`${PROJECT_DIR}/.env` marker block** — drydock writes a
   marker-delimited block in your project's `.env` file containing one
   line per detected sub-mount:

   ```ini
   APP_KEY=base64:...
   DB_PASSWORD=hunter2

   # >>> drydock managed (auto-generated, do not edit manually) <<<
   DRYDOCK_SUBMOUNT_DOCS_HOST_PATH=/mnt/c/Users/.../Vault
   # <<< end drydock managed >>>
   ```

   This lets `docker compose` invocations from the **host shell directly**
   (without drydock involvement) substitute the env vars too — docker
   compose reads `.env` automatically when run in the project directory.

The marker block is maintained idempotently: re-runs of drydock won't
duplicate it; sub-mounts that disappear get their entries removed; the
block is deleted entirely when there are no more sub-mounts. **Only the
content between the markers is touched** — your other `.env` variables are
preserved.

**`.env` is gitignored**: ensure your project's `.gitignore` includes
`.env` (this is the standard pattern). drydock's marker block contains
host-specific paths and should never be committed.

**Interaction with the managed-settings `.env` deny.** Since v0.2.1
`00-secrets.json` denies `Read`/`Edit`/`Write` on `.env` and its common
variants via Claude Code's tool layer. drydock's marker-block auto-edit
is unaffected: the drydock CLI writes the marker block via direct shell
file I/O (not through Claude Code's `Write` tool), so the deny does not
apply. The deny only blocks the agent from reading or modifying `.env`
through Claude Code's tools — which is the intended protection.

**Opt out**: set `DRYDOCK_SKIP_ENV_WRITE=1` in your environment to disable
the `.env` auto-edit. The overlay environment passthrough (item 2 above)
keeps working, so the bug fix still applies when running through drydock —
you only lose the "host shell direct" path.

**Migration note**: if you previously added `DRYDOCK_SUBMOUNT_*_HOST_PATH`
lines to `.env` by hand (before this feature existed), drydock will NOT
touch them — they live outside the marker block. After a `drydock` run,
your `.env` will have BOTH the manual line and a duplicate inside the
marker block. docker compose reads top-down, so the marker-block value
(written last) wins. To clean up, delete the manual line; drydock's marker
block stays.

**Why this gap exists**: drydock's sub-mount propagation rewrites paths for
its own container, but cannot intercept arbitrary `docker compose` calls the
agent makes internally — those go directly to the host daemon via the
bind-mounted socket. Exposing the translated path as an env var lets each
project opt in explicitly in its compose file, and the three-layer
auto-population (shell + container env + `.env`) covers every common flow.

## ccstatusline / MCP-remote OAuth tools not working inside drydock

Two opt-in compose overlays activate **automatically** when drydock detects
the user has the relevant tool configured on host:

| Overlay | Activated when | What it mounts |
|---|---|---|
| `docker-compose.mcp-auth.yml` | `~/.mcp-auth/` exists on host | `~/.mcp-auth/` RW (mcp-remote OAuth tokens) |
| `docker-compose.ccstatusline.yml` | `~/.config/ccstatusline/` exists on host | `~/.config/ccstatusline/` + `~/.cache/ccstatusline/` RW |

These overlays are **strictly opt-in** — drydock does NOT create empty dirs
in users' homes for tools they don't use. To activate:

- **mcp-remote** (Cloudflare-bindings MCP, etc.): authenticate once from
  host claude (where the browser flow works); `mcp-remote` creates
  `~/.mcp-auth/<server-hash>/` with the OAuth tokens. From then on every
  drydock session sees them and the MCP server connects without re-auth.
  Symptom of missing this: `MCP server "cloudflare-bindings" connection
  timed out after 30000ms` because mcp-remote falls back to launching a
  browser that does not exist inside the container.

- **ccstatusline**: run `npx ccstatusline` once from host claude and save
  your preferences. The directory `~/.config/ccstatusline/` is created
  automatically and from then on drydock mounts it. Symptom of missing
  this: status line shows defaults (segments/themes from ccstatusline are
  NOT applied) even after `drydock sync` ran. `drydock sync` only copies
  the `statusLine` block inside `~/.claude/settings.json` (which tells
  Claude WHICH command to run); the actual personalization lives in
  `~/.config/ccstatusline/settings.json` which is OUT of the `~/.claude/`
  sync scope by design.

The detection happens in `lib/compose.sh:compose_files()` — runs on every
`drydock` invocation, no manual step required. To verify which overlays
are active for your current session, inspect:

```bash
cd ~/projects/yourproject
# As-if-invoked compose command (does not actually run docker):
DRYDOCK_HOME=~/.local/share/drydock bash -c '
  source $DRYDOCK_HOME/lib/common.sh
  source $DRYDOCK_HOME/lib/paths.sh
  source $DRYDOCK_HOME/lib/compose.sh
  export_compose_env $PWD
  compose_files $PWD
'
# Look for -f docker-compose.mcp-auth.yml and -f docker-compose.ccstatusline.yml
# in the output. Absence = overlay not activated (and that's correct if you
# don't use the corresponding tool).
```

## A skill in `.claude/skills/` isn't loading inside the container

**Symptom.** A skill you symlinked into your project's `.claude/skills/`
directory shows up in `ls -la` but Claude Code reports it as unavailable, and
`cd` into it inside the container fails with `No such file or directory`.

**Cause.** The symlink points to an absolute host path *outside* the project
tree (e.g. a shared skill repo: `.claude/skills/playwright →
/home/you/projects/skills/playwright`). drydock mounts your project at `/workspace`,
but it does not mount arbitrary external paths — so the symlink resolves on the
host but dangles inside the container.

**You'll see a pre-flight warning** on `drydock run` / `drydock shell` naming
the exact fix (one warning per target parent directory):

```
warn:  skill 'playwright' → '/home/you/projects/skills/playwright' is outside the project and not linked
       fix: drydock link --mirror /home/you/projects/skills
```

**Fix.** Run the suggested command, then relaunch:

```bash
drydock link --mirror /home/you/projects/skills
```

`--mirror` mounts the external tree at the **same absolute path** inside the
container, so the symlink resolves identically on both sides. This is the
[host-path-mirror pattern](links.md#the-host-path-mirror-pattern). The warning
is informational only — drydock never mounts the path implicitly; you opt in by
running the command (threat model A, [INV-7](../CLAUDE.md)).

## `drydock link` rejected my path

`drydock link` validates both the host source path and the optional custom
container target before writing anything. If your path is rejected, the table
below maps each rejection class to a cause and a fix.

### Host source rejections

| Rejection class | Example trigger | Resolution |
|---|---|---|
| 1. Path does not exist or is not a directory | `drydock link ~/projects/file.txt` | The host path must exist and be a directory. Symlinks to directories are followed (via `realpath`). |
| 2. Path contains metacharacters | Host path with `\|`, `:`, `"`, `\`, newline, or tab | These break the pipe-delimited list file, the Docker Compose volume spec, or the YAML overlay. Rename or use a path without these characters. |
| 3. Path is `$HOME` itself or an ancestor of `$HOME` | `drydock link ~` or `drydock link /home` or `drydock link /` | Mounting `$HOME` or its ancestors would expose everything under `~/` to the container — defeating credential isolation entirely. |
| 4. Path is a credential directory (or any subdirectory) | `drydock link ~/.ssh`, `drydock link ~/.aws/my-profile` | Separator-anchored guard: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker` and anything strictly under them are rejected. Defense-in-depth for [INV-1](../CLAUDE.md). Note: `~/.ssh-backup` is **not** rejected — the guard is anchored at the directory boundary, not prefix-only. |
| 5. Path is drydock or Claude state | `drydock link ~/.claude`, `drydock link ~/.engram-container` | `~/.claude*`, `~/.engram*`, and `~/.config/drydock` (including per-session `~/.claude-container-<disc>/` dirs) are rejected. These are load-bearing wildcards for [INV-2](../CLAUDE.md). |
| 6. Path is the current project directory | `drydock link ~/projects/current-project` | The project directory is already mounted at `/workspace`. Linking it again would shadow it. |

### Custom container target rejections

These fire only when you supply an explicit container path as the second argument
(`drydock link <host> <container-target>`).

| Rejection class | Example trigger | Resolution |
|---|---|---|
| 7a. custom target: not absolute | `drydock link ~/projects/foo relative/path` | Container targets must begin with `/`. |
| 7b. custom target: filesystem root | `drydock link ~/projects/foo /` | Mounting over `/` would replace the container's root filesystem. |
| 7c. custom target: starts with `//` | `drydock link ~/projects/foo //etc/foo` | The kernel normalizes `//foo` to `/foo` at mount time, which would bypass all single-slash guards (e.g. let `//etc/foo` mount at `/etc/foo`). |
| 7d. custom target: contains `..` or `.` components | `drydock link ~/projects/foo /workspace-siblings/../etc` | Docker normalizes path components at mount time. `/../etc` → `/etc`, bypassing the system-dir guard. |
| 7e. custom target: shadows `/opt/drydock/hooks` | `drydock link ~/projects/foo /opt/drydock/hooks` | This is the hooks RO bind-mount ([INV-3](../CLAUDE.md)). A sibling mount over it would silently remove the read-only guardrail. See [security.md](security.md) and [docs/architecture.md](architecture.md). |
| 7f. custom target: under a system directory | `drydock link ~/projects/foo /etc/myapp`, `/bin/...`, `/usr/...` | First path component must not be `etc`, `bin`, `sbin`, `usr`, `lib`, `lib32`, `lib64`, `boot`, `root`, `opt`, `proc`, `sys`, `dev`, `run`, `var`, or `tmp`. Note: `home` is intentionally **not** in this list — `/home/<user>/projects/foo` is the [host-path-mirror pattern](links.md#the-host-path-mirror-pattern). |
| 7g. custom target: shadows `/workspace`, `/workspace-siblings`, `$HOME`, or drydock state | `drydock link ~/projects/foo /workspace/sub`, `/workspace-siblings` | These targets would shadow the primary project mount, the siblings parent directory, `$HOME`, or container state dirs (`~/.claude*`, `~/.engram*`, `~/.config/drydock`). |
| 8. Basename collision | Two different paths with the same `basename` | The default container target is `/workspace-siblings/<basename>`. Two siblings with the same basename would collide. Supply an explicit `<container-target>` for one of them, or use `drydock unlink` on the conflicting entry first. |
| 8. Container target collision | Two entries share the same custom target | Docker Compose would silently keep only one mount. Assign distinct container targets. |

**Cross-references**: credential guard rationale → [security.md](security.md);
hooks guard rationale → [architecture.md](architecture.md#inv-3-and-the-link-guard);
host-path-mirror pattern → [docs/links.md](links.md#the-host-path-mirror-pattern).

## `drydock link --rw` errors

`drydock link --rw` adds deploy-key generation and SSH config wiring on top of the
standard link flow. The table below covers error classes specific to RW mode.

| Error class | Symptom / message | Resolution |
|---|---|---|
| **Deploy key missing** | A previously generated key was deleted from `~/.config/drydock/keys/` and the sibling was already unlinked | Re-run `drydock link --rw <path>`. A new ed25519 key pair is generated; you will need to add the new public key as a deploy key on GitHub for that repo. |
| **Basename collision (cross-project)** | `drydock link --rw` exits with "basename '<name>' is already used as an RW sibling in project '<other>'" | Two projects are trying to link siblings with the same basename (e.g. both link `~/projects/shared-lib`). Deploy keys are scoped by basename; sharing would create a key conflict. Use an explicit `<container-target>` with a unique basename for one of them, e.g. `drydock link --rw ~/projects/shared-lib /workspace-siblings/shared-lib-projectB`. |
| **Non-canonical remote URL** | `drydock link --rw` exits with "only canonical 'git@github.com:owner/repo[.git]' SSH URLs supported (HTTPS / non-GitHub remotes are out of scope)" | drydock routes the sibling's `remote.origin.url` through its managed SSH alias via container-only `url.insteadOf` (issue #89). Only `git@github.com:owner/repo[.git]` SSH URLs can be expressed in the rewritten form. HTTPS remotes (`https://github.com/…`) and non-GitHub hosts (GitLab, Bitbucket, self-hosted) are explicitly rejected. Use RO mode (`drydock link` without `--rw`) for siblings with unsupported remote URLs. |
| **Already linked as a different mode** | `drydock link --rw <path>` on a path already in the list with `flags=` (RO) | Remove the existing entry first: `drydock unlink <path>`, then re-link with `--rw`. Upgrading from RO to RW in-place is not supported. |
| **Partial-state self-heal** | Previous `drydock link --rw` was interrupted after key generation but before the list file was updated | Re-run `drydock link --rw <path>`. The key generation step is idempotent (existing key is reused); the list-write and SSH-config regen steps will complete. |
| **Stale aliased URL from v0.2.1** | `git fetch` on the host fails after upgrading; the sibling's `remote.origin.url` is `git@github.com-<sibling>:owner/repo.git` instead of canonical | Run `drydock run` once for the project — the startup migration restores aliased URLs to canonical automatically. Or re-run `drydock link --rw <path>` (auto-heals up-front). Post-#89, the link flow never aliases the URL in the first place. |

### git push fails inside the container after `drydock link --rw`

If `git push` inside the container fails with a permission error or host-key
warning for a linked RW sibling:

1. **Check `GIT_SSH_COMMAND` and `GIT_CONFIG_GLOBAL`** are set: `echo $GIT_SSH_COMMAND`
   should reference `~/.config/drydock/ssh-config-<primary>`; `echo $GIT_CONFIG_GLOBAL`
   should reference `~/.config/drydock/gitconfig-<primary>`. If either is empty, the
   SSH overlay did not activate — verify the deploy key file exists at
   `~/.config/drydock/keys/<sibling>_deploy`.
2. **Check the per-project gitconfig** contains the sibling's `url.insteadOf` block:
   `cat $GIT_CONFIG_GLOBAL` inside the container — should show a
   `[url "git@github.com-<sibling>:owner/repo.git"]` block with
   `insteadOf = git@github.com:owner/repo.git`. If the block is missing, the next
   `drydock run` will regenerate it (the file is rewritten atomically each
   invocation).
3. **Check the sibling's `.git/config` is canonical**: `cat <sibling>/.git/config`
   — the `remote.origin.url` should be `git@github.com:owner/repo.git` (canonical).
   Post-#89 drydock NEVER mutates this; the alias is applied in-memory via
   `url.insteadOf`.
4. **Check the managed SSH config** is mounted: `ls -la ~/.config/drydock/ssh-config-<primary>`
   inside the container — should exist and be readable.
5. **Check the deploy key is on GitHub**: the public key at
   `~/.config/drydock/keys/<sibling>_deploy.pub` must be added to the sibling repo's
   "Deploy keys" settings (with write access) on GitHub. drydock prints this reminder
   at `link --rw` time, but it requires a manual step on GitHub.

## drydock can't find DRYDOCK_HOME / compose file

The CLI resolves `DRYDOCK_HOME` by following the symlink at
`~/.local/bin/drydock` back to `<DRYDOCK_HOME>/bin/drydock`. If you moved the
drydock directory, re-create the symlink:

```bash
rm ~/.local/bin/drydock
ln -s /new/path/to/drydock/bin/drydock ~/.local/bin/drydock
```

Or set `DRYDOCK_HOME` explicitly in your environment.
