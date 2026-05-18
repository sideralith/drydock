# Using engram with drydock

engram is an **optional** persistent-memory MCP server. drydock integrates it
only when it is already installed on the host — drydock does not install or
distribute engram. If you don't use engram, drydock works cleanly without it;
skip this document.

## What is engram

engram is a persistent-memory MCP server backed by SQLite. It gives AI agents
memory that survives across sessions — decisions, bug fixes, conventions — and
exposes them via a set of MCP tools (`mem_save`, `mem_search`, `mem_context`,
etc.).

- Source / releases: <https://github.com/Gentleman-Programming/engram>
- macOS install: `brew install gentleman-programming/tap/engram`

## How drydock detects engram

drydock activates the engram overlay only when **both** conditions are true:

1. The `engram` binary is on the host `$PATH`.
2. The host OS is Linux.

On a macOS host the `engram` binary is a native Mach-O executable — it cannot
run inside the Debian Linux container, so drydock treats it as absent regardless
of `$PATH`. See [§ macOS limitation](#macos-limitation).

Detection happens in `lib/compose.sh` (`engram_usable()`), evaluated on every
`drydock` invocation.

## Setup is automatic

You do **not** call `drydock setup` manually just to enable engram. The setup
command is auto-triggered by `run`, `build`, and `sync` (via `ensure_runtime_dirs`)
whenever the runtime directories are missing. After installing engram on the host,
the next `drydock run` picks it up automatically. You can also run `drydock setup`
explicitly if you want to force the initialization step.

In isolated mode (the default), `drydock setup` seeds `~/.engram-container/`
from the host's `~/.engram/` if it exists (point-in-time copy), or creates it
empty if not. In shared mode it skips this step — the host's `~/.engram/` is
mounted directly.

## Without engram

**Engram is optional.** drydock works cleanly without it:

- `drydock setup`, `drydock run`, `drydock build`, and `drydock sync` all
  work without engram installed.
- When engram is absent (or when the host is macOS), the engram volume overlay
  is not activated and the engram MCP server entry is removed from the
  container's `~/.claude-container.json` — Claude Code sees no startup errors.
- `drydock status` reports `engram: not detected (opt-in)` — not an error.

If you later install engram, the next `drydock run` picks it up automatically
(or run `drydock setup` explicitly).

## Shared vs isolated mode

By default, drydock gives the container its own engram DB (`~/.engram-container/`,
isolated mode). This prevents SQLite lock contention between a host session and
a container session.

**Opt-in to shared mode** (host and container share one DB):

On a native Linux host, the interactive installer (`install.sh` run in a terminal)
will ask whether to enable shared mode and create the sentinel automatically.
On WSL2 and macOS the installer does not show this prompt — shared mode is
force-downgraded to isolated there because `fcntl` locks are unreliable (INV-5
in [CLAUDE.md](../CLAUDE.md)); those users use the manual `touch` + `DRYDOCK_ENGRAM_SHARED=force`
route below.

To enable it manually:
```bash
mkdir -p ~/.config/drydock
touch ~/.config/drydock/engram-shared
```

Remove the file to return to isolated mode.

**Safety gate**: on WSL2 and macOS hosts, POSIX file locks over the
host↔container bind-mount layer are unreliable. drydock automatically downgrades
shared mode to isolated on these hosts and emits a warning. To override:
`DRYDOCK_ENGRAM_SHARED=force drydock run` (bypasses the safety check — the
sentinel must still be present; `=force` alone is a no-op). You accept the risk
of SQLite WAL corruption if host and container Claude write concurrently.

For the architectural rationale (SQLite WAL `fcntl` lock semantics, WSL2 9P
layer, Docker Desktop VM boundary): see [architecture.md](architecture.md) § "engram (optional)".

## Migrating between modes

**Isolated → shared (lossy without preparation).** Any memories accumulated in
`~/.engram-container/` won't automatically appear in the shared `~/.engram/`.
Before switching, export and import the isolated-mode snapshot:

```bash
# Inside the container (or on host, targeting the container DB):
engram export ~/engram-snapshot.json
# On the host:
engram import ~/engram-snapshot.json
```

Then create the sentinel (or let the installer do it) to switch to shared mode.

drydock does **not** provide a migration tool. If you skip this step, isolated
container memories are inaccessible in shared mode — the `~/.engram-container/`
directory is orphaned but not deleted, so you can import from it later.

**Shared → isolated** is safe: `drydock setup` re-seeds `~/.engram-container/`
from the current `~/.engram/` (a fresh point-in-time copy). Memories saved
during shared-mode sessions are already in `~/.engram/` and will be in the
seed copy.

> **Note on `engram sync` vs `engram export/import`:** these are two different
> mechanisms. `engram sync [--import]` is the chunk-bridge for **ongoing
> isolated-mode bridging** (moving chunks between sessions incrementally).
> `engram export <file>` / `engram import <file>` produce a **full JSON
> snapshot** and are the correct tool for mode migration.

## macOS limitation

On macOS, `engram` ships as a native Mach-O binary
(`brew install gentleman-programming/tap/engram`) and the DB directory can be
bind-mounted. However, the macOS binary cannot run inside the Debian Linux
container. drydock v0.1.0 treats macOS as engram-effectively-absent for the
container; future releases may ship a Linux engram in the image or bridge via
its HTTP API.

For the two concrete future paths, see [architecture.md](architecture.md) § "macOS limitation and future paths".

## Memories diverge (isolated mode)

The container has its own engram DB (`~/.engram-container/`). Memories saved
inside the container stay in the container's DB; memories saved on the host
stay in the host's DB. They do **not** auto-sync between host and container.

This is intentional — divergence prevents SQLite contention when running host
Claude and container Claude concurrently.

Consolidate manually when you want (see [§ Consolidating memories](#consolidating-memories)).

## Updating engram

Engram's binary at `~/.local/bin/engram` is shared between host and container
(the `~/.local/` mount is RW), but its plugin metadata in
`~/.claude/plugins/cache/engram/` is separate between host and container.
Updating from inside the container leaves the new binary on host with stale
plugin metadata on host — a skew. Correct recipe:

```bash
# on host:
gentle-ai update engram        # or the canonical upgrade path for your installer
drydock sync                   # sync metadata host → container
```

## Consolidating memories

Memories saved in host Claude stay on host. Memories saved in container Claude
stay in the container's DB. They do **not** auto-sync. Consolidate manually when
you want:

```bash
# from whichever side has the memories you want to move:
engram export ~/engram-snapshot.json
# on the destination side:
engram import ~/engram-snapshot.json
```

## Troubleshooting

See [troubleshooting.md](troubleshooting.md) — the "Engram returns 'no memories'
inside container" section covers common failure modes. For shared vs isolated mode
and the migration recipe, see [§ Migrating between modes](#migrating-between-modes)
above.
