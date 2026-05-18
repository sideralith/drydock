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
| drydock deny policy (`permissions.deny` + `hooks.SessionStart`) | image-baked managed-settings (`/etc/claude-code/managed-settings.d/`) — update via `drydock build` | N/A — applied at highest precedence, not overridable from project `settings.json` |
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

Engram's binary at `~/.local/bin/engram` is shared (mount RW), but its plugin
metadata in `~/.claude/plugins/cache/engram/` is separate between host and
container. Update from container leaves the new binary in host with stale
plugin metadata in host → skew. Correct recipe:

```bash
# on host:
gentle-ai update engram        # or canonical upgrade path
drydock sync                   # sync metadata host → container
```

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

Memories saved in host Claude (any project) stay on host. Memories saved in
container Claude (any project) stay in the container's DB. They do **not**
auto-sync. Consolidate manually when you want:

```bash
# from whichever side has the memories you want to move:
engram export ~/engram-snapshot.json
# on the destination side:
engram import ~/engram-snapshot.json
```

## Mental model

- **`~/.local/`** = **shared toolchain**. Source of truth = host. Update on
  host, container picks up.
- **`~/.claude/`, `~/.claude.json`, `~/.engram/`** = **isolated workspace**.
  The container is a **reversible playground**; the host is **canonical**.
- When in doubt: change on host, then `drydock sync`, then restart the
  container session.
