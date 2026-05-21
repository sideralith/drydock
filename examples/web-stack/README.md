# drydock — web-stack example

What's here: postgres + python backend. Demonstrates drydock against a multi-container stack via DooD.

> Reminder: drydock's Docker socket mount is root-equivalent on the host.
> See [docs/security.md](../../docs/security.md) (INV-6) before running this against untrusted code.
> drydock is NOT adversarial isolation.

## TL;DR

```
cp .env.example .env && docker compose up -d && curl http://localhost:18080/health
```

## Run

```bash
cp .env.example .env      # demo credentials; edit for non-demo use
drydock                   # enter the drydock container

# inside the container:
docker compose up -d                       # boots postgres + backend via DooD
curl http://localhost:18080/health         # → {"ok": true}
curl http://localhost:18080/db             # → {"version": "PostgreSQL 16..."}
```

## What this proves

- Multi-container stacks run untouched inside drydock — same compose file works inside or out.
- drydock is the outer process; your project's compose is the inner process. They do not compete.
- Service-to-service networking (`backend` → `db`) uses compose's default bridge network — no host-mode required.

## Architecture

```
host
 └─ drydock container (Claude Code + your shell)
      └─ docker compose up (DooD via /var/run/docker.sock)
           ├─ db        (postgres:16, internal-only — NOT published)
           └─ backend   (python:3.12-slim, published on host port 18080)
```

## Caveats

- Postgres image is ~430MB on first pull — subsequent runs are cached.
- This example uses bridge networking, so it works on macOS Docker Desktop unmodified.
- Reminder: drydock's Docker socket mount is root-equivalent on host (see [docs/security.md](../../docs/security.md) INV-6). This example is for showing drydock works against multi-container stacks, NOT for adversarial isolation testing.
