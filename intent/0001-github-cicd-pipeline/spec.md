# Spec: GitHub + CI/CD template for vibe-coded projects

| Field | Value |
|---|---|
| Status | **Accepted** by the product owner on 2026-11-15 (PR #1, `083d256`). Next: Stage 3, Build (`plan.md`) |
| Source intent | [`intent.md`](intent.md), accepted 2026-11-15 (commit `7138c42`) |
| SDLC stage | Stage 2, Design: "Requirements and design" |
| Framework | [The AI-native SDLC playbook](https://claude.com/resources/articles/the-ai-native-sdlc-playbook) |
| Constrained by | The intent's Constraints section and the playbook principles. No org policy skills exist yet; this spec defines the first ones (§6). |
| Next artifact | `plan.md` in this folder (Stage 3, Build). It is written in plan mode after this spec is accepted. |

Requirements trace back to the intent: **FR** = functional requirement, **NFR** = non-functional requirement. Items marked **⚠ verify** depend on facts that could not be confirmed from primary sources while drafting; `plan.md` must prove them before relying on them.

---

## 1. Scope

**In scope**
- The `template-repo-ci` GitHub template repository and everything a new project gets from it.
- One deterministic bootstrap that turns a fresh copy of the template into a configured project: GitHub settings, the chosen deploy target's resources and the chosen stack.
- The template's own self-test CI.

**Out of scope**
- Application code. The template ships only a minimal "hello" service per stack, so the pipeline has something to build, test and deploy.
- Multi-repo intent homes, private-repo GitHub Advanced Security.
- Deploy adapters beyond the four in §4.11. Others can be added later through the adapter contract.
- Building or changing Antigravity itself. We wrap its CLI; we don't modify it.

## 2. Requirements

### 2.1 Functional

| ID | Requirement | Intent ref |
|---|---|---|
| FR-1 | `gh repo create <name> --template Jomaries777/template-repo-ci --public --clone` followed by `make bootstrap STACK=<stack> TARGET=<target>` produces a fully configured project with no manual GitHub-UI steps. The only exceptions are the one-time secrets listed in §4.9. | Outcome, Problem 1 |
| FR-2 | Every change is traceable to an `intent/<id>-<slug>/` folder holding `intent.md`, `spec.md` and `plan.md`. Templates for all three ship as skills. | Outcome §1, Decision 10 |
| FR-3 | Brainstorming for `intent.md` is done only in an interactive Claude Code session, through the `/intent` command. | Outcome §2 |
| FR-4 | `scripts/agy-run.sh` runs an Antigravity `/swarm`, `/boost` or `/teamwork` job against an accepted `plan.md`. It streams progress to a GitHub check run and the PR. | Outcome §3, Decision 2 |
| FR-5 | Claude Code ships subagents (`verifier`, `test-writer`, `researcher`, `simplifier`) and build-time hooks (format/lint, protected paths, secrets, test-first). | Outcome §4 |
| FR-6 | Every PR runs deterministic checks in tiers. Claude Code Review runs only after all of them pass, and is skipped for docs-only, draft, Dependabot and failing PRs. | Outcome §5 |
| FR-7 | Dependabot covers each stack's ecosystem plus `github-actions` and `docker`. Patch updates auto-merge after all checks pass; minor and major updates, security ones included, wait for the owner (amended 2026-11-15, see plan.md Deviations). | Decision 6 |
| FR-8 | After merge, a path classifier routes the change: docs-only → no build or deploy; config-only → checks only; code → build once, deploy to dev, then production with owner approval. | Outcome §6 |
| FR-9 | Every dev and production deploy goes: dark deploy → pre-traffic test → promote → live test → automatic revert on failure → report. | Decision 11 |
| FR-10 | Scheduled deterministic jobs (CodeQL, a daily production smoke test, stale-branch cleanup, monthly SDLC metrics) open a GitHub issue when they find a breach. | Outcome §7 |
| FR-11 | Agents author PRs and pushes under a GitHub App bot identity, never under the owner's account. | Decision 5 |
| FR-12 | Owner-authored PRs (e.g. editing an intent by hand) can still be merged even though the owner can't approve their own PR. | Derived; see C4 |
| FR-13 | The deploy target is chosen per project in `deploy.yml` and implemented by a pluggable adapter (§4.11). Ships with `cloud-run` (default), `cloudflare-workers`, `github-pages` and `none`. FR-9 applies to every adapter. | Owner request 2026-11-15, amends Decision 1 |
| FR-14 | `README.md` has a **"Start a new project"** quick-start covering, in order: prerequisites → one-time owner setup → one-time machine setup → create from template → `make bootstrap` → install the bot App on the new repo → `make doctor` → first change via `/intent`. It also explains how to choose `STACK` and `TARGET` (table from §4.11) and how to continue on another computer. Bootstrap replaces the template's README with a project README stub. | Owner request 2026-11-15 |
| FR-15 | `make doctor` (read-only, no AI) checks that the repo settings, ruleset, Environments, secrets/variables, bot App installation and deploy-target access all match this spec. It prints a pass/fail list with a fix hint for each failure. | Supports FR-1, FR-14 |

### 2.2 Non-functional

| ID | Requirement |
|---|---|
| NFR-1 **Cost** | Steady-state infra cost for an idle project is **$0/month** within the free tiers: a public GitHub repo plus the chosen target's free tier. Every adapter must declare how it reaches $0 when idle (§4.11). Any target that can bill a card gets a budget alert at $1 / $5 / $10. |
| NFR-2 **AI usage** | At most one automatic Claude review per PR revision, and at most 3 automatic reviews per PR. After that, the owner asks for more with `@claude review`. Zero AI calls on docs-only PRs and merges. |
| NFR-3 **Actions minutes** | Every job sets a `timeout-minutes`. Superseded PR runs are cancelled. Dependencies are cached. Linux runners only. |
| NFR-4 **Security** | Workflows default to `permissions: contents: read`. Third-party actions are pinned to a commit SHA (Dependabot keeps them updated). Deploy auth uses OIDC federation wherever the target supports it (GCP Workload Identity Federation, GitHub Pages). Where it doesn't, auth uses a least-privilege token scoped to one account, stored as a GitHub *Environment* secret and rotated yearly. Secrets never appear in logs. |
| NFR-5 **Determinism** | Every gate decision (classify, deploy, revert, auto-merge) is made by a script or GitHub rule, never by a model. |
| NFR-6 **One command surface** | `make lint`, `make typecheck`, `make test`, `make acceptance`, `make build` and `make smoke URL=…` are the only commands. `CLAUDE.md`, Antigravity and CI all call them. |
| NFR-7 **Portability** | Works from any of the owner's computers after `gh repo clone` plus a documented one-time machine setup (§4.9). |
| NFR-8 **Rollback time** | An automatic revert restores the previous version within 2 minutes, on every target, of a failed live test. |

## 3. Architecture

```
 Owner ──(interactive)──▶ Claude Code ──▶ intent.md ─▶ spec.md ─▶ plan.md   (each merged by owner)
                                                                   │
              ┌────────────────────────────────────────────────────┘
              ▼
   scripts/agy-run.sh ──▶ Antigravity CLI (/swarm|/boost|/teamwork, headless)
              │                 │ JSON event stream
              │                 ▼
              │        scripts/agy-events.sh (jq, no AI) ──▶ GitHub check run + PR comments
              │                                                   │
              │        Claude Code (watches PR, wakes on change) ◀┘  ── steps in only on failure/ask
              ▼
   Draft PR (bot identity) ──ready──▶ pr.yml: classify → static+security → tests → acceptance
                                                         → Claude Code Review (advisory) → ci-ok
              ▼
   Owner approves + merges ──▶ deploy.yml: classify → build artifact once → deploy.sh → adapter in deploy.yml
                               (cloud-run | cloudflare-workers | github-pages | none)
              dev:  dark deploy → pre-traffic test → promote → live test → revert on fail
              prod: [owner approval] → same sequence ──▶ issue on failure → claude -p triage
              ▼
   maintain.yml (cron): CodeQL, daily prod smoke, stale branches, metrics ──▶ issue / draft intent.md
```

## 4. Design

### 4.1 Repository layout (what a new project receives)

```
.
├── README.md                      # template: "Start a new project" quick-start (FR-14); project: stub
├── CLAUDE.md                      # single source of truth for agents (< 1 page)
├── AGENTS.md                      # 3 lines: "Read CLAUDE.md". Antigravity's entry point ⚠ verify filename agy reads
├── REVIEW.md                      # Claude Code Review passes, severity, skips
├── Makefile                       # the one command surface (NFR-6), delegates to stacks/<stack>/
├── deploy.yml                     # chosen deploy target + environments + smoke settings (FR-13)
├── deploy/targets/                # adapters: cloud-run (default), cloudflare-workers, github-pages, none
├── intent/
│   └── .gitkeep                   # bootstrap removes the template's own intent folders
├── .claude/
│   ├── settings.json              # team hooks + permissions
│   ├── commands/                  # /intent, /spec, /plan, /sweep
│   ├── skills/                    # write-intent, write-spec, write-plan, secure-change, cost-guard
│   └── agents/                    # verifier, test-writer, researcher, simplifier
├── .github/
│   ├── workflows/                 # pr.yml, claude.yml, deploy.yml, dependabot-automerge.yml, maintain.yml
│   ├── actions/                   # composite: classify, release (adapter-driven)
│   ├── rulesets/main.json         # ruleset as code, applied by bootstrap
│   ├── dependabot.yml
│   ├── CODEOWNERS                 # * @Jomaries777 (replaced with the new owner by bootstrap)
│   └── pull_request_template.md   # links intent/spec/plan, proof checklist
├── stacks/
│   ├── node/  python/  go/        # lint/test config, hello service, Dockerfile, acceptance suite
├── scripts/
│   ├── bootstrap.sh               # FR-1, idempotent
│   ├── gh-settings.sh             # security features, ruleset, environments, template flag
│   ├── deploy.sh                  # dispatcher: deploy.sh <verb> → deploy/targets/<target>/<verb>
│   ├── bot-token.sh               # mints 1-hour GitHub App installation token
│   ├── agy-run.sh / agy-events.sh # FR-4
│   ├── classify.sh                # docs | config | code (shared by PR and deploy)
│   └── sdlc-metrics.sh            # FR-10 monthly metrics
(template-only CI is .github/workflows/template-selftest.yml; bootstrap removes it)
```

`make bootstrap STACK=node|python|go TARGET=cloud-run|cloudflare-workers|github-pages|none` keeps the chosen stack in `stacks/<stack>/` (the root `Makefile` delegates to it), writes `deploy.yml` with `target:` and `stack:`, and deletes the unused stacks and the test-only adapters (every real adapter stays, so `make bootstrap-target` can switch to it later; amended 2026-11-18), the template's own `intent/` folders, its self-test workflow and its bootstrap test. It then runs `gh-settings.sh`, creates the Environments, sets the secrets and runs the chosen adapter's `bootstrap` (amended 2026-11-15, see plan.md Deviations).

### 4.2 Change classifier (`scripts/classify.sh`, no AI)

It reads `git diff --name-only <base>...<head>` and outputs one class:

| Class | Matches (all changed files must match) |
|---|---|
| `docs` | `**/*.md` (except `CLAUDE.md`, `REVIEW.md`, `AGENTS.md`), `docs/**`, `intent/**`, `LICENSE`, `.github/ISSUE_TEMPLATE/**`, `.github/pull_request_template.md` |
| `config` | `.github/**`, `.claude/**`, `CLAUDE.md`, `REVIEW.md`, `AGENTS.md`, lint/format configs, `Makefile` |
| `code` | anything else, or any mix that includes a non-docs, non-config file |

Precedence: `code` > `config` > `docs`. Agent instruction files count as `config`, not `docs`, because changing them changes behaviour ("configuration is code").

### 4.3 PR pipeline: `.github/workflows/pr.yml`

**Trigger**: `pull_request` (`opened`, `synchronize`, `reopened`, `ready_for_review`) and `merge_group`.
**Concurrency**: `pr-${{ github.event.pull_request.number }}`, `cancel-in-progress: true`.

| Job | `needs` | Runs when | What it does |
|---|---|---|---|
| `classify` | — | always | `classify.sh` → output `class` |
| `hygiene` | classify | always | `actionlint`, conventional-commit PR title check, markdownlint + link check (lychee) on changed `.md` files |
| `secrets` | classify | always | gitleaks on the PR diff. GitHub secret scanning + push protection run as repo settings; this job makes leaks a *blocking check*. |
| `lint` | classify | class ≠ docs | `make lint` + `make typecheck` |
| `dependency-review` | classify | class = code | `actions/dependency-review-action` (fail on high severity, deny copyleft licences except where listed) |
| `codeql` | classify | class = code | CodeQL **advanced setup** in this workflow, so Claude can wait on it (see C3) |
| `unit` | lint | class = code | `make test` with a coverage threshold (default 80% of changed lines; set in stack config) |
| `build` | lint | class = code | `make build` → the artifact the target needs (container image, worker bundle or static directory), built only and not published |
| `acceptance` | unit, build | class = code | `make acceptance`: the app plus dependencies as service containers in the job (Decision 8) |
| `claude-review` | all of the above | class ≠ docs **and** not draft **and** author ≠ `dependabot[bot]` **and** PR from this repo (not a fork) **and** auto-review count < 3 | `anthropics/claude-code-action` with `claude_code_oauth_token`, prompt = "Review per REVIEW.md", Sonnet model, `timeout-minutes: 10` |
| `ci-ok` | all except claude-review | `if: always()` | Fails if any needed job failed or was cancelled. Skipped jobs count as passing. **This is the only required status check.** |

Why a single `ci-ok` gate: GitHub treats a required check that never ran as pending forever. Path-filtered jobs would therefore block docs-only PRs. One always-running aggregate job avoids that.

Why `claude-review` isn't required: review findings are advisory (playbook) and must never block a merge. The owner reads them before approving.

### 4.4 Claude Code Review and `@claude`

- **Auth**: repo secret `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` on the owner's Pro account (Decision 4).
  - The token is tied to the owner's account and lasts about a year. `maintain.yml` opens a renewal issue 30 days before expiry.
  - ⚠ verify: user reports describe 401 errors and plan-upgrade breakage with setup tokens. If that happens, regenerate the token with `claude setup-token`. **There is no API-key fallback (C7).** A broken or exhausted token makes `claude-review` exit neutral with an explanatory comment and never blocks `ci-ok`.
- **Quota guards** (NFR-2; Pro usage only, never paid API usage):
  - The review runs only after every check passes.
  - At most 3 automatic reviews per PR, counted from its own previous review comments. Later pushes are reviewed only on `@claude review`.
  - Draft, docs-only and Dependabot PRs are skipped.
  - **Fork PRs are skipped.** On a public repo this stops strangers from spending your Pro quota.
- **`claude.yml`** handles `@claude` mentions in PR, review and issue comments. It runs **only if the commenter's `author_association` is `OWNER`**, which is the same quota protection on a public repo. Model: Sonnet by default; `@claude opus …` selects Opus for hard problems.
- **`REVIEW.md`** sets:
  - **Review passes**: bugs/correctness, security (OWASP basics, secrets, injection), conformance to `spec.md` / `plan.md` (does the diff match "Files that change"?), test adequacy, cost (new always-on resources, missing timeouts).
  - **Severity**: Important or Nit, with at most 5 nits.
  - **Skip**: generated files, lockfiles, anything lint/CI already enforces.
  - Findings never approve or request changes. They are posted as a comment review only.

### 4.5 Bot identity (Decision 5)

- **A GitHub App** owned by the owner, installed only on the repos that use the template.
  - Name: `<owner>-agent-bot`.
  - Permissions: contents RW, pull requests RW, checks RW, issues RW, metadata R.
  - Check runs can only be created by GitHub Apps, which is a second reason for the App.
- **`scripts/bot-token.sh`** mints a 1-hour installation token from the App private key, which is stored in the macOS Keychain on each of the owner's computers. Antigravity runs and Claude Code build sessions export `GH_TOKEN=$(scripts/bot-token.sh)` before `git push` / `gh pr create`. Commits are authored as the bot, with `Co-Authored-By` crediting the agent.
- **Why this works**: the bot authors, Claude reviews (advisory), the owner approves. The owner isn't the author, so the approval is real.
- **Amendment 2 (accepted 2026-11-16, [intent 0002](../0002-bot-identity-any-device/intent.md)): bot identity from any device.** The Keychain-only key kept agents on other PCs, phones (through Codespaces) and cloud sessions from acting as the bot. [Spec 0002](../0002-bot-identity-any-device/spec.md) replaces that in two phases:
  - **Phase 1:** a Codespaces user secret.
  - **Phase 2:** a token broker on Cloudflare Workers. It checks a login-only GitHub App token against the owner's ID and mints 1-hour, one-repo bot tokens. It also offers a relay, so cloud sessions commit and open PRs as the bot, and it sets new repos' bot secrets.

  The Keychain path stays as the Mac fallback. Spec 0002 is the authority for the design; the build is M2 step 7 in `plan.md`.

### 4.6 Ruleset on the default branch (`.github/rulesets/main.json`)

| Rule | Setting |
|---|---|
| Restrict deletions, block force pushes | on |
| Require linear history | on (squash merge only) |
| Require a pull request | 1 approving review; dismiss stale approvals on push; require approval of the most recent push; require conversation resolution |
| Required status checks | `ci-ok` only. "Require branches to be up to date" is **off**, which saves CI minutes; the merge queue isn't needed for a solo project. |
| Code owners | `CODEOWNERS` → the owner; code-owner review **not** required, so the bot can approve Dependabot patch PRs (C1). See plan.md Deviations, 2026-11-15. |
| Bypass list | **Repository admin, bypass mode "pull requests only"**. The owner can merge their *own* PRs without an approval but still can't push directly to `main` (C4). The bot App is **not** on the bypass list. |

### 4.7 Dependabot (`.github/dependabot.yml` + `dependabot-automerge.yml`)

- **Ecosystems**: the stack's (`npm` / `pip` / `gomod`), `github-actions`, `docker`.
- **Schedule**: weekly, Monday. All non-security updates in one group per ecosystem, so there are fewer PRs and fewer CI runs.
- **Auto-merge workflow**: triggered on `pull_request` from `dependabot[bot]`.
  - It uses `dependabot/fetch-metadata`. If `update-type == semver-patch`, the bot App approves the PR and enables `gh pr merge --auto --squash`.
  - GitHub then merges once `ci-ok` passes. Minor and major updates, security ones included, stay open for the owner: the bot App can't read Dependabot alerts, so it can't tell a security update apart (amended 2026-11-15, see plan.md Deviations).
- **Secrets**: workflows triggered by Dependabot can't read normal Actions secrets, so the bot App key goes into **Dependabot secrets** as well.
- ⚠ verify: community reports suggest that ruleset bypass behaves differently on the deferred auto-merge path. This design avoids bypass entirely: the bot gives a real approval and Dependabot is the author. `plan.md` must prove it with a real Dependabot PR (C1).

### 4.8 Antigravity integration (FR-4, Decision 2)

```
scripts/agy-run.sh <swarm|boost|teamwork> intent/<id>/plan.md
```

1. Creates the worktree and branch `agy/<id>-<slug>` and pushes it as the bot.
2. Opens a **draft PR** as the bot. The body links intent, spec and plan.
3. Creates check run `antigravity/<mode>` with status `in_progress`.
4. Runs the Antigravity CLI headless with the plan as input and JSON event-stream output.
   - ⚠ verify the exact flags. Third-party docs describe `agy -p … --headless --approve <policy>` and a stream of JSON events with a `type` field. The real behaviour of `/swarm`, `/boost` and `/teamwork` is unconfirmed.
   - Writes are auto-approved only inside the worktree; `--approve all` is never used outside a sandbox.
5. Pipes the events through `scripts/agy-events.sh` (jq, no AI). It maps event types to updates: check-run summary and text updates (throttled to one every 30 s) and a PR comment for each completed or failed task.
6. On exit:
   - Success → completes the check run and marks the PR ready for review, which triggers `pr.yml`.
   - Failure → marks the check run failed and posts the last error events.
7. **Claude Code side**: Claude Code watches the PR, using the desktop app's PR monitor or `gh pr checks --watch` under a non-AI monitor, so it wakes only on state changes. On a failed or blocked check run, Claude Code reads the events, updates `plan.md` if reality diverged, and either fixes the problem itself (subagents) or re-runs `agy-run.sh`.

Fallback if headless Antigravity can't run slash-command modes: the owner starts the mode interactively, and Antigravity is told (in `AGENTS.md`) to run `scripts/agy-report.sh <event>` at each milestone. The GitHub channel stays the same.

### 4.9 One-time setup

**Once per owner**
1. Create the GitHub App (manifest in `scripts/bot-app-manifest.json`) and install it.
2. Generate `CLAUDE_CODE_OAUTH_TOKEN`.
3. Create an account on each deploy target you plan to use (GCP billing account, Cloudflare free account). GitHub Pages and `none` need nothing.

**Once per machine**: run `make machine-setup`. It:
1. checks `gh`, `agy`, `claude`, `jq`, `docker` and `actionlint`, plus the CLI each installed adapter needs (`gcloud`, `wrangler`);
2. imports the App private key into the Keychain;
3. runs `gh auth status` and the adapter CLI's login.

**Once per project** (`make bootstrap`) sets:
- **Repo secrets**: `CLAUDE_CODE_OAUTH_TOKEN`, `BOT_APP_PRIVATE_KEY`, also mirrored to Dependabot secrets.
- **Repo variables**: `BOT_APP_ID`.
- **Adapter variables and secrets**: whatever the chosen adapter's `target.yml` declares. For example:
  - `cloud-run`: `GCP_PROJECT_ID`, `GCP_REGION` (default `us-central1`), `WIF_PROVIDER`, `DEPLOY_SA`
  - `cloudflare-workers`: `CLOUDFLARE_ACCOUNT_ID` plus the Environment secret `CLOUDFLARE_API_TOKEN`

It reads the secret values from the Keychain or a prompt and never writes them to disk.

### 4.10 Deploy pipeline: `.github/workflows/deploy.yml` (FR-8, FR-9, FR-13)

**Trigger**: `push` to `main`. **Concurrency**: `deploy`, `cancel-in-progress: false` (never cancel a deploy halfway).

The workflow knows nothing about any particular host. It calls `scripts/deploy.sh <verb>`, which hands each verb to the adapter named in `deploy.yml` (§4.11). **Switching targets never requires editing a workflow.**

| Job | Runs when | What it does |
|---|---|---|
| `classify` | always | `classify.sh HEAD~1...HEAD`, and reads `target` from `deploy.yml` |
| `artifact` | class = code **and** target ≠ `none` | `make build` once, tagged with the commit SHA, then `deploy.sh publish <sha>` (image push, bundle upload or Pages artifact) |
| `dev` | after artifact, if the adapter supports a dev environment and `deploy.yml` enables it | `release` composite, environment `dev` (no reviewer) |
| `production` | after dev succeeds (or after artifact if there is no dev) | Environment **`production`** with the owner as **required reviewer** and deployment branch `main` only. Same composite |
| `report` | `if: failure()` | Opens an issue labelled `deploy-failure` with test output, then runs `claude -p` read-only triage (Sonnet, `--max-turns 5`, read-only tools) and appends its summary as a comment |

**`release` composite** (shell, no AI). It runs the same sequence for every target:

1. `PREV=$(deploy.sh current <env>)`. Then a **baseline**: one live test (step 5's check; a failure is retried once) against `deploy.sh url <env>`. It is logged and never fails the release (amended 2026-11-24, see plan.md Deviations).
2. **Dark deploy**: `CANDIDATE_URL=$(deploy.sh deploy-dark <env> <sha>)`. The new version is deployed but receives no traffic.
3. **Pre-traffic test**: `make smoke URL=$CANDIDATE_URL`. On failure: `deploy.sh discard <env>`, fail, and send no traffic.
4. **Promote**: `deploy.sh promote <env> <sha>`
5. **Live test**: `make smoke URL=$(deploy.sh url <env>)` three times, 60 s apart, plus `/health`. All must pass. Count and interval are set in `deploy.yml`.
6. **Auto-revert** on failure: `deploy.sh revert <env> $PREV`. Then re-run the live test to confirm the revert, and fail the job. The re-check always runs. If it fails and `PREV` failed the baseline too (on a first deploy, bootstrap's placeholder), the job fails with "not healthy before this release either: fix forward" instead of "NOT confirmed healthy: manual action needed", unless `PREV`'s `/health` passed at the baseline (retried once) and fails after the revert, or the URL can't be read: then the revert lost service, and it is "NOT confirmed". `/health` decides because it doesn't depend on the new commit's smoke tests, which a healthy `PREV` can fail (amended 2026-11-24, see plan.md Deviations).
7. `deploy.sh cleanup <env>`: removes candidate tags and prunes old versions.

If an adapter declares `dark_deploy: false` (e.g. GitHub Pages), steps 2–3 become a smoke test against the built artifact served locally inside the job (`deploy.sh preview <env> <sha>` prints its local URL; `discard` stops it), and step 4 is the deploy itself. Steps 5–7 are unchanged (C9).

The owner's production approval covers the automatic revert (intent §6). Rolling forward again needs a new PR.

**Test safety (C2)**:
- `make smoke` runs **only tests marked `prod-safe`**: read-only, or using dedicated test accounts.
- The pre-traffic candidate shares production data, so it gets the same `prod-safe` suite.
- The full acceptance suite runs only in CI containers (§4.3) and against dev.

### 4.11 Deploy targets (pluggable adapters, FR-13)

**Choosing a target.** Each project picks its target in `deploy.yml` at bootstrap time (`TARGET=`), based on what the project needs:

```yaml
target: cloud-run            # cloud-run (default) | cloudflare-workers | github-pages | none
environments:
  dev:        { enabled: true }
  production: { approval: required }
smoke:
  live_checks: 3
  interval_seconds: 60
```

To change the target later, edit `deploy.yml` and run `make bootstrap-target`, which provisions the new adapter and sets its variables and secrets. Workflows stay the same.

**Adapter contract.** Each adapter is a folder `deploy/targets/<name>/` containing:

| File | Purpose |
|---|---|
| `target.yml` | Capabilities and requirements: artifact type, `dark_deploy` true/false, `environments` supported, auth type (`oidc` / `token`), required repo variables and Environment secrets, the CLI it needs, and a one-line **"$0 when idle because…"** statement |
| `bootstrap` | Idempotent provisioning. **Must** set the target's cost caps and a budget alert wherever the target can bill a card |
| `publish <sha>` | Upload the built artifact |
| `current <env>` | Print the live version ID |
| `deploy-dark <env> <sha>` | Deploy without traffic and print the candidate URL |
| `promote <env> <sha>` | Send 100% of traffic to the version |
| `revert <env> <version>` | Restore that version within NFR-8 (2 minutes) |
| `url <env>` | Print the live URL |
| `discard <env>` / `cleanup <env>` | Remove the candidate / prune old versions and artifacts |
| `preview <env> <sha>` | Only with `dark_deploy: false`: serve the artifact on localhost inside the job and print its URL, for the pre-traffic test (C9) |

Every verb supports `DEPLOY_DRY_RUN=1`, which prints the commands instead of running them. The template self-test runs every adapter in dry-run mode.

**Adapters shipped in the first release**

| Adapter | Best for | Artifact | Dark deploy → promote → revert | Auth | $0 when idle because | Cost cap |
|---|---|---|---|---|---|---|
| **`cloud-run`** (default) | Containers, full backends, APIs | Image in Artifact Registry | `gcloud run deploy --no-traffic --tag c<sha>` → `update-traffic --to-latest` → `update-traffic --to-revisions $PREV=100` | Workload Identity Federation (OIDC, no keys) | Request-based billing, `min-instances 0` | `max-instances 2`; GCP budget $10 with alerts at $1/$5/$10 |
| **`cloudflare-workers`** | Edge APIs, web apps, light backends | Worker bundle | `wrangler versions upload` (preview URL) → `wrangler versions deploy <id>@100%` → `wrangler rollback <prev>` ⚠ verify | Least-privilege API token (Workers edit, one account) stored as a GitHub **Environment** secret (C10) | Workers Free plan; no card on file ⚠ verify how over-quota requests are handled | Free plan only. Upgrading to paid is a new intent |
| **`github-pages`** | Static sites, docs, and any stack through its `make build-static` export | Static directory (`dist/static`) | `dark_deploy: false`: `preview` serves the export on localhost for the pre-traffic smoke → `promote` commits it to the `gh-pages` branch (fast-forward) and waits for the Pages build → `revert` commits an earlier version's files (amended 2026-11-18, see plan.md Deviations) | The job's `GITHUB_TOKEN` with `contents: write`, `pages: write`; no stored secret | Free on public repos | n/a |
| **`none`** | Libraries, CLIs, docs-only repos, **this template repo itself** | — | No deploy. The `artifact` job and everything after it are skipped | — | Nothing is provisioned | — |

**`cloud-run` adapter details** (`deploy/targets/cloud-run/bootstrap`, idempotent gcloud, no Terraform):
- **One GCP project per app.** Region `us-central1`, a Tier 1 region where the free tier applies (⚠ verify current free-tier figures on the official pricing page).
- **Workload Identity Federation**: pool `github`, provider restricted to `repository == <owner>/<repo>`.
- **Deploy service account** with `roles/run.developer`, `roles/artifactregistry.repoAdmin` on the `app` repository only (promote moves image tags, which needs `tags.delete`), and `roles/iam.serviceAccountUser` on the runtime SA only.
- **Artifact Registry** repo `app` with a cleanup policy: keep the last 5 images, delete untagged images after 7 days and tagged images after 30 days, but never the images tagged `dev`/`production` (and `-prev`) by promote and revert (protects the 0.5 GB free storage; amended 2026-11-15, see plan.md Deviations).
- **Cloud Run services** `<app>-dev` and `<app>-prod`, with `--cpu 1 --memory 512Mi`. The runtime SA has no roles unless the app needs them.
- Why gcloud scripts rather than Terraform: no state bucket to pay for or secure, and fewer moving parts for a solo project. Revisit if resources grow beyond about 10.

**`cloudflare-workers` adapter details**: workers `<app>-dev` and `<app>`. `wrangler.toml` is generated by `bootstrap` with `preview_urls = true`, which the dark deploy needs. The API token is scoped to Workers Scripts edit on one account and readable only by the `dev` / `production` Environments.

**Adding another adapter** (e.g. Vercel, Fly.io, AWS App Runner / Lambda, Azure Container Apps) takes its own small intent. The new adapter must:
1. implement every verb in the contract and pass the dry-run self-test;
2. support a dark deploy, or declare `dark_deploy: false` and use the local pre-traffic test;
3. revert within NFR-8;
4. declare a $0-when-idle path, or have `bootstrap` create a budget alert.

### 4.12 Maintain: `.github/workflows/maintain.yml`

| Schedule | Job | Breach → |
|---|---|---|
| Daily 06:00 UTC | `make smoke URL=$(scripts/deploy.sh url production)` (skipped when target = `none`) | Issue `prod-smoke-failure` + draft `intent/` stub |
| Weekly Mon | CodeQL full scan (`pr.yml` also triggered on `schedule`); delete merged branches older than 14 days; delete stale `agy/*` branches whose PRs are closed | Issue on any CodeQL alert ≥ high |
| Monthly 1st | `scripts/sdlc-metrics.sh` (§7) posts a metrics issue; checks the age of `CLAUDE_CODE_OAUTH_TOKEN` and of any adapter API tokens | Renewal issue at 11 months |

These jobs never call AI. When the owner picks up an issue, they triage it in an interactive Claude Code session via `/intent --from-issue <n>` (intent §2).

### 4.13 Claude Code configuration

- **`CLAUDE.md`** (under 1 page) has sections Commands, Conventions, Architecture, Verification and Things Claude gets wrong.
  - Verification lists the `make` targets with what healthy output looks like.
  - Rules: start in plan mode; push only via bot token; never touch `main`.
- **`.claude/settings.json` hooks** (fast, limited to the changed file):

  | Event | Hook | Effect |
  |---|---|---|
  | PostToolUse (Edit/Write) | `make fmt FILE=$path && make lint FILE=$path` | Auto-format; lint errors are fed back |
  | PreToolUse (Edit/Write) | `scripts/hooks/protect-paths.sh` | **Block** edits to `.github/rulesets/**`, generated files and lockfiles (except via a package manager) |
  | PreToolUse (Edit/Write/Bash) | `scripts/hooks/no-secrets.sh` (gitleaks on the content) | **Block** any content containing a secret |
  | PreToolUse (Edit/Write) | `scripts/hooks/test-first.sh` | When the branch is `fix/*`, **block** edits to test files after the first commit, so the failing test is written and committed first |
  | PreToolUse (Bash) | deny `git push * main`, `git push --force*`, `scripts/deploy.sh promote\|revert`, and target CLIs' traffic commands (`gcloud run services update-traffic`, `wrangler versions deploy`, `wrangler rollback`) | Agents never push to `main` and never change production |

- **Subagents** in `.claude/agents/`:
  - `verifier`: fresh context, read-only plus `make`. Final check against `plan.md` "Proof".
  - `test-writer`: tests only, can't edit `src/`.
  - `researcher`: read-only plus web.
  - `simplifier`: refactor only; tests must stay green.
- **Commands**:
  - `/intent`: interactive brainstorm → `intent.md`.
  - `/spec`: intent → spec.
  - `/plan`: spec → plan, in plan mode.
  - `/sweep`: on a Claude- or bot-opened PR, loops over unresolved review comments and failing checks until only the owner's approval is left.
- **Agent teams**: `plan.md` "Order of work" marks independent steps. Claude Code runs them as parallel worktree sessions: up to 3 by default, more only while review keeps up.

## 5. Flagged concerns and policy conflicts: resolved by the owner (interactive session, 2026-11-15)

| # | Concern | Conflict | **Decision** |
|---|---|---|---|
| **C1** | Dependabot auto-merge vs "1 owner approval required" | Auto-merge needs an approval that isn't the owner's | **The bot App approves only Dependabot security and patch PRs**, through a deterministic workflow and never through an agent session. Dependabot is the author, so the approval is valid. Must be proven with a real Dependabot PR in Build. |
| **C2** | Live tests hit production data | "Test the live app" vs "don't damage prod" | **Only `prod-safe` tests run against production**, both pre-traffic and live. The full acceptance suite runs only in CI containers and dev (§4.10). |
| **C3** | "All checks before Claude review" vs CodeQL default setup | Default setup runs outside our workflow, so `needs:` can't wait for it | **CodeQL advanced setup inside `pr.yml`**. It adds a few minutes per code PR, which is free on public repos. |
| **C4** | Owner can't approve their own PRs | The required approval would block owner-authored PRs | **Repository admin bypass in "pull requests only" mode, and never a direct push to `main`.** The owner merges their own PRs without an approval, and `ci-ok` still has to pass. Emergencies also go through a PR. There is no break-glass switch. Agent PRs still need the owner's approval. |
| **C5** | Bot App key on several computers | Portability (NFR-7) vs key sprawl | **App private key in each Mac's Keychain**, minting 1-hour tokens, with yearly key rotation (a `maintain.yml` reminder issue). No machine-user account. |
| **C6** | Claude-authored PRs reviewed by Claude | "The agent that wrote the code can't approve it" | **Accepted as designed.** The review is advisory, runs as a separate session and identity, and only the owner approves. For Claude-built PRs, `REVIEW.md` asks for extra checking of the `spec.md` / `plan.md` match. |
| **C7** | Pro limit shared between CI and interactive work | Decision 4 vs available capacity | **Quota guards only, with no API-key fallback** (§4.4). When the Pro limit is hit, `claude-review` exits *neutral* and comments "Review skipped: Claude Pro limit reached. Comment `@claude review` later." It never fails `ci-ok` and never switches to paid API usage. |
| **C8** | Antigravity CLI behaviour unverified | The design depends on headless mode and its event stream | **Spike first.** `plan.md` step 1 is a time-boxed spike proving headless `agy`, `/swarm` / `/boost` / `/teamwork` and the event stream. If it fails, use the §4.8 fallback (interactive Antigravity + `agy-report.sh`). |
| **C9** | Some targets can't deploy without traffic (GitHub Pages) | FR-9 "pre-traffic test" vs target capability | **Accepted for static sites.** The adapter declares `dark_deploy: false`, and the pre-traffic test runs against the artifact served locally in the job. Live test and revert still apply. A host with server-side code *and* no dark deploy needs its own intent. |
| **C10** | Some targets have no GitHub OIDC federation (likely Cloudflare ⚠ verify) | NFR-4's no-long-lived-keys preference | **Least-privilege token** (Workers edit, one account) readable only by the `dev` / `production` Environments, with a yearly rotation issue from `maintain.yml`. Prefer keyless targets when they fit the project equally well. |

## 6. Skills this spec introduces (they constrain future specs)

| Skill | Triggers when | Enforced by (skills are advisory) |
|---|---|---|
| `write-intent` | Brainstorming a new change | PR template check: an `intent/` link is required |
| `write-spec` | An intent is accepted | `hygiene` job: a spec must exist before `code` PRs touching `src/` (warning only at first) |
| `write-plan` | A spec is accepted | `pr_template` checkbox + `verifier` subagent |
| `secure-change` | Editing auth, input handling, secrets or IaC | `secrets`, `codeql` and `dependency-review` jobs; `no-secrets` hook |
| `cost-guard` | Adding any cloud resource or workflow | `REVIEW.md` cost pass; each adapter's `bootstrap` sets its cost caps and budget alert, and `target.yml` must contain a "$0 when idle" statement; `actionlint` rule that every job sets `timeout-minutes` |

## 7. Metrics (per playbook play: leading / lagging)

`scripts/sdlc-metrics.sh` gathers these from the GitHub API and the adapter's CLI, with no AI:

| Play | Leading | Lagging |
|---|---|---|
| Plan / Design | Time from first commit to merged intent; from intent to spec | Spec commits after the first plan (rework) |
| Build | Antigravity runs per PR; Claude interventions per Antigravity run | First-pass `ci-ok` success rate |
| Review | Claude reviews per PR (quota); time to first review | Defects found after merge (deploy failures, reverts) |
| Deploy | Lead time from merge to production; docs-only merges skipped | Change failure rate (auto-reverts ÷ production deploys); time to restore |
| Maintain | Time from breach issue to intent | Production incidents found by the daily smoke test vs by users |
| Cost | Actions minutes and Claude reviews per month | Deploy-target spend per month (target $0) |

## 8. Acceptance criteria for this template (the "Proof" that `plan.md` must satisfy)

1. From a clean machine (after the one-time setup), `gh repo create … --template` + `make bootstrap STACK=<s>` succeeds for **node, python and go**, with no manual GitHub-UI steps.
2. A PR with a lint error fails `ci-ok`, and **`claude-review` does not run**.
3. A docs-only PR passes `ci-ok` with only hygiene and secrets jobs running, gets no Claude review, and its merge **triggers no image build or deploy**.
4. A code PR from the bot runs every tier, gets one advisory Claude review, can't merge without the owner's approval, and deploys to dev then waits for production approval.
5. On **each shipped adapter except `none`**, a production deploy whose live smoke test is deliberately broken **reverts automatically** within 2 minutes (NFR-8), opens an issue, and attaches a triage comment.
6. A Dependabot patch PR merges with no human action. A minor update waits.
7. An `@claude` comment from a non-owner account does nothing.
8. `agy-run.sh` produces a draft PR with a live-updating `antigravity/<mode>` check run, and Claude Code is woken by its completion.
9. An idle project shows **$0** spend on its deploy target after 30 days. Where the target can bill, the budget alert is configured.
10. The template's own self-test CI (`.template/selftest.yml`) passes: actionlint, shellcheck, markdownlint, bootstrap dry-runs for all three stacks, and `DEPLOY_DRY_RUN=1` runs of every adapter verb.
11. Changing `target` in `deploy.yml` and running `make bootstrap-target` moves an existing project's deploys to the new adapter **without any workflow file changing**.
12. Following `README.md` **word for word** on a clean machine produces a working project, and its final step, `make doctor`, passes with every check green (FR-14, FR-15).
13. **Amendment 2:** the owner acts as the bot from a non-Mac device and from a cloud session (whose PR the owner approves without the admin bypass), and bootstraps a project without a Mac. Each of these is checked as in [spec 0002's acceptance criteria](../0002-bot-identity-any-device/spec.md#acceptance-criteria) 1–14.

---

*To accept: the owner reviews this spec, confirms the C1–C10 decisions recorded in §5, then commits/merges it. Acceptance starts Stage 3: Claude Code plan mode reads this spec and interviews the owner to produce `plan.md`. Its first step is the Antigravity headless spike (C8), because §4.8 depends on it.*
