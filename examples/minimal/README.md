# drydock — minimal example

What's here: an empty project. The point — drydock works on ANY directory, with
no per-project setup.

## TL;DR

```
drydock
```

## Run

```bash
drydock           # launches Claude Code inside the drydock container
```

## What this proves

- drydock works against a bare directory with no source code (the workspace IS the value).
- No project-specific configuration required to start — drydock's safety policy
  ships image-baked (`/etc/claude-code/managed-settings.d/`, INV-3) and applies
  to every project automatically.
- `.claude/settings.json` is optional; Claude Code creates it lazily if/when you
  add MCP servers, hooks, or permissions through normal Claude Code commands.

## Next steps

- [Root README](../../README.md) — full usage guide
- [`../web-stack/`](../web-stack/) — multi-container DooD example
