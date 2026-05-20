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
- **Self-modification of hook scripts** — the hooks directory is RO
  bind-mounted; the agent can read its guardrails but not edit them.
- **Weakening of the `permissions.deny` block or hook entries** —
  drydock's agent policy is delivered as Claude Code managed-settings drop-ins baked
  into the image at `/etc/claude-code/managed-settings.d/`. The files are root-owned;
  the non-root container user cannot write to `/etc/`. Claude Code loads managed
  settings at highest precedence and the rules cannot be weakened from project-level
  settings. The protection is structural, not advisory — it is not possible for an
  agent to overwrite these policy files from inside the container.
- **Damage to other projects under `~/`** — only `$PROJECT_DIR` is mounted by
  default; sibling projects are not visible unless explicitly added via
  `drydock link`. Linked siblings mount read-only (`:ro`) — writes are
  blocked at the filesystem level, not just by policy.
- **Credential read inside a linked sibling** — three cooperating layers
  protect credentials in any linked sibling. See the
  [dedicated walkthrough below](#credential-protection-in-linked-siblings).
- **Destructive commands (accident class)** — see the section below.

## Credential protection in linked siblings

When a sibling project is mounted via `drydock link`, three cooperating layers
defend against credential exposure. They are ordered outside-in — each layer
catches what the previous one missed.

### Layer 1 — link-time host-source guard

Before any mount is written, `lib/commands.sh` rejects host paths that **are**
credential directories or anything strictly under them:

- `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker` (and any subdirectory)

The guard uses separator-anchored prefix matching so that `~/.ssh-backup` is
**not** rejected (a common false-positive risk with naive prefix checks). If the
path passes the guard, it is not a credential dir — credentials never get linked
in the first place. This is defense-in-depth for [INV-1](../CLAUDE.md).

### Layer 2 — read-only bind mount

Every linked sibling is mounted `:ro`. Even if a sibling's tree happens to
contain a `.env` file with database credentials or a `.pem` key, the container
cannot write to it. Writes are blocked at the OS layer by the bind-mount flag —
not by policy alone — so this protection holds regardless of whether the agent
attempts an explicit write or a tool that opens a file for writing.

### Layer 3 — `//**/`-anchored deny rules in `00-secrets.json`

Claude Code's permission engine evaluates the deny rules in
`templates/managed-settings.d/00-secrets.json` (image-baked, root-owned, not
overridable from project settings) **before** any tool executes. The credential
patterns use root-anchored `//**/<path>` globs:

```
Read(//**/.ssh/**)
Read(//**/.aws/**)
Read(//**/.gnupg/**)
Read(//**/.kube/**)
Read(//**/.docker/config.json)
Read(//**/.claude/.credentials.json)
Read(//**/.claude-container*/.credentials.json)
Read(__HOME__/.config/drydock/**)
# Edit(...) and Write(...) variants present for every entry — see 00-secrets.json
```

The `//**/` prefix matches **at any mount depth**: a `.ssh/` directory inside a
sibling at `/workspace-siblings/other-repo/.ssh/` is denied by the same rule
that would deny `~/.ssh/` on the primary project or anywhere else in the
filesystem.

**`__HOME__`-anchored entry.** `__HOME__/.config/drydock/**` uses an
`__HOME__`-anchored pattern (resolved to `/home/<user>/.config/drydock/**`
at image build time) rather than the root-anchored `//**/` form. This is
intentional: drydock-state paths only need to be denied under the container's
`$HOME`, not at arbitrary mount depths. The distinction mirrors the threat
model — credential files like `.ssh/` can appear anywhere in a sibling tree,
but drydock-state paths are only meaningful under `$HOME`.

**Read/Edit/Write symmetry.** All three verbs are denied for each credential
path — not just `Read`:

- `Read` prevents exfiltration.
- `Edit` and `Write` prevent accidental overwrite or corruption of credential
  files (threat model A, [INV-7](../CLAUDE.md)) — for example, an agent that
  tries to "update" a `.env` file it mistook for project config cannot silently
  corrupt a `.docker/config.json` that happens to live in the sibling tree.

**The `.claude-container*` glob is load-bearing.** It covers both the legacy
single-session `.claude-container/` directory and the per-session
`.claude-container-<disc>/` directories introduced by concurrent-sessions
support in v0.2.0 (see [INV-2](../CLAUDE.md)). Without the `*` glob, per-session
credential files (`.claude-container-<disc>/.credentials.json`) would be
uncovered — a gap identified and closed in the v0.2.0 re-verify.

### RW links and the keys directory — expanded surface

When `drydock link --rw` is used, drydock mounts the **entire**
`~/.config/drydock/keys/` directory `:ro` into the container. This is necessary
so the managed SSH config can reference any sibling deploy key by absolute path.
Previously (RO-only links) only the primary project's deploy key was mounted.

**Surface expansion.** The blast radius of an accidental Bash read command goes
from one key file to all deploy keys under `~/.config/drydock/keys/`. A
command like `cat ~/.config/drydock/keys/*_deploy` to debug something would
expose every sibling's private key in one shot.

**Defense-in-depth.** `00-secrets.json` (image-baked, root-owned) now includes
`Bash(...)` deny patterns covering the most common read commands (`cat`, `less`,
`more`, `head`, `tail`, `od`, `xxd`, `strings`, `bat`) targeting that path.
`bat` is explicitly covered because drydock's global agent convention prefers
`bat` over `cat`; failing to deny it would leave a normal-tool-usage hole.
Under Threat Model A (accidents — INV-7) this is sufficient: the deny rules
block inadvertent tool invocations. They do NOT block every conceivable
reading mechanism (`python`, `dd`, `awk`, `perl`, custom scripts, etc.) — a
determined adversary is explicitly out of scope.

**If you need stricter isolation:** do not enable the SSH overlay
(`docker-compose.ssh.yml`). RO-only links mount no key material at all.

### Upstream enforcement caveat

drydock ships the deny rules; **Claude Code is the enforcer**. If an agent
bypasses Claude Code's permission gate — via a raw Docker socket call, a
sub-shell not mediated by the Bash tool, or a base64-obfuscated tool invocation
— the deny rules do not fire. This is the same non-goal stated in [INV-7](../CLAUDE.md)
for destructive commands: drydock defends against accidents, not against an
adversarial agent that is actively trying to circumvent its own permission layer.

## Destructive-command guardrail layer (v0.2.0+)

drydock ships a two-tier defense against accident-class destructive commands.
Both tiers are image-baked and tamper-proof.

### Tier 1 — declarative deny (`permissions.deny`)

Most rules ship as `Bash(...)` wildcard patterns in root-owned managed-settings
drop-ins. Claude Code evaluates the deny list **before** any hook runs —
matching commands are blocked at the framework level before execution.

| Drop-in file | What it covers |
|---|---|
| `10-git-safety.json` | Protected-branch delete/rename (8 branches × 6 flag forms), history-rewrite (`push --mirror`, `filter-branch`, `update-ref -d`), remote-delete refspecs, GitHub destructive ops (`gh repo delete/archive/transfer`, `gh release delete`, `gh api DELETE refs/heads/*`) |
| `30-os-safety.json` | `rm -rf` to system paths, `find / -delete`, disk-destruction tools (`dd`, `mkfs`, partition tools, `wipefs`), sudo + destructive verb, package-manager purge/remove, kernel module teardown, firewall flush, `crontab -r`, `kill -9 1`, `docker system/volume prune`, redirect to block devices or critical `/etc` files, `docker run --privileged` / `docker run -v /:` (host-root bind) |

Deny patterns use strict word-boundary shapes to prevent false positives.
For example, `git branch --delete main` is blocked but `git branch --merged`
and `git checkout fix/main-bug` are not.

### Tier 2 — `PreToolUse` hook

A small Bash hook (`drydock-block-destructive.sh`) handles the five rule
classes that the deny mechanism cannot express — cases requiring multi-token
AND/OR logic or anchored substring matching:

| Rule | Blocked example | Allowed example |
|---|---|---|
| A1 — ssh to production host | `ssh user@prod.example.com` | `ssh user@dev.example.com` |
| C12 — fork bomb | `:() { :|:& };:` | `bash -c 'echo hello'` |
| C17 — `rm` of `.` or `.git` | `rm -rf .` | `rm -rf ./tmp` |
| C18 — `rm` of parent traversal | `rm -rf ../sibling` | `rm -rf ./dist` |
| C20 — curl/wget pipe to shell | `curl https://x.com/i.sh \| bash` | `curl -o file.sh https://x.com/i.sh` |

The hook is wired by `40-guardrails-hook.json` (also image-baked) as a
`PreToolUse` handler with matcher `"Bash"` — it only runs for Bash tool calls.
The script reads the full command string on stdin and applies regex checks.

**Docker exec/run coverage.** The hook checks the full command string
regardless of a leading `docker exec <ctr>` or `docker run [opts] <image>`
prefix — dangerous substrings (`rm -rf`, `:(){:|:&};:`, `curl … | bash`, etc.)
are present in the full string whether or not the command is docker-wrapped.
This provides accident-class coverage for simple docker-wrapped invocations.

**Hard boundary (non-goal per INV-6 and INV-7).** Command-string inspection
raises the accident floor; it is NOT an adversarial ceiling. A raw Docker
socket call, the Docker SDK, a base64-obfuscated payload, or `docker exec`
reading the command from a file all bypass string inspection. Adversarial
container-escape via the Docker socket remains a documented non-goal —
the socket is root-equivalent by design and drydock's threat model is
accidents, not adversaries. See "What drydock does NOT protect against" below.

### Known limitations

- **B3 non-origin remotes.** `Bash(git push origin :*)` blocks refspec-delete
  for `origin` only. `git push upstream :main` (non-origin remote) is not
  covered. Under threat model A this is an acceptable documented gap — pushing
  a delete refspec to a non-origin remote is not an accident-shaped action in
  typical workflows.
- **C7 sudo rules are defense-in-depth only.** The default drydock image does
  not install `sudo` (verified — no `sudo` in the Dockerfile apt list;
  `no-new-privileges:true` would make it a no-op anyway). The `sudo + verb`
  deny entries in `30-os-safety.json` are dead weight against the default
  image. They are kept as a safety net for derived images where a user adds
  `sudo` — they do not protect against bypassing the deny layer itself.
- **Force-push via `+`-refspec not in deny matrix.** `git push origin +main`
  (force-push using a `+`-prefixed refspec rather than `--force`) is not
  currently covered by the deny layer. Under threat model A, using a
  `+`-refspec is not an accident-shaped action in typical workflows, but it
  is a documented gap. The protected-branch hooks (B4/B9) cover flag-based
  force-push forms; `+`-refspecs would require a separate pattern class.
- **Hook `rm` anchoring does not catch shell-metacharacter-glued targets.**
  The C1-residue, C17, and C18 hook rules use space as the token boundary
  before the target argument. A command like `$(rm -rf .)` or `rm${IFS}-rf .`
  would bypass the space-anchored regex. Accident-class typos do not produce
  these metacharacter-glued forms; this gap is documented for completeness
  under threat model A (accidents, not adversaries).

### If you have a personal `block-destructive.sh` hook

Previous drydock guidance suggested adding a personal
`~/.claude/hooks/block-destructive.sh` on your host. Since v0.2.0, drydock
ships its own guardrail hook (`drydock-block-destructive.sh`) image-baked and
wired automatically. **You can safely delete your personal
`~/.claude/hooks/block-destructive.sh`** and rely on the shipped version —
it covers the same rule classes plus docker-wrapped variants.

The two scripts coexist without conflict (different filenames, different mount
points), so there is no urgency. But the personal copy is now redundant.

## Container hardening defaults (v0.1.1+)

drydock auto-applies a hardening overlay (`docker-compose.hardening.yml`) that bounds
accident-class privilege and resource use. These defaults are anchored as **INV-8** in
`CLAUDE.md` — they are project invariants, not per-release polish.

| Defense | Effect | Opt-out |
|---|---|---|
| `cap_drop: [ALL]` + minimum `cap_add` | Privileged syscalls return EPERM rather than completing silently (e.g. `mount -o bind` requires `SYS_ADMIN`; raw-socket `bind` requires `NET_RAW`; cross-uid `ptrace` requires `SYS_PTRACE`) | `DRYDOCK_NO_HARDENING=1` (nuclear) |
| `security_opt: no-new-privileges:true` | A setuid-root binary (`su`, `mount`, `passwd` — present in the base image) cannot re-acquire dropped caps; the cap drop cannot be bypassed via SUID escalation | `DRYDOCK_NO_HARDENING=1` (nuclear) |
| `tmpfs /tmp` with `size=1g` (default) | Runaway loops writing to `/tmp` halt at 1G instead of filling the host's memory-backed tmpfs | `DRYDOCK_TMPFS_SIZE=<size>` (granular) or `DRYDOCK_NO_HARDENING=1` (nuclear) |

The `cap_add` set — `DAC_OVERRIDE`, `CHOWN`, `FOWNER`, `SETUID`, `SETGID` — is the documented
minimum bounding set. With the container running as a non-root user and no file-cap'd binaries
in the image, these caps do NOT sit in the running process's effective set — they remain in the
bounding set so file-mode / ownership / uid-context operations function when invoked by tooling
that genuinely needs them (rsync `-a` preserving modes and uids, npm/pnpm post-install scripts
chmod'ing under `node_modules`, future file-cap'd binaries). Each entry has an inline rationale
in `docker-compose.hardening.yml`. Adding a cap MUST come with a new inline comment; removing
one requires reopening INV-8.

To opt out of all hardening for a single invocation:

```sh
DRYDOCK_NO_HARDENING=1 drydock
```

To tune the tmpfs size (granular — hardening otherwise active):

```sh
DRYDOCK_TMPFS_SIZE=4g drydock
```

These defenses defeat **accidents**, not adversaries. The Docker socket mount remains
root-equivalent (see below) — INV-8 is additive defense in depth, not a replacement for INV-6.

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
  drydock — though drydock's managed-settings layer does add `Read(~/.ssh/**)` etc.
  as image-baked policy that applies automatically to every container session).
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
