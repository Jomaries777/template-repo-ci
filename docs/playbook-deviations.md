# Playbook deviations

Where this template departs from [The AI-native SDLC playbook](https://claude.com/resources/articles/the-ai-native-sdlc-playbook) (read 2026-11-18), and why.

This file records the template's own history. Bootstrap removes it from new projects. It is the one place for departures from the **playbook**, and its [checklist](#playbook-checklist) says, item by item, whether the template meets the playbook today. Departures from an intent's **plan** stay in that `plan.md`'s Deviations table. When an entry here leads to work, link the PR or intent in its Status, and don't delete closed entries: set their Status.

**Kinds of entry**
- **Deliberate:** a design choice the owner accepted. It holds until someone reopens it.
- **Gap:** something the playbook recommends that we don't do yet.
- **Slip:** our own process wasn't followed on a specific change. It's kept so that repeats show up; a slip that repeats goes into `CLAUDE.md`.

**Status values:** `accepted` (deliberate, no action), `open`, `planned` (with where), `fixed` (with the PR).

## Personal vibe coding: what we keep and what we adapt

The playbook is written for teams: separate product owners, tech leads, code owners and release managers, staging environments, enterprise controls and a budget. This template serves one owner who writes mostly through AI, on a tablet or in cloud sessions, on public repos, with a Claude Pro plan and $0 hosting when idle.

So we keep the playbook's **intent** everywhere and adapt its **mechanisms** where they assume a team or a budget.

### Why adapting is sound here

1. **Collapsing roles leaves the gates in place.** A gate does its work at the moment of decision, whoever makes it. One person holding every role still has to accept the intent, approve the PR and approve the production deploy, and each step is recorded. Intent 0001 sets the rule: gates "can be collapsed onto one person, but they cannot be skipped."
2. **Server-side controls replace team process.** GitHub enforces branch rulesets, required checks and Environment reviewers whoever is at the keyboard, including an agent. That covers what a second reviewer or a managed-settings policy would.
3. **The blast radius is small.** Public, low-traffic projects with free hosting can't run up a bill or expose customer data. Cost controls ($0 when idle, budget alerts) matter more here than change-management sign-off.
4. **Cost and quota are hard limits.** One Pro plan shares its quota between interactive work and CI review. Practices that need Enterprise features, paid usage or nightly AI runs are replaced by free deterministic tools, or scaled down.
5. **Rehearsed rollback stands in for staging.** A deploy that reverts itself in under 2 minutes, proven for real in sandbox repos, gives most of staging's safety without a second environment.

### What we always follow (non-negotiable for one owner too)

These cost little and are where solo AI-written code most often goes wrong, so they hold on every change:

| Principle | How it's held here |
|---|---|
| The loop runs on artifacts, not chat | `intent.md`, then `spec.md`, then `plan.md`, then a PR. Results go into a file before a change is called done. |
| Plan before code | Plan mode first, from the accepted `spec.md` and `plan.md`. |
| Verification comes from tools, not claims | `make lint test` and the `verifier` subagent before "done". Evidence is command output and `git diff`. |
| Bugs start with a failing test | On `fix/*`, the failing test is committed first and not edited after (hook). |
| Agent output arrives as a PR; nothing pushes to `main` | Branch ruleset and `ci-ok` required check. |
| The agent can't approve its own work | AI review is advisory. Only the owner approves PRs and production deploys. |
| The agent never deploys to production | Deploys run in CI behind the Environment reviewer. |
| Agents act under their own identity | PRs come from the bot, never the owner's account (see PD-10). |
| Configuration is code | `CLAUDE.md`, `REVIEW.md`, skills, hooks, agents and workflows change only through PRs. |
| Must-hold rules are enforced, not advised | Hooks and required CI checks back every rule; skills are advisory. |
| Deterministic first, AI last | Lint, tests, scanners and classification decide; AI review runs once after they pass. |
| Mistakes made twice go into `CLAUDE.md` | Kept under one page. |
| Cheap or free by default | $0 when idle; nothing billable without the owner's say-so. |

### What we adapt, and the condition to revisit

Each adaptation is listed below with its ID. Revisit it when its condition changes:

- **A second person joins the project:** split the roles again (PD-1, PD-8) and consider code-owner review (PD-2).
- **Real users or revenue:** add staging (PD-4) and the Stage 6 control bands (PD-11).
- **An Enterprise plan:** consider Claude Security scans (PD-6).
- **Many intents a week:** automate spec writing (PD-7).

## Playbook checklist

Every practice the playbook recommends, one row each, so it's clear what is met and what isn't. Reviewed 2026-11-21. The Plan, Design and Build items come from the playbook's full text. Test, Deploy and Maintain come from a summary of the page's second half. Its closing section and its diagram of the plays weren't read.

**Met?**
- **Met:** done as the playbook says.
- **Met (adapted):** same intent, different mechanism; the PD entry says why.
- **Partly:** done in part.
- **Not met:** not done.
- **N/A:** doesn't apply to one owner.

**Recommendation** is for personal projects with one owner, a Pro plan and $0 hosting:
- **Keep:** keep doing it as now.
- **Keep adapted:** keep the adapted form.
- **Skip:** don't pursue it unless its trigger in [What we adapt](#what-we-adapt-and-the-condition-to-revisit) happens.
- **Do:** a cheap step that closes or narrows a gap.

To update: change a row's **Met?** when that changes, and link the PR.

### Stage 1: Plan

| ID | Playbook practice | Met? | How it's held here, or why not | Recommendation |
|---|---|---|---|---|
| PB-1 | Brainstorm with Claude into `intent.md` | Met | `/intent`, `write-intent` skill | Keep |
| PB-2 | Product owner corrects and accepts the intent | Met (adapted) | The owner holds the role (PD-1); accepting means merging | Keep adapted |
| PB-3 | Agreed intent template (problem, outcome, users and systems, constraints, open questions) | Met | `write-intent` skill | Keep |
| PB-4 | Intent lives in `intent/` in the product repo | Met | `intent/<id>-<slug>/` | Keep |
| PB-5 | Non-engineers reach Claude through claude.ai, Cowork or a GitHub connector | N/A | One owner, who is the engineer | Skip |
| PB-6 | Metrics: time to committed intent; share accepted; intent edits after the spec | Not met | Printed as n/a by `sdlc-metrics.sh` v1 | Skip: too few intents to mean anything |

### Stage 2: Design

| ID | Playbook practice | Met? | How it's held here, or why not | Recommendation |
|---|---|---|---|---|
| PB-7 | `spec.md` written from the intent in one session, constrained by policy skills, concerns flagged | Met | `/spec`, `write-spec` skill; `secure-change` and `cost-guard` skills | Keep |
| PB-8 | Front-end mocks in Claude Design, exported to Claude Code | Not met | No UI work yet | Do it on UI-heavy projects only |
| PB-9 | Accepting an intent triggers a job that commits `spec.md` as a PR | Met (adapted) | `/spec` by hand (PD-7) | Keep adapted |
| PB-10 | Product owner gates the spec; tech lead for higher-risk work; concerns settled with the policy owner | Met (adapted) | The owner holds every role (PD-1) | Keep adapted |
| PB-11 | Spec, its prompt and the skill versions are logged in version control | Partly | The spec and skills are in git; the prompt is not kept | Keep as is |
| PB-12 | Metrics: intent-to-spec time; spec rework after the plan | Not met | n/a in `sdlc-metrics.sh` v1 | Skip |

### Stage 3: Build

| ID | Playbook practice | Met? | How it's held here, or why not | Recommendation |
|---|---|---|---|---|
| PB-13 | Plan mode first; `plan.md` with Files, Order, Risks, Proof; updated in the same commit when the build departs | Partly | `write-plan` skill and Deviations tables, but plan mode was skipped more than once (PD-14); the slip is now in `CLAUDE.md` | Keep |
| PB-14 | A hook keeps `plan.md` in sync with the code | Not met | The Deviations table and the review's conformance pass catch drift | Skip |
| PB-15 | Higher-risk plans go to a tech lead or architect | Met (adapted) | The owner (PD-1) | Keep adapted |
| PB-16 | Auto mode for tightly specced, small, tested changes | Met | Used once the plan is accepted | Keep |
| PB-17 | One source of truth per artifact (legacy-system sidebar) | Met | The repo is the source of truth (option A) | Keep |
| PB-18 | `CLAUDE.md`: under a page, commands with healthy output, conventions, mistakes made twice | Met | `CLAUDE.md` | Keep |
| PB-19 | `CLAUDE.md` changes approved by code owners | Met (adapted) | The owner approves every PR; code-owner review is off (PD-2) | Keep adapted |
| PB-20 | Skills for standards applied consistently, paired with a hook or review re-check | Met | Skills are advisory; hooks and CI back them | Keep |
| PB-21 | Build hooks: protected paths, format and lint after edits, no credentials | Met | `scripts/hooks/` | Keep |
| PB-22 | 2–3 parallel worktree sessions, split by file | Partly | Plans mark independent steps; rarely used | Optional |
| PB-23 | Safe commands pre-allowed to avoid prompt fatigue | Met | `.claude/settings.json` | Keep |
| PB-24 | Subagents: simplifier, researcher, and a verifier that runs the app | Met | All three exist; the verifier also runs the acceptance suite when the app's behaviour changes, and reports "not run" without Docker | Keep |
| PB-25 | Metrics: parallel sessions, steering time, OpenTelemetry export | Not met | PD-12 | Skip |

### Stage 4: Test

| ID | Playbook practice | Met? | How it's held here, or why not | Recommendation |
|---|---|---|---|---|
| PB-26 | A feedback loop: one command, its healthy output in `CLAUDE.md`, verification in "done" | Met | `make lint test`, the `verifier` subagent | Keep: non-negotiable |
| PB-27 | Bugs start with a failing test; a hook blocks test edits during the fix | Met | `test-first.sh` on `fix/*` | Keep |
| PB-28 | UI work: browser or screenshot loop against the mock | Not met | No UI work yet; Playwright is in the node stack | Do it on UI projects |
| PB-29 | Continuous evals: 20–50 real tasks, scheduled and on `CLAUDE.md`/skill/hook changes, gating them | Not met | PD-9, the largest gap; each run uses Pro quota | Skip until `CLAUDE.md` or skill changes cause regressions, then 3–5 cases |
| PB-30 | AI PR review with `REVIEW.md`, Important vs nit, nits capped at 5, advisory | Met | `claude-review` job, five passes | Keep |
| PB-31 | Review findings fixed by `@claude` or a sweep command | Met | `claude.yml`, `/sweep` | Keep |
| PB-32 | Review tuned monthly; a finding flagged twice goes into `CLAUDE.md` | Partly | Done when noticed, not monthly | Keep informal |
| PB-33 | Metrics: time to first review; comments resolved without a human | Partly | Reviews and skips per merged PR in `sdlc-metrics.sh` v1 | Keep |

### Deploy

| ID | Playbook practice | Met? | How it's held here, or why not | Recommendation |
|---|---|---|---|---|
| PB-34 | Approval gates as Claude Code hooks; a release manager authorizes production | Met (adapted) | GitHub Environment reviewer (PD-3, PD-8) | Keep adapted: stronger, it can't be bypassed |
| PB-35 | Managed settings: denied paths, sandbox, managed hooks and MCP servers | Met (adapted) | `permissions.deny`, hooks, and the cloud session's sandbox; no Enterprise managed settings | Keep adapted |
| PB-36 | Read-only `claude -p` judgment in CI (triage failures) | Met | The deploy `report` job | Keep |
| PB-37 | Agent write steps land only as PRs, never on `main` | Met | Ruleset, `ci-ok` | Keep: non-negotiable |
| PB-38 | Agent jobs sandboxed, short-lived scoped tokens, no production credentials | Met | 1-hour bot tokens; target secrets only in the deploy jobs | Keep |
| PB-39 | Deploy, status and rollback as MCP tools scoped per environment | Met (adapted) | CI scripts only; the agent has no deploy path (PD-5) | Keep adapted |
| PB-40 | Dev, then staging, then production | Met (adapted) | Dev and production; sandboxes rehearse (PD-4) | Keep adapted until real users or revenue |
| PB-41 | Rollback is one command, rehearsed | Met | Automatic revert, failed live check to confirmed revert: Cloud Run 11.5 s, Pages 27.1 s (`sandbox-node-workers` run 45407649448; the earlier 27 s in `sandbox-node-static` was never confirmed, see `m3-results.md` finding 2) | Keep; rehearse once per new adapter |
| PB-42 | Each agent run has its own identity in logs | Partly | Commits and PRs come from the bot; cloud-session PR comments appear as the owner, and Claude in CI posts as the shared `github-actions[bot]` (PD-10) | Keep adapted for now |
| PB-43 | DORA metrics | Partly | `sdlc-metrics.sh` v1: deploys, lead time, change failure rate, time to restore (PD-12) | Keep |

### Maintain

| ID | Playbook practice | Met? | How it's held here, or why not | Recommendation |
|---|---|---|---|---|
| PB-44 | Headless monitoring: a metric baseline, σ bands, tiered response (log, diagnose, PR or runbook) | Not met | PD-11; low traffic gives no stable baseline | Skip the bands; the daily smoke test opening an issue is enough |
| PB-45 | Scheduled deterministic checks open issues | Met | `maintain.yml` (#54): daily smoke test, monthly metrics and token renewal; proven by two manual runs, the metrics one opening #56 (PD-11) | Keep |
| PB-46 | Findings written as `intent.md` | Met (adapted) | An issue first, then `/intent --from-issue` | Keep adapted |
| PB-47 | An eval for each incident | Not met | Tied to PB-29 | Skip |
| PB-48 | Claude Tag on call in incident channels | N/A | No incident channel | Skip |
| PB-49 | Post-mortem lessons file | Not met | `deploy-failure` issues and `CLAUDE.md` cover it | Skip |
| PB-50 | Recurring codebase security scans, findings dismissed with a reason | Met (adapted) | CodeQL, secret scanning, Dependabot, dependency review (PD-6); CodeQL on PRs and weekly on Mondays (#54; first scheduled run [45213625625](https://github.com/Jomaries777/template-repo-ci/actions/runs/45213625625), 2026-11-23, passed) | Keep adapted |

**Score (2026-11-21), 50 practices:** 20 met, 11 met (adapted), 7 partly, 10 not met, 2 N/A. Every "not met" row is either a deliberate skip for personal projects or has a **Do**.

### Open actions from the checklist

- PB-13: ~~add the repeated plan-mode slip to `CLAUDE.md`~~ done.
- PB-24: ~~have the `verifier` run `make acceptance` on stack changes~~ done.
- PB-45: ~~owner merges `maintain.yml`~~ done (#54).
- PB-50: ~~owner adds `schedule:` (weekly) to `pr.yml` for CodeQL~~ done (#54).

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
| PD-9 | Continuous evals: 20–50 real tasks run in CI on a schedule and on any change to `CLAUDE.md`, skills or hooks, and they gate those changes. Every incident adds one. | None. Changes to `CLAUDE.md`, skills and hooks are reviewed like code, but nothing regression-tests them. | Not in intent 0001's scope, and each run uses Pro quota. This is the largest gap. | open: a small intent of its own, 3–5 cases run only when `CLAUDE.md`, skills or hooks change, to stay within Pro quota |
| PD-10 | Agent runs use their own identity, so logs separate agent actions from the engineer's. | Commits and PRs from cloud sessions now come from the bot through `scripts/bot-relay.sh` (intent 0002; #47 to #51). PR **comments** from a cloud session still appear as the owner, because they go through the GitHub connector and the broker has no comment route. Claude in CI (`claude.yml`, `claude-review`, the deploy `report` job) posts with the job's `GITHUB_TOKEN`, so its comments appear as `github-actions[bot]`, shared with every workflow; only the linked run shows it was Claude. | Until 2026-11-18 the session was on the Default environment. The relay has `/relay`, `/token` and `/secrets`, but no route for comments. Anthropic's Claude GitHub App would label CI comments `claude[bot]`, but it adds a write-capable App the owner doesn't control, and its setup clashes with the hand-written `claude.yml`. | partly fixed (commits and PRs); comments accepted for now by the owner, 2026-11-21. A broker `/comment` route would close it (spec 0002 amendment). CI comments as `github-actions[bot]`: recorded 2026-11-24, no fix chosen |
| PD-11 | Stage 6, Maintain: σ control bands on a metric, read-only diagnosis at 2σ, a PR or pre-approved runbook at 3σ, findings written as `intent.md`. | Not built. | Milestone order. | fixed for v1: `maintain.yml` (#54) runs the daily smoke test and the monthly metrics and token renewal; both proven by manual runs (#56). σ bands won't be built for personal projects (PB-44) |
| PD-12 | Leading and lagging metrics per stage, DORA measures, OpenTelemetry session export. | Defined in 0001 spec §7; nothing collects them yet, and no OpenTelemetry export is set up. | Milestone order. | partly fixed: `sdlc-metrics.sh` v1 (#50) covers DORA-style deploy metrics, review and first-pass `ci-ok`; the rest prints n/a. OpenTelemetry won't be set up (PB-25) |
| PD-13 | "Gemini does the bulk work" is not a playbook rule; it's intent 0001's. Listed here because it changes who the build agent is. | Most of M2 and M3 was built by Claude Code in a cloud session; Antigravity re-runs are deferred. | No Antigravity and no bot key in cloud sessions. Recorded for M2 steps 1–2 in the plan; M3 and M4 went the same way. | open: recommend dropping the rule from intent 0001 unless Antigravity is used again. First change delivered by Antigravity: #76 (2026-11-26), a one-line README change from a real `agy-run.sh boost` run (criterion 8). The recommendation stands: the bulk work is still Claude Code's |
| PD-18 | The agent waits for delivered events, not polling loops. | Deploy runs and the bot's check runs are waited on by a background loop that runs no AI: `gh run watch`, or a `gh api` loop on the check run. It exits on completion, and its exit wakes the session. PR events still come through the app's PR monitor where it applies. | Deploy runs and the bot's check runs have no push route to a session. The app's PR monitor can't watch bot PRs, the only kind agents open. Spec §4.7 names the non-AI watch. Seen in the M3 E2E (2026-11-18), and again on 2026-11-26: the python and go sandbox deploys, #76's re-run, and the criterion 8 monitor (`spikes/m4-criterion8-agy-run.md`). | accepted by the owner, 2026-11-27. It was slip PD-18 (2026-11-18) |

## Slips

| ID | Date | Change | What was skipped | Status |
|---|---|---|---|---|
| PD-14 | 2026-11-18 | template #45; sandbox `sandbox-node-static` #5, #6 | Plan mode was not used. | repeated (the `sdlc-metrics.sh` design was agreed in chat, 2026-11-20, not in plan mode); now in `CLAUDE.md` "Things Claude gets wrong". **Fixed**: closed by the owner on 2026-11-27. In one session (2026-11-26/27), five changes in a row, #74, #75, #77, #78 and #79, plus the planned agy run #76, each started in plan mode, and the owner approved each plan before any edit. The evidence is that session, because plan mode leaves no trace on GitHub. Whether #64 to #73, from other sessions, started in plan mode isn't known. The `CLAUDE.md` line stays as the guard |
| PD-15 | 2026-11-18 | sandbox `sandbox-node-static` #6 | Merged before Claude's review ran. The review is skipped on drafts and the PR was merged right after it was marked ready. | open: wait for `claude-review` before merging. Held on #78 (2026-11-27), the only code PR among #73 to #79: merged 8.5 min after `claude-review` succeeded |
| PD-16 | 2026-11-18 | sandbox `sandbox-node-static` #1–#3 (Dependabot majors) | Merged on the owner's word in chat, with green CI but no review recorded on the PR. | open: closes with PD-10, when the owner reviews and merges in GitHub. Since 2026-11-26 every template merge (the Dependabot update #59, and #73 to #79) was an owner approval recorded in GitHub before the merge |
| PD-17 | 2026-11-18 | M3 E2E on GitHub Pages | Results lived only in chat: the Pages 409 bootstrap bug, the 27 s revert, the post-revert check gap, and the Dependabot majors that waited. | fixed: written up on 2026-11-24 in `intent/0001-github-cicd-pipeline/spikes/m3-results.md` |

PD-18 moved to Deliberate on 2026-11-27.
