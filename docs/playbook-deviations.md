# Playbook deviations

Where this template departs from [The AI-native SDLC playbook](https://claude.com/resources/articles/the-ai-native-sdlc-playbook) (read 2026-11-18), and why.

This file records the template's own history. Bootstrap removes it from new projects. It is the one place for departures from the **playbook**. Departures from an intent's **plan** stay in that `plan.md`'s Deviations table. When an entry here leads to work, link the PR or intent in its Status, and don't delete closed entries: set their Status.

**Kinds of entry**
- **Deliberate:** a design choice the owner accepted. It holds until someone reopens it.
- **Gap:** something the playbook recommends that we don't do yet.
- **Slip:** our own process wasn't followed on a specific change. It's kept so that repeats show up; a slip that repeats goes into `CLAUDE.md`.

**Status values:** `accepted` (deliberate, no action), `open`, `planned` (with where), `fixed` (with the PR).

## Where we follow the playbook

For reference, so a gap isn't mistaken for the norm:

- **Artifacts:** each stage ends in a committed file: `intent.md`, `spec.md`, then `plan.md` (updated when the build departs from it), then a PR.
- **`CLAUDE.md`:** stays under a page, lists commands with their healthy output, and records mistakes made twice.
- **Hooks:** protected paths, no secrets in edits or commands, test-first on `fix/*` (`scripts/hooks/test-first.sh`), and format plus lint after edits.
- **Subagents:** `verifier` (fresh context, read-only), `simplifier`, `researcher`, `test-writer`. The `/sweep` command clears review comments and failing checks on Claude's PRs.
- **Review:** `REVIEW.md` has five passes (correctness, security, conformance, test adequacy, cost), Important and Nit severities and a cap of 5 nits. AI review is advisory: it never approves and never blocks, and only `ci-ok` is required.
- **Gates:** agent output arrives only as PRs and never goes straight to `main`. The agent never deploys to production.
- **Rollback:** a single automatic `revert` path, rehearsed for real: Cloud Run 11.5 s (M2 step 6b), GitHub Pages 27 s (M3, [`sandbox-node-static` run 44334822339](https://github.com/Jomaries777/sandbox-node-static/actions/runs/44334822339), to be recorded in `spikes/m3-results.md`, see PD-17).
- **Read-only judgment in CI:** the `report` job has Claude triage failed deploys.

## Deliberate

| ID | Playbook | This template | Why | Status |
|---|---|---|---|---|
| PD-1 | Separate people hold the product-owner, tech-lead, code-owner and release-manager gates ("A human team mate always makes this call"). | One owner holds every role. | One-owner projects. Intent 0001: gates "can be collapsed onto one person, but they cannot be skipped." | accepted |
| PD-2 | Branch protection requires code-owner approval. | Code-owner review is off. The ruleset needs 1 approval, last-push approval and resolved threads. The owner's own PRs merge through the PRs-only admin bypass (C4). | The bot can't be a code owner, so requiring it would block Dependabot patch auto-merges (0001 plan Deviations, 2026-11-15). | accepted |
| PD-3 | The production gate is a Claude Code hook: the release manager sets an approval, and the hook blocks the deploy without it. | The production gate is a GitHub Environment with a required reviewer and a branch policy. | Deploys run in CI, never inside a Claude session. A server-side reviewer can't be skipped from a laptop, and it's free on public repos. | accepted |
| PD-4 | Dev, then staging, then production. Rollback is rehearsed in staging. | Dev and production only, and production only for GitHub Pages. Rollback is rehearsed in throwaway sandbox repos. | $0 when idle, and Pages has one site. The sandboxes do staging's job for the template itself. | accepted |
| PD-5 | Deploy, status and rollback are MCP tools the agent can call, scoped per environment. | They are scripts that run only in CI (`scripts/deploy.sh`, `scripts/release.sh`). | Stricter: the agent has no deploy path at all. | accepted |
| PD-6 | Recurring Claude Security scans on the most capable model. | CodeQL, secret scanning with push protection, Dependabot and dependency review. | Claude Security needs Enterprise and paid usage. The free deterministic scanners cover what CI must enforce. | accepted |
| PD-7 | Accepting an `intent.md` triggers a non-interactive job that commits `spec.md` as a PR. | `/spec` and `/plan` are run interactively by the owner. | One owner; the volume doesn't justify automating it. | accepted |
| PD-8 | Production deploys are authorized by a named release manager. | The owner approves each production deploy in the GitHub UI, including deploys of the agent's own PRs. | Same as PD-1. | accepted |

## Gaps

| ID | Playbook | This template | Why | Status |
|---|---|---|---|---|
| PD-9 | Continuous evals: 20–50 real tasks run in CI on a schedule and on any change to `CLAUDE.md`, skills or hooks, and they gate those changes. Every incident adds one. | None. Changes to `CLAUDE.md`, skills and hooks are reviewed like code, but nothing regression-tests them. | Not in intent 0001's scope, and each run uses Pro quota. This is the largest gap. | open: needs its own intent, kept to a few cases within quota |
| PD-10 | Agent runs use their own identity, so logs separate agent actions from the engineer's. | A cloud Claude Code session not on the bot-relay environment pushes, opens PRs and merges as the owner. Bot identity works through `scripts/bot-relay.sh` (intent 0002). | The session was on the Default environment. Switching was refused because the bot-relay environment's name contains parentheses. | open: owner renames the environment, then the session switches |
| PD-11 | Stage 6, Maintain: σ control bands on a metric, read-only diagnosis at 2σ, a PR or pre-approved runbook at 3σ, findings written as `intent.md`. | Not built. | Milestone order. | planned: 0001 M4 (`maintain.yml`) |
| PD-12 | Leading and lagging metrics per stage, DORA measures, OpenTelemetry session export. | Defined in 0001 spec §7; nothing collects them yet, and no OpenTelemetry export is set up. | Milestone order. | planned: 0001 M4 (`sdlc-metrics.sh`) |
| PD-13 | "Gemini does the bulk work" is not a playbook rule; it's intent 0001's. Listed here because it changes who the build agent is. | Most of M2 and M3 was built by Claude Code in a cloud session; Antigravity re-runs are deferred. | No Antigravity and no bot key in cloud sessions. Recorded for M2 steps 1–2 in the plan; M3 went the same way. | open |

## Slips

| ID | Date | Change | What was skipped | Status |
|---|---|---|---|---|
| PD-14 | 2026-11-18 | template #45; sandbox `sandbox-node-static` #5, #6 | Plan mode was not used. | open: plan mode for the next changes (restore-check fix, Workers target) |
| PD-15 | 2026-11-18 | sandbox `sandbox-node-static` #6 | Merged before Claude's review ran. The review is skipped on drafts and the PR was merged right after it was marked ready. | open: wait for `claude-review` before merging |
| PD-16 | 2026-11-18 | sandbox `sandbox-node-static` #1–#3 (Dependabot majors) | Merged on the owner's word in chat, with green CI but no review recorded on the PR. | open: closes with PD-10, when the owner reviews and merges in GitHub |
| PD-17 | 2026-11-18 | M3 E2E on GitHub Pages | Results lived only in chat: the Pages 409 bootstrap bug, the 27 s revert, the post-revert check gap, and the Dependabot majors that waited. | open: `intent/0001-github-cicd-pipeline/spikes/m3-results.md` |
| PD-18 | 2026-11-18 | M3 E2E | The agent polled GitHub with shell loops while waiting for deploys. PR events are delivered without polling, but deploy runs are not. | open |
