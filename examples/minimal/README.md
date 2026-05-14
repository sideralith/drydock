# drydock — minimal example

What's here: an empty project. The point — drydock works on ANY directory.

## TL;DR

```
drydock init .
drydock
```

## Run

```bash
drydock init .    # materializes .claude/settings.json from the template
drydock           # launches Claude Code inside the drydock container
```

## What this proves

- drydock works against a bare directory with no source code (the workspace IS the value).
- `drydock init` substitutes `$HOME` paths into `.claude/settings.json` deny lists.
- No project-specific configuration required to start.

## Next steps

- [Root README](../../README.md) — full usage guide
- [`../web-stack/`](../web-stack/) — multi-container DooD example
