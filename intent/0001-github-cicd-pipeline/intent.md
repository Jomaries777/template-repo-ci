# Intent: GitHub + CI/CD template for vibe-coded projects

| Field | Value |
|---|---|
| Status | **Accepted** by the product owner on 2026-11-15. Amendment 1 (pluggable deploy targets) accepted 2026-11-15 (PR #1). Amendment 2 (bot identity from any device, [intent 0002](../0002-bot-identity-any-device/intent.md)) accepted 2026-11-16 (#19); its spec was accepted 2026-11-16 (#21). Spec accepted; now in Stage 3, Build (`plan.md`) |
| Product owner | Repo owner (sole human: product owner, engineer and release manager) |
| Created | 2026-11-15 |
| SDLC stage | Stage 1, Plan: "Capture as intent.md" |
| Framework | [The AI-native SDLC playbook](https://claude.com/resources/articles/the-ai-native-sdlc-playbook) |
| Next artifact | `spec.md` in this folder (Stage 2, Design). It is written only after this file is accepted and committed. |

---

## Problem

1. **Every new project starts from scratch.** GitHub settings, branch rules, security scanning, Dependabot and CI workflows are set up by hand each time. The result is inconsistent and gaps get missed.
2. **Writing code is no longer the slow part. Review, testing and deploying are, and they have no structure.** Agents (Antigravity/Gemini and Claude Code) produce code quickly. Nothing decides when a change counts as verified, who may approve it, or when it may ship. There is also no record of artifacts that explains *why* a change exists.
3. **AI is spent on work that tools can do without AI.** Formatting, linting, testing, dependency updates and "should this deploy?" decisions burn Claude and Gemini quota when a deterministic tool would do the job for free and give the same answer every time.
4. **Infra and CI cost more than they should for hobby projects.** Hosting is always on, and every merge rebuilds and redeploys, even when only documentation changed.

## Proposed outcome

A **GitHub template repository** (`template-repo-ci`). Each new project is created from it with one command (`gh repo create <name> --template <owner>/template-repo-ci`) and comes with the full AI-native SDLC loop already wired up.

### 1. The loop and its artifacts

Each stage ends by committing an artifact. The next stage reads that artifact, and committing it is what starts the next stage.

| Stage | Committed artifact | Drafted by | Accepted by | Accepting it starts |
|---|---|---|---|---|
| Plan | `intent/<id>/intent.md` | Owner brainstorming with **Claude Code (interactive session)** | Owner (merge) | Design |
| Design | `intent/<id>/spec.md` | Agent, constrained by the project skills | Owner (merge) | Plan mode |
| Build | `intent/<id>/plan.md` + code on a branch/worktree | Antigravity (primary) / Claude Code (as needed) | Owner (plan approval) | Implementation PR |
| Test | Tests in the repo + CI results | Agents write the tests; CI runs them | The tools, not the agent's say-so | PR review |
| Deploy | Merged PR → release | CI pipeline | Owner (merge + production gate) | Post-merge deploy decision |
| Maintain | New `intent.md` from a breach or scan finding | Deterministic scheduled jobs | Owner (triage) | Plan (the loop restarts) |

The template ships the files that drive this loop: an `intent.md` template, `CLAUDE.md`, `REVIEW.md`, `.claude/skills/`, `.claude/agents/`, `.claude/settings.json` (team hooks), `.github/workflows/`, `.github/dependabot.yml`, and the repository ruleset as code.

### 2. Brainstorming: always in interactive Claude Code

- Brainstorming in the Plan stage always happens in an **interactive Claude Code session** with the owner in the loop. It is never headless (`claude -p`), never delegated to Antigravity/Gemini, and never automated.
- Claude Code interviews the owner, challenges assumptions, and drafts `intent.md` from the shared `intent.md` template, which ships as a skill. The owner corrects the draft before committing it.
- Incident- or scan-triggered intents from Maintain follow the same rule. Automation may open a *draft* `intent.md` or issue, but the owner refines it in an interactive Claude Code session before accepting it.

### 3. Build and test: Antigravity CLI is the primary executor

- After a `plan.md` is accepted, the build and test work runs mainly through the **Antigravity CLI** using `/swarm`, `/boost` or `/teamwork`. The owner picks the mode based on the size and shape of the task.
- **Antigravity reports progress to Claude Code** at start, per task, when blocked, and at done/failed, with links to the branch, commits and PR. **The channel is GitHub.** Antigravity pushes to a branch, opens a *draft PR* early, and posts progress as check runs or PR comments. Claude Code reacts to those PR events. The channel is event-driven and deterministic: Claude Code wakes on a state change and never polls with AI. It also leaves a durable record on GitHub that works across machines and needs no extra infra.
- **Claude Code's default role during Build** is orchestrator and observer. It reads the progress updates and keeps `plan.md` in sync with what Antigravity actually did. It steps in to build only when (a) Antigravity reports a failure or is blocked, (b) a task needs Claude specifically, or (c) the owner asks.
- **One shared context.** `CLAUDE.md` is the single source of truth for commands, conventions and known mistakes. Antigravity's context file points to it rather than duplicating it, so both agents verify work with the same `build` / `test` / `lint` commands.

### 4. Claude Code as builder and tester, when needed

- It always starts in **plan mode** with the accepted `spec.md`. No edits happen until `plan.md` is accepted.
- It makes full use of **subagents** defined in `.claude/agents/` with scoped tools. At minimum: a `verifier` (final check with fresh context), a `test-writer`, a `researcher` and a `simplifier`.
- For independent parts of the work it uses **agent teams / parallel sessions in git worktrees**. It starts with 2–3 sessions and adds more only while review can keep up.
- **Build-time hooks** (deterministic, fast, limited to the changed file):
  - run the formatter and linter after every edit
  - block edits to protected or generated paths
  - block secrets from entering the diff
  - during a bug fix, block edits to test files, so the fix is test-first

### 5. PR pipeline (GitHub Actions): deterministic checks first, Claude Code Review last

Jobs are chained with `needs:` and fail fast. **Claude Code Review runs only after every deterministic check has passed.** No AI tokens are spent on a PR that a linter or test would reject anyway.

| Tier | Checks (all non-AI) |
|---|---|
| 0. Triage | Classify changed paths (docs-only / CI-config / code); lint the workflows (`actionlint`); check the PR title (conventional commits) |
| 1. Static and security | Format check, lint, type check; **GitHub secret scanning + push protection**; **dependency review**; **CodeQL**; IaC/container scan when present; license check |
| 2. Tests | Build; **unit tests** with a coverage threshold; **acceptance tests** run against the app and its dependencies as **service containers inside the Actions job** (nothing is deployed per PR) |
| 3. AI review | **Claude Code Review** via `claude-code-action`, authenticated with the owner's **Claude Pro subscription** (`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`, so there is no per-token bill). It follows `REVIEW.md` and checks the diff against `CLAUDE.md`, `spec.md` and `plan.md` |

**Supported stacks, first release.** Each stack is an opt-in module. The language-neutral core is always included.

| Stack | Format / lint | Types | Unit | Acceptance |
|---|---|---|---|---|
| TypeScript / Node | Prettier, ESLint | `tsc` | Vitest | Playwright |
| Python | Ruff (lint + format) | pyright or mypy | pytest | Playwright or pytest-bdd |
| Go | gofmt, golangci-lint | compiler | `go test` | `go test` acceptance suite |

Repository-level settings applied by the template:

- **Dependabot**: alerts, security updates and grouped weekly version updates (grouping cuts PR noise and CI minutes). **Security and patch updates auto-merge** once every required check passes; this is non-AI automation. Minor and major updates wait for the owner.
- **GitHub security**: secret scanning + push protection, CodeQL default setup, private vulnerability reporting.
- **Ruleset on `main`**:
  - a PR is required and the required status checks must pass
  - **1 approving review** from the owner (Dependabot patch updates are exempt, see above)
  - review conversations must be resolved
  - no force-push or deletion
  - linear history
- **Claude Code Review rules** (from the playbook):
  - Findings are advisory and ranked by severity. They **never approve and never block**.
  - Nits are capped. Generated paths and anything CI already enforces are excluded.
  - Tagging `@claude` on a comment gets the fix pushed.
- **Separation of duties**: Antigravity/Gemini (or a Claude build session) writes the code, a separate Claude review session reviews it, and **only the owner approves and merges**. Agents never push to `main`. All agent output arrives as a PR under a **bot identity (a GitHub App)** rather than the owner's account. That is what lets the owner formally approve agent PRs, and it keeps agent actions separate from the owner's in the logs.

### 6. After merge: decide whether to deploy, without AI

When a push lands on `main`, a deterministic path classifier (no AI) picks one of these routes:

| Change type | Example paths | Action |
|---|---|---|
| **Docs only** | `**/*.md`, `docs/**`, `intent/**`, `LICENSE`, issue/PR templates | **No build, no deploy.** At most, rebuild a static docs site if the project has one. |
| CI / repo config only | `.github/**`, `.claude/**`, lint configs | Re-run checks. No deploy. |
| App code, dependencies, infra | everything else | Build the artifact once → deploy to the **dev** environment of the project's deploy target automatically → **production only after the owner approves** (GitHub `production` Environment, owner as required reviewer) |

**The deploy target is chosen per project** (Amendment 1). Each project picks the target that fits its needs through a pluggable deploy adapter. **Google Cloud Run is the default**, and the steps below use Cloud Run terms. Every target must follow the same dark deploy → test → promote → live test → auto-revert sequence and stay at $0 when idle. Other targets (e.g. Cloudflare Workers, GitHub Pages, or none for libraries) are designed in `spec.md`.

- The agent prepares the release up to the production gate and does nothing past it.
- AI is used after merge **only if a deploy fails**. Then `claude -p` runs a read-only triage and posts a summary to the owner.
- **Every production deploy is tested live and reverted automatically if it fails.** These steps are deterministic and use no AI:
  1. **Deploy dark.** The new Cloud Run revision deploys with `--no-traffic` and a revision tag. It gets its own URL while users stay on the current revision.
  2. **Pre-traffic test.** The smoke and acceptance suite runs against the tagged revision URL. If it fails, the new revision never receives traffic.
  3. **Promote.** All traffic shifts to the new revision.
  4. **Live test.** The same suite, plus health and error-rate checks, runs against the live production URL.
  5. **Auto-revert.** If the live test fails, the pipeline immediately shifts traffic back to the previous revision and re-runs the live test to confirm the revert worked.
  6. **Report.** The job fails visibly, and a GitHub issue / draft `intent.md` is opened with the test output. Only then does `claude -p` run a read-only triage that is attached to the issue.
- The owner's production approval covers the revert. Reverting is part of the approved release, not a new decision, so no second approval is needed to roll back. Rolling forward again requires a fresh PR and approval.
- Rollback is a single command (shift Cloud Run traffic back to the previous revision), rehearsed in dev. The same pre-traffic → promote → live-test → revert sequence runs on every dev deploy, so the path is exercised continuously.
- Fallback if a repo is ever private and its plan lacks Environment reviewers: production deploys through a manual `workflow_dispatch` run.

### 7. Maintain

- **Scheduled deterministic jobs**: Dependabot, a weekly CodeQL scan, stale-branch cleanup, cleanup of old versions and artifacts on the deploy target, and a cost/budget check.
- When a job crosses a threshold, it opens an issue or a draft `intent.md`, which restarts the loop. **AI is called only when there is a real finding to diagnose.** The owner decides whether to fix, schedule or dismiss it.

## Affected users and systems

**People**
- **Owner**: the only human. Holds the product owner, engineer, reviewer of record and release manager roles. Every gate comes down to the owner, but each gate stays explicit and recorded (a merge, an approval, an environment sign-off).

**Agents**
- **Antigravity CLI (Gemini)**: primary builder and tester through `/swarm`, `/boost` and `/teamwork`. Reports progress to Claude Code.
- **Claude Code**: interactive brainstorming partner (Plan), orchestrator, secondary builder and tester (subagents, agent teams), PR reviewer in CI, and post-failure triage.
- **GitHub automation**: Dependabot, CodeQL, secret scanning, Actions.

**Systems**
- **GitHub**: public template repository, rulesets, Actions, Dependabot, code security features, Environments, and a GitHub App as the agents' bot identity.
- **Local machine** (macOS): Antigravity CLI and Claude Code, git worktrees.
- **Anthropic**: the Claude Pro subscription covers interactive use *and* CI review. **Google**: Gemini quota for Antigravity.
- **Deploy target**: **chosen per project** through a pluggable adapter. The default is **Google Cloud Run** (dev + production services, Artifact Registry for images).

## Constraints

### Playbook principles (non-negotiable)
1. **The loop runs on artifacts.** Every stage ends in a committed artifact, and the next stage reads it. Nothing moves forward on chat alone.
2. **Agents act inside gates, not around them.** The agent does everything up to the production gate and nothing past it.
3. **Verification comes from tools, not from the agent's claims.** Tests, builds, linters, scanners and screenshots decide "done".
4. **The agent that wrote the code cannot approve it.** AI review findings are advisory.
5. **Agent output always arrives as a PR.** Agents never push to `main`.
6. **Configuration is code.** `CLAUDE.md`, `REVIEW.md`, skills, hooks, subagents and workflows are version-controlled and change through PRs.
7. **Skills are advisory.** Any policy that must hold is backed by a hook or a required CI check.
8. **One source of truth per artifact.** No duplicated instructions across agent context files.
9. **`CLAUDE.md` stays under one page.** When an agent makes the same mistake twice, the correction goes in.

### Optimising AI use (Claude and Gemini)
1. **Deterministic first.** Anything a formatter, linter, test, scanner, path filter or script can decide must not use AI.
2. **AI runs last and once.** In CI, Claude Code Review runs only after all deterministic checks pass. It is skipped for docs-only and draft PRs. Superseded runs are cancelled (`concurrency: cancel-in-progress`).
3. **Gemini does the bulk work.** Antigravity handles most build and test. Claude is kept for interactive brainstorming, orchestration, review and targeted build work.
4. **No AI polling.** Progress updates and pipeline state are event-driven.
5. **Right-size the model.** Each task's model tier is set in config. The default is the cheapest model that meets the quality bar; the details are decided in `spec.md`.

### Optimising cost
1. **Repos are public by default.** On public repos, CodeQL, secret scanning, push protection, dependency review and Environment reviewers are free, and so are standard Actions minutes. A repo that must be private switches to free open-source equivalents (e.g. gitleaks, Semgrep CE, osv-scanner, Trivy). Plan details must be verified in `spec.md`.
2. **Use few Actions minutes.** Use Linux runners only, set a `timeout-minutes` on every job, cache dependencies, filter by path, and cancel superseded runs.
3. **Scale-to-zero infra on every target.** Each deploy target must declare how it costs $0 when idle. For the Cloud Run default, services run with `min-instances=0` and stay within the free tier wherever possible. No per-PR environments: acceptance tests run in CI containers. Artifact Registry deletes old images automatically. Set a GCP budget alert on the project.
4. **Watch the Pro usage limit.** CI review shares the Claude Pro limit with interactive sessions. The skip rules (docs-only, draft, failing checks) and `concurrency` cancellation exist to protect it.
5. **Docs-only merges never build or deploy.**

### Vibe-coding context
- One owner, mostly AI-written code. The process has to stay light: gates can be collapsed onto one person, but they cannot be skipped.

## Open questions

### Resolved with the owner (interactive session, 2026-11-15)

| # | Question | Decision |
|---|---|---|
| 1 | Deploy target ("deploy to claude" read as "cloud") | **Pluggable per project. Google Cloud Run is the default**, scale to zero (Amendment 1, 2026-11-15) |
| 2 | Antigravity → Claude Code progress channel | **GitHub draft PR + check runs / PR comments** |
| 3 | Public or private by default | **Public**: free GitHub security features and Actions minutes |
| 4 | Billing for CI Claude Code Review | **Claude Pro subscription** via `CLAUDE_CODE_OAUTH_TOKEN` |
| 5 | Recording human approval | **Agents use a GitHub App bot identity**, and the owner approves their PRs |
| 6 | Dependabot auto-merge | **Security and patch updates only**, after all checks pass |
| 7 | First stacks | **TypeScript/Node, Python, Go** |
| 8 | Where acceptance tests run | **CI service containers** |
| 9 | Production gate | **GitHub `production` Environment** with the owner as required reviewer; `workflow_dispatch` fallback |
| 10 | Intent home | **`intent/<id>-<slug>/` in each repo** (intent.md, spec.md, plan.md) |
| 11 | Production verification | **Test the live app after every production deploy**, and **revert automatically** (Cloud Run traffic back to the previous revision) if the test fails |

### Still open (to verify during Design)

1. Can the Antigravity CLI open draft PRs and post check runs or comments under the GitHub App identity? What exactly do `/swarm`, `/boost` and `/teamwork` emit?
2. Is the Claude Pro usage limit enough for interactive work *plus* CI reviews at the expected PR volume? If not, what is the fallback (e.g. reviewing only on `ready_for_review`, or switching to an API key with a budget cap)?
3. Can Dependabot PRs be exempted from the required-approval rule in a ruleset, or does auto-merge need a bypass actor?
4. What counts as a failed live test: test failures only, or also error-rate / latency thresholds over a short observation window? How long is that window, given the cost of keeping a job running?
5. Live tests must not damage production data. Which tests are safe to run against production (read-only or using dedicated test accounts), and which run only pre-traffic?

---

*To accept: the owner reviews and corrects this file, then commits/merges it. Acceptance starts Stage 2: `spec.md` is drafted in this folder from this intent and constrained by the project skills, and any policy conflicts are flagged for the owner.*
