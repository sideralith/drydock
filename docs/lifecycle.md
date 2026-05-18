# Plugin & binary lifecycle — where to update what

The split-storage architecture (see [architecture.md](architecture.md)) means
different things land in different places. Read this once so you know the
right place for each action.

## Map: who writes where

| Action | Writes to | Shared host ↔ container? |
|---|---|---|
| Update binaries: `gentle-ai`, `claude`, `engram`, `gga`, `uv`, `node` | `~/.local/` | **YES** — mount RW |
| `/plugin install <x>` inside Claude | `~/.claude/plugins/` | **NO** — separate (`~/.claude-container/plugins/`) |
| Create/edit skill in `~/.claude/skills/` | `~/.claude/skills/` | **NO** — separate |
| Edit `~/.claude/CLAUDE.md` or `settings.json` (global) | `~/.claude/` | **NO** — separate |
| Onboarding flags, "seen hints", project registry, MCP servers, OAuth | `~/.claude.json` | **NO** — separate (`~/.claude-container.json`) |
| Edit `~/.claude/hooks/` | blocked from container (RO overlay) | host-only |
| drydock guardrail policy (`permissions.deny` git + OS safety, `hooks.SessionStart`, `hooks.PreToolUse` destructive-command hook) | image-baked managed-settings (`/etc/claude-code/managed-settings.d/`) — update via `drydock build` | N/A — applied at highest precedence, not overridable from project `settings.json` |
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

- **From container**: stays only in `~/.claude-container/plugins/`. Host
  doesn't know. Perfect for trying plugins without committing to them.
- **From host**: stays only in `~/.claude/plugins/`. Container doesn't see it
  until `drydock sync`.
- **No automatic promote**. If a plugin you tested in the container convinces
  you, do `/plugin install foo` on host too.

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
- When in doubt: change on host, then `drydock sync`, then restart the
  container session.
