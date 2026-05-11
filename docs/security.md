# Security boundaries — be honest with yourself

drydock's threat model is **defense against agent accidents, not against an
adversarial agent**. Read this so you don't develop a false sense of security.

## What drydock DOES protect against

- **`rm -rf ~/.ssh` typo** — the path isn't mounted into the container. The
  agent literally cannot see it.
- **`rm -rf /` accidental** — the container's `/` is the container's
  ephemeral root, not the host's. Blast radius = the container.
- **Read of `~/.aws/credentials`, `~/.gnupg/`, `~/.kube/`, etc.** — not
  mounted.
- **Self-modification of `~/.claude/hooks/block-destructive.sh`** — RO
  overlay; the agent can read its guardrails but not edit them.
- **Damage to other projects under `~/`** — only `$PROJECT_DIR` is mounted;
  sibling projects aren't visible.

## What drydock does NOT protect against

- **Adversarial agent using the Docker socket** — a process with
  `/var/run/docker.sock` access can run
  `docker run -v /:/host --privileged alpine sh` and then it's root on the
  host. The socket is root-equivalent. drydock mounts the socket because
  that's what makes `make shell-api` / `docker exec` work; the trade-off is
  explicit.
- **Agent committing nonsense to the project tree** — `$PROJECT_DIR` is
  mounted RW. The agent can write anything in it. (That's the point — it
  needs to do its job.) Use git review discipline.
- **Agent reading anything inside `$PROJECT_DIR`, including `.env`** —
  mitigated, not prevented, by a `Read(.env)` deny in your global
  `~/.claude/settings.json` (you set that up yourself; it's not part of
  drydock — though `drydock init` does add `Read(~/.ssh/**)` etc. to each
  project's `.claude/settings.json`).
- **Network exfiltration** — the container shares the host's network
  namespace (`network_mode: host`). The agent can make arbitrary outbound
  connections.

## If you need adversarial-resistant isolation

drydock as-is is the wrong tool for an adversarial threat model. Layer one of
these in front of the Docker socket and restrict the API surface:

- [`Tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy)
  — env-var-controlled allowlist of Docker API endpoints. Configure it to
  allow `containers/exec`, `containers/logs`, `containers/json` and deny
  `containers/create` with privileged/host-mount/network options.
- [`cetusguard`](https://github.com/cetusguard/cetusguard) — more expressive
  filtering.

Or go heavier: run the agent in a VM (no host kernel sharing), or use
gVisor/Kata containers (syscall isolation). All of these are out of scope for
drydock's current design — they're on the roadmap as opt-in for users with
that threat model.

## The honest framing

drydock **raises the cost of an accidental mistake** by an unsupervised AI
agent. It does **not guarantee impossibility** of harm. Use it the way you'd
use a circuit breaker — it stops the common failure mode, it doesn't make
the wiring adversary-proof.
