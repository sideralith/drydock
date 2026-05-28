---
name: drydock-prs
description: "Open or update drydock pull requests with the two-branch dev/main model and conventional-commits CI gates. Trigger: opening/pushing/updating a drydock PR, choosing type:*/size:* labels, running CI gates locally before push."
---

## Activation Contract

Active when working in the `drydock` repo AND about to create a branch, commit, push, or open/update a PR against it. Do NOT apply to PR work on other repos.

## Hard Rules

- PRs target **`dev`**, NEVER `main`. `main` holds only released versions; each commit on `main` is a tagged release. A feature/fix PR against `main` is the wrong base branch.
- Branch naming: `type/short-description` (e.g., `feat/add-podman-support`, `fix/submount-detection-macos`). The type segment matches the commit type prefix.
- Conventional Commits on EVERY commit subject: `type(scope): subject`. Valid types: `feat | fix | docs | refactor | test | style | chore`. CI-enforced by `scripts/lint-commits.sh` (job: `Lint (commit-message)`).
- NO `Co-Authored-By` trailers — prohibited (CLAUDE.md §5). Soft norm, not CI-enforced.
- NEVER `--no-verify`. NEVER `--force` on shared branches.
- Three CI gates MUST be green; run locally before push:
  - `shellcheck bin/drydock lib/*.sh scripts/*.sh install.sh` → no errors
  - `shfmt -d bin/drydock lib/ scripts/ install.sh` → no diff
  - `scripts/test.sh` → all pass (NOT bare `bats test/` inside a drydock container — `/tmp` is `noexec` under INV-8; the wrapper redirects bats' tmpdir to an exec-allowed path)
  - Plus: `scripts/lint-commits.sh` → mirrors the commit-message gate locally
- Every PR should link the issue it closes (e.g., `Closes #N` in the body). The maintainer closes the linked issue manually at merge time because the merge target is `dev`, not the default branch — GitHub does not auto-close.
- Every Bash script MUST start with `set -euo pipefail` (CLAUDE.md §3). No `eval` over user input; no `bash -c "$untrusted"`.
- Every compose path MUST be parameterized (`${HOME}`, `${USER_NAME}`, `${DRYDOCK_*}`). No literal user-specific paths.

## Decision Gates

- Changed lines > 400? → Apply `size:l` AND either split per `chained-pr` OR negotiate `size:exception` with the maintainer BEFORE opening. Do not open a `size:l` PR silently.
- Touching an invariant (INV-1 … INV-8)? → Cite the INV explicitly in PR body, restate the rule, and justify why the change preserves it. Do NOT silently soften an invariant.
- Adding adversarial protection (socket-proxy, sandboxing, namespace remap, rootless Docker)? → INV-7 / §4 boundary push. Requires documented real-user demand AND maintenance-cost analysis in the PR body.
- PR is a release (`dev` → `main`)? → Maintainer-only path. Bumps `DRYDOCK_VERSION` in `lib/common.sh`, tags `vX.Y.Z`, publishes a GitHub Release. NOT a normal contribution route.
- Mutating host artifacts (sibling `.git/config`, host `~/.gitconfig`, `~/.ssh`, `~/.gnupg`)? → INV-1 violation. Route via drydock-owned files under `~/.config/drydock/` and container-only mechanisms (`url.insteadOf`, managed SSH config, `GIT_SSH_COMMAND`).

## Execution Steps

1. Branch from `dev`: `git checkout dev && git pull && git checkout -b type/short-description`.
2. Implement; commit each unit with conventional-commits format (see `work-unit-commits` for slicing).
3. Run all four gates locally:
   ```
   shellcheck bin/drydock lib/*.sh scripts/*.sh install.sh
   shfmt -d bin/drydock lib/ scripts/ install.sh
   scripts/test.sh
   scripts/lint-commits.sh
   ```
4. Push: `git push -u origin type/short-description`.
5. Open PR: `gh pr create --base dev --title "type(scope): subject" --body "..."`. Link the issue with `Closes #N`.
6. Apply labels: exactly one `type:*` + one `size:s|m|l|exception`.
7. Do NOT add `Co-Authored-By` to the PR body, commit trailers, or the eventual squash subject.

## Output Contract

Return: PR URL, base branch (MUST be `dev`), linked issue, applied labels (`type:*`, `size:*`), and confirmation that the four local gates passed. If you blocked at a Decision Gate (INV touched, adversarial-protection without justification, > 400 LOC without an exception), state which gate and why.

## References

- `CONTRIBUTING.md` — § How to submit a PR, § Code style, § Testing
- `CLAUDE.md` — § 3 (Bash/Compose/Docker conventions), § 4 (threat model boundary), § 5 (commit conventions), INV-1 … INV-8
- `scripts/test.sh`, `scripts/lint-commits.sh`
- `.github/workflows/ci.yml`
