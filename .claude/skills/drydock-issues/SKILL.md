---
name: drydock-issues
description: "Create or triage drydock GitHub issues with the project's typed conventions. Trigger: filing a bug or feature request against drydock, choosing labels, or checking threat-model fit (INV-6/INV-7) before opening."
---

## Activation Contract

Active when working in the `drydock` repo AND about to create, update, or triage a GitHub issue against it. Do NOT apply to issue work on other repos.

## Hard Rules

- Use one of two templates: `.github/ISSUE_TEMPLATE/bug_report.yml` or `.github/ISSUE_TEMPLATE/feature_request.yml`. Do not open blank issues.
- Bug template auto-applies the `bug` label; feature template auto-applies `enhancement`. Do NOT add them manually.
- No `status:*` labels exist in this repo. Do NOT add `status:approved`, `status:needs-review`, etc. — that workflow belongs to agent-teams-lite, not drydock.
- GitHub Issues is the ONLY intake channel for v0.1.0. No Discord, no Discussions, no mailing list. Do NOT redirect users to "Discussions".
- Bug body MUST include: command (full invocation with every flag), reproduction steps, expected behavior, actual behavior, environment (`drydock` version, `docker --version`, OS + version). The YAML's `validations: required: true` blocks submission otherwise.
- Feature body MUST include: problem (concrete friction first, NOT the solution), why it matters (who hits this, how often, what it costs), proposed approach (rough user-facing sketch). The `constraints` field is where INV references and adversarial-protection justification go.
- No `Co-Authored-By` trailers in issue body (CLAUDE.md §5).
- Issue title: one line describing what is broken in which command (e.g., `drydock build fails on macOS 14 with "no such file" error`).

## Decision Gates

- Reporting that the host Docker socket is root-equivalent on the host? → That is INV-6 by design, NOT a vulnerability. Close as `wontfix` or redirect to `docs/security.md`; do not file as a bug. The bug template's header already states this.
- Proposing adversarial-protection (socket-proxy, gVisor, user-namespace remap, rootless Docker)? → Threat model is A (INV-7 / §4). MUST justify against a concrete real-user use case AND quantify maintenance cost on contributors. Put both in the `constraints` field. Speculative interest or release cadence do NOT reopen the boundary.
- Touching `~/.ssh` / `~/.gnupg` mounts, or mutating host artifacts like the sibling's `.git/config` or `~/.gitconfig`? → INV-1 violation by default. Surface the conflict in the issue body and reference the affected sub-rule.
- Bug vs feature ambiguity? → "broken / surprising / wrong behavior" → bug. "new capability or improvement to existing one" → feature.

## Execution Steps

1. Search duplicates: `gh issue list --search "<keywords>"`.
2. Pick template; fill ALL `validations: required: true` fields.
3. Create via `gh issue create --template bug_report.yml` (or `feature_request.yml`) — or the web UI.
4. Do NOT manually re-apply the auto-label (`bug` / `enhancement`).
5. Add a `size:*` label only if scope is already known (typically a maintainer applies this on triage).
6. If the issue touches an invariant, cite it explicitly as `INV-N` (e.g., `INV-2`).

## Output Contract

Return: issue URL, title, auto-applied label, and any cited `INV-N`. If you chose NOT to open the issue (because it is an INV-6 misreport, an INV-7 boundary push without justification, or a duplicate), state which gate blocked it and why.

## References

- `.github/ISSUE_TEMPLATE/bug_report.yml`
- `.github/ISSUE_TEMPLATE/feature_request.yml`
- `CONTRIBUTING.md` — § How to file an issue, § Where to discuss
- `CLAUDE.md` — § 4 (threat model boundary), § 5 (tracking & contribution), INV-1, INV-6, INV-7
- `docs/security.md`
