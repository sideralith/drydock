# Plugin & binary lifecycle — where to update what

The split-storage architecture (see [architecture.md](architecture.md)) means
different things land in different places. Read this once so you know the
right place for each action.

## Map: who writes where

| Action | Writes to | Shared host ↔ container? |
|---|---|---|
| Update binaries: `gentle-ai`, `claude`, `engram`, `gga`, `uv`, `node` | `~/.local/` | **YES** — mount RW |
| `/plugin install <x>` inside Claude | `~/.claude/plugins/` | **NO** — separate (`~/.claude-container-<disc>/plugins/`, per-session) |
| Create/edit skill in `~/.claude/skills/` | `~/.claude/skills/` | **NO** — separate |
| Edit `~/.claude/CLAUDE.md` or `settings.json` (global) | `~/.claude/` | **NO** — separate |
| Persist plugin config / MCP entries across container sessions | `~/.config/drydock/claude-overlay/` (mirrors `~/.claude/`; files are copied into the per-session dir on every `drydock run` before Claude starts — host→container only, unidirectional) | host-only — applied at seed time |
| Onboarding flags, "seen hints", project registry, MCP servers, OAuth | `~/.claude.json` | **NO** — separate (`~/.claude-container-<disc>.json`, per-session) |
| Edit `~/.claude/hooks/` | blocked from container (RO overlay) | host-only |
| drydock guardrail policy (`permissions.deny` git + OS safety, `hooks.SessionStart`, `hooks.PreToolUse` destructive-command hook) | image-baked managed-settings (`/etc/claude-code/managed-settings.d/`) — update via `drydock build` | N/A — applied at highest precedence, not overridable from project `settings.json` |
| `drydock link` / `unlink` | `~/.config/drydock/links/<project>.list` (host-only; pipe-delimited `host\|target\|flags` per line) | host-only — overlay regenerated per launch |
| `drydock link --rw` — per-sibling deploy key (first link only; reused idempotently on re-link; **left on disk at unlink** — see dual-hint message) | `~/.config/drydock/keys/<sibling-basename>_deploy{,.pub}` | host-only — mounted `:ro` as a directory into the container |
| `drydock link --rw` / `unlink` — managed SSH config (regenerated atomically: mktemp + mv + chmod 600 on every link/unlink that touches an RW sibling) | `~/.config/drydock/ssh-config-<primary>` | host-only — RO bind-mounted into the container |
| `drydock link --rw` — sibling `remote.origin.url` rewritten from canonical GitHub remote to alias (`github.com-<sibling>`); **restored to canonical by `drydock unlink`** | sibling repo `.git/config` at `$SIBLING_DIR` | **YES** — sibling is mounted; the mutation is visible inside the container |
| Edits to `.claude/settings.json` of a project | repo at `$PROJECT_DIR` | **YES** — same mount |
| engram memories (`mem_save`) | `~/.engram/engram.db` | **NO** — separate DBs |

## Practical rules

### Update binaries → do it on HOST

```bash
# on host:
gentle-ai self-update          # or whatever upgrade command
# container picks up the new version via ~/.local/ mount automatically
```

Why not from container? Some installer flows (`curl | sh`, pnpm/npm scripts,
`uv` packages) write to `~/.config/`, `~/.cache/`, `~/.bashrc`, system PATH —
paths NOT mounted from host. Update from container = partial update, container
`/tmp` pollution, doesn't persist.

### Engram update gets a specific recipe

See [engram.md](engram.md#updating-engram) for the correct update recipe
(binary is shared, plugin metadata is not — updating from inside the container
causes skew).

### Plugins from Claude (`/plugin install foo`)

- **From container**: stays only in `~/.claude-container-<disc>/plugins/`
  (the per-session dir). Host doesn't know. The per-session dir is discarded
  when GC'd by `gc_orphan_session_dirs` — container-installed plugins do NOT
  persist across sessions unless promoted to the host or the overlay.
- **From host**: stays only in `~/.claude/plugins/`. Container doesn't see it
  until `drydock sync`.
- **No automatic promote**. If a plugin you tested in the container convinces
  you, do `/plugin install foo` on host too.
- **Persist a plugin's config across container sessions**: copy the config file
  into `~/.config/drydock/claude-overlay/` under the same relative path it has
  in `~/.claude/`. drydock copies it into every new session dir at startup.
  See [troubleshooting.md § "Container config edits revert every run"](troubleshooting.md#container-config-edits-revert-every-run-plugin-config-mcp-entries-settings).

### New skills

Same pattern. Create on host (canonical) + `drydock sync` so the container
picks it up. Or create in a project's `.claude/skills/` — those are mounted
with the project tree and visible immediately (project-scoped skills are
additive to global ones).

### Engram memories

See [engram.md](engram.md#consolidating-memories) for the manual
export/import recipe (host and container DBs do not auto-sync).

## Mental model

- **`~/.local/`** = **shared toolchain**. Source of truth = host. Update on
  host, container picks up.
- **`~/.claude/`, `~/.claude.json`, `~/.engram/`** = **isolated workspace**.
  The container is a **reversible playground**; the host is **canonical**.
  For Claude config specifically, "reversible" now means "discarded on session
  end" — each session gets its own per-session dir, reaped by
  `gc_orphan_session_dirs` after the session exits.
- When in doubt: change on host, then `drydock sync`, then restart the
  container session.
