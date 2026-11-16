# Plan: 0001 GitHub + CI/CD template — build

> Stage 3 (Build) artifact. **Accepted** by the product owner on 2026-11-15 in plan mode.
> Sources: [`intent.md`](intent.md) (accepted, + Amendment 1), [`spec.md`](spec.md) (accepted, PR #1, `083d256`).

## Context

The intent and spec are accepted. This plan builds `Jomaries777/template-repo-ci` into a working GitHub template that meets spec acceptance criteria 1–12. Choices from the plan-mode interview:

- **Slicing**: milestones, thin slice first. Each milestone is 1–3 PRs and usable on its own.
- **Builder**: Claude Code (subagents + parallel worktree sessions) builds M0–M1, including the Antigravity bridge. **From M2 on, Antigravity is the primary builder** via `scripts/agy-run.sh`, which dogfoods the design. Claude Code orchestrates and steps in on failure.
- **First vertical slice**: Node + Cloud Run.
- **Owner readiness**: GCP billing account ✔, Antigravity CLI ✔. Still to do: the Cloudflare account (needed in M3), the GitHub App, the Claude setup-token, and missing tools.

Facts found during plan mode (they reduce C8 risk):
- `agy` 1.5.9 is installed and supports `-p`, `--output-format stream-json`, `--mode auto|accept-edits|plan`, `--sandbox` and `--print-timeout`.
- `/swarm`, `/boost` and `/teamwork` are **built-in** agy commands. The changelog confirms `agy -p` can start a swarm, and that `/swarm` is "Quota Heavy".
- Tools: `gh`, `gcloud`, `claude`, `jq`, `docker` and `python3` are present. **Missing**: `actionlint`, `shellcheck`, `node`, `go`, `wrangler`.

## Files that change

| Area | Paths |
|---|---|
| Loop artifacts | `intent/0001-…/plan.md` (this file), status lines in `intent.md` / `spec.md`, `intent/0001-…/spikes/*.md` and fixtures. M2 also amends `spec.md` §4.1, §4.7 (FR-7) and §4.11 where the owner accepted a change (each marked "amended 2026-11-15" and recorded in Deviations) |
| Agent config | `CLAUDE.md`, `AGENTS.md`, `REVIEW.md`, `.claude/settings.json`, `.claude/{agents,commands,skills}/**`, `scripts/hooks/*.sh` |
| Repo scaffolding | `.gitignore`, `.github/{CODEOWNERS,pull_request_template.md,dependabot.yml,rulesets/main.json}`, `Makefile`, `README.md` |
| CI | `.github/workflows/{pr,claude,deploy,dependabot-automerge,maintain}.yml`, `.github/actions/{release,target-auth}/action.yml`, `.github/workflows/template-selftest.yml` (not `.template/selftest.yml`, see Deviations) |
| Scripts | `scripts/{classify,gh-settings,bootstrap,doctor,bot-token,agy-run,agy-events,agy-report,deploy,deploy-base,deploy-config,release,sdlc-metrics}.sh`, `scripts/bot-app-manifest.json`, `tests/scripts/**` (plain-bash tests with fixtures) |
| Stacks | `stacks/{node,python,go}/**`: hello service with `/healthz`, lint/type/test configs, Dockerfile, acceptance suite (service containers), `prod-safe` smoke tag |
| Deploy adapters | `deploy.yml` (written by bootstrap), `deploy/targets/{cloud-run,none,local,github-pages,cloudflare-workers}/{target.yml,lib.sh,bootstrap,publish,current,deploy-dark,promote,revert,url,discard,cleanup}` |

## Order of work

Each milestone ends in PRs that the owner approves and merges. **Owner** marks a step only the owner can do.

### M0: Plan, owner setup, spikes (PR #2)
1. Commit this plan as `plan.md`, and flip the `spec.md` / `intent.md` status lines to Accepted.
2. **Owner**: `brew install actionlint shellcheck node go` (`wrangler` goes in M3 via npm).
3. **Owner**: create the GitHub App from `scripts/bot-app-manifest.json`, which Claude writes. Install it on `template-repo-ci` and import the private key into the Keychain.
4. **Owner**: run `claude setup-token` and set the repo secret `CLAUDE_CODE_OAUTH_TOKEN`.
5. **Spike A (C8, time-box 1 h)**: in a throwaway worktree, run `agy -p "/boost <trivial task>" --output-format stream-json --mode auto --sandbox`, then the same with `/teamwork` and a tiny `/swarm`.
   - Record the event schema in `spikes/agy-events.md`, and save sample NDJSON as test fixtures.
   - **Gate**: headless works → §4.8 primary design. Otherwise → the §4.8 fallback.
6. **Spike B**: a minimal `claude-code-action` workflow on a throwaway PR proves the Pro OAuth token works. Record the result. On a 401, regenerate the token; there is no API fallback (C7).
7. **Spike C**: `bot-token.sh` mints an installation token and creates a check run on the spike PR.

### M1: Template core; the template dogfoods its own CI (PRs #3–#5, three parallel tracks)
- **Track A, agent config**:
  - `CLAUDE.md` (under 1 page), `AGENTS.md` (points to `CLAUDE.md`), `REVIEW.md`
  - hooks in `.claude/settings.json` plus `scripts/hooks/{protect-paths,no-secrets,test-first}.sh`
  - subagents (verifier, test-writer, researcher, simplifier)
  - commands (`/intent`, `/spec`, `/plan`, `/sweep`)
  - 5 skills
- **Track B, CI**:
  - `.gitignore`, CODEOWNERS, PR template, `dependabot.yml` (github-actions)
  - `classify.sh` + tests, and the `Makefile` (template targets: `lint` = shellcheck + actionlint + markdownlint, `test` = script tests)
  - `pr.yml` with all tiers + `ci-ok`, `claude.yml` (OWNER-only), `.template/selftest.yml`
  - SHA-pinned actions and `timeout-minutes` everywhere
- **Track C, identity and bridge**:
  - `bot-token.sh`
  - `agy-run.sh` / `agy-events.sh`, tested against the Spike A fixtures. Headless is used for `/boost` and plain prompts. Success requires a tool-verified diff plus `make lint test`, never `result.status` alone.
  - `agy-report.sh`: the **required** path for `/teamwork` and `/swarm`, which run interactively (Spike A finding)
- **Then (serial)**: `gh-settings.sh` and `rulesets/main.json`, applied to this repo. It enables secret scanning + push protection and private vulnerability reporting, applies the ruleset (admin bypass in PRs-only mode), and marks the repo as a template. From here on, every change goes through PRs and `ci-ok`.

### M2: Node + Cloud Run vertical slice, built by Antigravity (PRs #6–#8)

Built with headless `agy-run.sh boost …` for focused steps, and interactive `/teamwork` (or `/swarm`) + `agy-report.sh` for wide steps.
1. `stacks/node`: hello service, ESLint/Prettier/tsc/Vitest, Playwright acceptance against compose service containers, Dockerfile, `prod-safe` smoke.
2. Deploy contract: `scripts/deploy.sh` dispatcher with `DEPLOY_DRY_RUN`, plus `deploy/targets/cloud-run/*` (WIF, Artifact Registry + cleanup policy, `<app>-dev` / `<app>-prod`, min 0 / max 2 instances, $10 budget) and `deploy/targets/none`. Runs in parallel with step 1.
3. `deploy.yml` + the `release` composite (dark deploy → pre-traffic test → promote → live test ×3 → auto-revert → report with `claude -p` triage). Depends on step 2.
4. `bootstrap.sh` (STACK/TARGET, cleanup, secret prompts, README stub) and `doctor.sh` (FR-15). Depends on steps 1 and 2.
5. `dependabot-automerge.yml` (bot approves patch PRs, C1; minor and major updates, security ones included, wait for the owner). Independent of the other steps.
6. **E2E on a sandbox repo** `sandbox-node-cloudrun` (public, created from the template): prove criteria 1–8 for this slice, including a deliberately broken live smoke test → auto-revert in under 2 min, and a real Dependabot patch auto-merge. Owner setup on the Mac: [spikes/m2-step6-owner-setup.md](spikes/m2-step6-owner-setup.md); the rest runs from a cloud session. Split by the owner (2026-11-15): **6a** first runs it with the test-only `local` target, which needs no cloud account, and **6b** repeats the deploy and revert parts on Cloud Run later.

### M3: Remaining stacks and adapters (PRs #9–#12, all four in parallel)
- `stacks/python`, `stacks/go`
- `deploy/targets/github-pages` (`dark_deploy: false`, C9)
- `deploy/targets/cloudflare-workers`: **Owner** creates the Cloudflare account and scoped token. First run a short spike verifying the `wrangler versions upload/deploy` and `rollback` commands and the free-plan behaviour (C10).
- Each gets dry-run self-tests, and the two new adapters get one live sandbox E2E each (deploy, revert).

### M4: Maintain, metrics, docs (PRs #13–#14)
- `maintain.yml` (daily prod smoke, weekly CodeQL and branch cleanup, monthly `sdlc-metrics.sh` and token-age check) and `sdlc-metrics.sh`.
- `README.md` "Start a new project" quick-start (FR-14). Then follow it word for word in a fresh clone and a new sandbox repo (criterion 12).

## Progress

| Milestone | Status | PRs |
|---|---|---|
| M0: plan, owner setup, spikes | ✅ Done | Jomaries777/template-repo-ci#2 (spike, closed), Jomaries777/template-repo-ci#3 |
| M1: template core | ✅ Done. The ruleset and repo settings are applied with `scripts/gh-settings.sh --template`, and the repo is a template | Jomaries777/template-repo-ci#4 (CI), Jomaries777/template-repo-ci#5 (agent config), Jomaries777/template-repo-ci#6 (agy bridge), Jomaries777/template-repo-ci#7 (settings and ruleset) |
| M2: Node + Cloud Run slice | In progress (cloud session, owner PRs). Steps 1–5 merged (#9–#18). Step 6a (`local` target) passed on 2026-11-16 for criteria 1, 3, 4 and 5 ([results](spikes/m2-step6a-results.md)); its Dependabot test (criterion 6) waits for the bot key, and 2, 7 and 8 were not run there (the results say where each is proven). Step 6b (Cloud Run) not started | Jomaries777/template-repo-ci#9, #10, #11, #12, #13, #15, #16, #17, #18; sandbox: Jomaries777/sandbox-node-local#1, #2, #3, #5 |
| M3: remaining stacks and adapters | Not started | — |
| M4: maintain, metrics, docs | Not started | — |

## Deviations

| Date | Change | Why |
|---|---|---|
| 2026-11-15 | `/teamwork` and `/swarm` run interactively and report through `agy-report.sh`. Headless is only for `/boost` and plain prompts. `--mode auto` is not used. | [Spike A](spikes/m0-spike-a-antigravity.md): headless `/teamwork` returned `SUCCESS` without changing the workspace, and `--mode auto` isn't available on this account |
| 2026-11-15 | `scripts/bot-token.sh` was built in M0, not M1 Track C. The bot App has no `workflows` permission, so workflow changes go through the owner's PRs. | Spike C needed it. Keeping agents unable to change CI is a deliberate guardrail ([Spikes B/C](spikes/m0-spike-b-c-ci-identity.md)) |
| 2026-11-15 | The Claude token is stored with `pbpaste \| tr -d '[:space:]' \| gh secret set …` | Spike B: the wrapped token was truncated, causing a 401 |
| 2026-11-15 | The template self-test is `.github/workflows/template-selftest.yml`, not `.template/selftest.yml` (spec §4.1). It is guarded by `if: github.repository == 'Jomaries777/template-repo-ci'`, and bootstrap (M2) deletes it. | GitHub only runs workflows from `.github/workflows/`, so a file under `.template/` would never run |
| 2026-11-15 | No `.github/actions/classify` composite. `pr.yml` calls `scripts/classify.sh` directly. The `release` composite still comes in M2. | One script is shared by PR and deploy workflows without a wrapper. Raised by Claude Code Review on #4 |
| 2026-11-15 | Dependency graph and Dependabot alerts were enabled ahead of the M1 serial step | `dependency-review` fails while the dependency graph is off (first CI run on #4) |
| 2026-11-15 | The `agy` verification gate runs `make lint test` with `Makefile` and `tests/scripts/` from `origin/main` under `env -i` (no tokens), but still as the owner's user and outside a sandbox. Agent-added tests under `tests/scripts/` are not run by the gate; that path is protected, so the owner reviews it. | Claude Code Review on #6. A container or sandbox for the gate is deferred to M2, once the Node stack shows what lint and test need |
| 2026-11-15 | The `main` ruleset doesn't require code-owner review (`require_code_owner_review: false`). It still needs 1 approval, last-push approval and resolved threads. | CODEOWNERS is `* @Jomaries777`, and the bot can't be a code owner, so code-owner review would block the bot's approval of Dependabot patch PRs (C1). The owner's own PRs merge through the PRs-only bypass (C4). |
| 2026-11-15 | The required `ci-ok` check is bound to the GitHub Actions app (`integration_id: 15368`). | A check run named `ci-ok` posted by the bot App, which has `checks: write`, can't satisfy the rule. Only the real workflow job can. |
| 2026-11-15 | M2 step 1 (`stacks/node/`) was finished by Claude Code in a cloud session as an owner PR, not by an Antigravity run. Antigravity's partial `/boost` output was kept; Claude Code added `vitest.config.ts` so Vitest stops loading the Playwright specs. A real Antigravity re-run is deferred. | The cloud session has no Antigravity and no bot key. `make acceptance` was run against an image built with the session's proxy CA added to a copy of the Dockerfile; the committed Dockerfile is unchanged. CI does not exercise `stacks/node` until bootstrap (step 4) copies it to the root; the as-is `make build acceptance` is proven on the owner's machine or in step 6 |
| 2026-11-15 | M2 step 2 (deploy contract) was finished by Claude Code in a cloud session as an owner PR. Antigravity's partial output (dispatcher, `none` adapter, `cloud-run/target.yml`) was kept; Claude Code wrote the `cloud-run` verbs, `lib.sh` and `tests/scripts/test_deploy.sh`, and made the `none` verbs executable. A real Antigravity re-run is deferred. | The cloud session has no Antigravity and no bot key |
| 2026-11-15 | Adapter verbs print only their result (URL or revision) on stdout. `DRY-RUN:` lines, progress and CLI output go to stderr. In dry run, read-only queries return built-in fixtures. | `release` captures results with `$(deploy.sh …)` (spec §4.10). Fixtures let every verb, including `cleanup`'s keep-5 logic, run without credentials. The fixtures are hand-written: the `jq` paths into `gcloud --format json` output (`status.traffic[].revisionName/percent/tag/url`, `status.url`, `metadata.name/creationTimestamp`) stay unverified until step 6 runs against a real project |
| 2026-11-15 | Cloud Run: `bootstrap` creates `<app>-dev` and `<app>-prod` once, public and idle, from Google's sample image. `deploy-dark` doesn't pass `--allow-unauthenticated`. `bootstrap` also enables `iam.googleapis.com`. | `roles/run.developer` can't set IAM policy, so the deploy SA couldn't make a new service public. The service's IAM policy persists across deploys. Service accounts and WIF pools need the IAM API |
| 2026-11-15 | `deploy.sh discard <env> <sha>` takes the SHA (spec §4.10 step 3 shows `discard <env>`). `cleanup` also removes tags from revisions at 0% traffic, so step 3's `deploy.yml` must serialize deploys per environment (a concurrency group without `cancel-in-progress`). | The candidate tag is derived from the SHA. A tagged revision can't be deleted, and an overlapping run's candidate would lose its tag |
| 2026-11-15 | The template ships a root `deploy.yml` (`target: none`); bootstrap rewrites it with the chosen `TARGET` (plan "Files that change" says bootstrap writes it). `deploy-dark` uses `--update-env-vars`, not `--set-env-vars`. | The template repo itself deploys nothing, and the dispatcher needs a config to read. `--set-env-vars` would wipe env vars set outside the deploy (Claude review on #10) |
| 2026-11-15 | The Cloud Run WIF provider admits only `refs/heads/main` of this repository (`assertion.ref`), not every ref. The deploy SA's `artifactregistry.writer` is bound on the `app` repository, not the project. | Least privilege (Claude review on #10): PR branches can't impersonate the deploy SA, and the SA can't write other registries |
| 2026-11-16 | `bootstrap.sh --skip-bot-key` sets up a project without the bot App key (no Mac Keychain, e.g. from a Codespace on a phone) and prints the Mac commands that add it later; `doctor`'s fix hint is that command. | Owner choice (option A): set up 6a from Android. The key stays only in Mac Keychains (C5), and only Dependabot auto-merge needs it in a project |
| 2026-11-15 | Step 6 is split. **6a** runs the sandbox E2E with a test-only `local` adapter (`deploy/targets/local/`): each version runs as a Docker container on the GitHub Actions runner, `current` starts the parent commit as the version to revert to, and the live URL follows the serving container. **6b** repeats deploy and revert on Cloud Run. `release.sh` now asks for the live URL again before the post-revert re-check. | Owner choice (cheaper route, no GCP). 6a proves deploy.yml, release.sh, revert, report and Dependabot for real; only 6b proves WIF, IAM, Artifact Registry, the budget and cold starts. A real run of `release.sh` against `local` here (a version that degrades after 6s) caught that the re-check reused the pre-revert URL, which Cloud Run's fixed URL had hidden. The adapter's real Docker paths (ports, state files, starting the parent commit) are tested only in dry run here; 6a in GitHub Actions is their first automated proof. The owner checklist (`spikes/m2-step6-owner-setup.md`) gains the 6a route |
| 2026-11-15 | Owner decisions after #10: (1) the Artifact Registry policy also deletes tagged images older than 30 days (the 5 newest are still kept). `promote` tags the new image `<env>` and the image of the revision serving before it `<env>-prev` (both before moving traffic), `revert` re-tags the restored image, and a `keep-deployed` rule never deletes `dev*` / `production*` tags, so the image a cold start pulls (min-instances 0) is never cleaned up. `<env>-prev` is read from the serving revision, and a retried promote (its own revision already serving) leaves it alone. Only the previous revision is protected, which is the one `release.sh` reverts to; an older revision's image may be cleaned up. No deployment predates these tags (step 6 is the first). Step 6 checks the live policy with `gcloud artifacts repositories list-cleanup-policies`, that `tagPrefixes` matches `production-prev`, that `gcloud artifacts docker tags add` moves an existing tag, and which image form `revisions describe` reports; (2) WIF bound to `refs/heads/main` is enough, without binding to the `environment` claim; (3) both services serving Google's public sample image until the first real deploy is acceptable. | (1) `publish` tags every image with its SHA, so without an age limit storage passes the free tier, breaking NFR-1's $0 when idle. (2) and (3) accepted as-is by the owner |
| 2026-11-15 | `dependabot-automerge.yml` auto-merges only `semver-patch` updates. Security updates that are minor or major wait for the owner (FR-7 says security and patch updates auto-merge). Built by Claude Code in a cloud session as an owner PR. | The bot App can't read Dependabot alerts, so the workflow can't tell a security update apart from a version update. Patch-only is the safe subset. Workflow files come from owner PRs (the bot has no `workflows` permission) |
| 2026-11-15 | M2 step 3 (`deploy.yml`, the `release` composite) was built by Claude Code in a cloud session as an owner PR, with the owner's `ALLOW_WORKFLOW_EDIT=1` override. The release sequence lives in `scripts/release.sh` and the `deploy.yml` parsing in `scripts/deploy-config.sh`, each with a test; the composite only calls the script. | Deterministic logic belongs in scripts with tests, not in workflow YAML (NFR-5). The bot can't push workflows |
| 2026-11-15 | A second composite, `.github/actions/target-auth`, does the target's OIDC sign-in (cloud-run: `google-github-actions/auth` + `setup-gcloud`; `none`: nothing). `deploy.yml` passes adapter variables (`GCP_PROJECT_ID`, `GCP_REGION`, `APP_NAME`) as workflow env. A new adapter that needs sign-in adds a branch to `target-auth`, not to `deploy.yml`. | Composite actions can't read `vars`, and the deploy, publish and release jobs all need the same sign-in |
| 2026-11-15 | `deploy.yml` classifies the range from the last successful **production** deployment (`scripts/deploy-base.sh`, from GitHub's Deployments API) to the merge, not `HEAD~1..HEAD` (spec §4.10). With no production deploy yet, the class is `code`. `release.sh` refuses to deploy unless `deploy.yml` names a stack (or `SMOKE_CMD` is set). Live checks must fit in 10 minutes (`(live_checks - 1) × interval_seconds ≤ 600`), and a failed dark deploy is discarded. | GitHub cancels a *pending* run when a newer one joins the `deploy` group, so with `HEAD~1` a docs-only merge could make an earlier code merge never deploy. Without the stack's suite, the template's stub `make smoke` would pass vacuously. The dev and production jobs time out at 20 minutes, and a timeout during live checks (after promote) would skip the revert (Claude reviews on #13) |
| 2026-11-15 | `production` refuses to deploy unless its environment has a required reviewer and a branch policy. Environments and their rules are created by bootstrap (step 4), not by `scripts/gh-settings.sh`. | GitHub creates a missing environment on first use with no protection, which would skip the owner's approval |
| 2026-11-15 | With `dark_deploy: false`, `release.sh` skips steps 2–3 and `promote` is the deploy. The local pre-traffic smoke test for such targets (spec §4.10, C9) comes with the `github-pages` adapter in M3. | No M2 adapter lacks dark deploys |
| 2026-11-15 | `report` triage uses `anthropics/claude-code-action` (as `pr.yml` does) rather than a raw `claude -p`, with the same limits: Sonnet, `--max-turns 5`, read-only tools plus `gh issue comment`. The issue links the run and lists job results instead of embedding test output; the triage comment summarises the failed log. If there is no previous revision, `release.sh` fails without reverting. | One pinned, Dependabot-updated way to run Claude in CI, with the Pro-quota OAuth token and no API key. Logs stay in Actions instead of being copied into a public issue |
| 2026-11-15 | M2 step 4 (`scripts/bootstrap.sh`, `scripts/doctor.sh`) was built by Claude Code in a cloud session as an owner PR. It is proven offline: tests for both scripts, plus bootstrapping a scratch copy (`--local-only`) and running its `make lint test` and `make typecheck`. A real run against GitHub and GCP is step 6, which must cover what fakes can't: the production reviewer and branch policy, secrets set through stdin (and that the bot key without a trailing newline works with `create-github-app-token`), the interactive prompts, and the PR path on an already-protected repo. | The cloud session has no bot key, no Keychain and no GCP project |
| 2026-11-15 | The chosen stack stays in `stacks/<stack>/`. Bootstrap writes `stack: <name>` to `deploy.yml`; the root `Makefile` runs repo-level checks and then the same target in the stack; `deploy.sh` uses the stack folder as the image build context. Spec §4.1's text says bootstrap copies the stack to the root, but its layout says the Makefile delegates to `stacks/<stack>/`. | Copying would run the stack's `prettier --check .` and ESLint over the whole repo (workflows, Markdown, scripts) and replace the root `Makefile`, which also lints shell and workflows |
| 2026-11-15 | Bootstrap also deletes the template's own `intent/` folders and `tests/scripts/test_bootstrap.sh`. It creates the `dev` and `production` Environments itself; `gh-settings.sh` does not. On a new repo it pushes the bootstrap commit to `main` before `gh-settings.sh` applies the ruleset; on a rerun after that it opens a PR, and it stops without pushing if the rulesets can't be read. The Claude token is read from the Keychain service `claude-code-oauth-token` or a hidden prompt. | A project starts its own intent history. The bootstrap test only makes sense in the template. A new repo's `main` is unprotected until the ruleset is applied, and pushing first avoids an owner PR for generated files |
| 2026-11-15 | `doctor.sh` reports SKIP, not FAIL, for the bot App installation when the App key isn't in the Keychain, and for the Cloud Run services when `gcloud` isn't logged in. The App check mints a short-lived installation token (a POST to GitHub); doctor changes no repo state. | Only the App's own token can see its installation, and only an authenticated `gcloud` can see the services |
| 2026-11-15 | `test_deploy.sh`, `test_doctor.sh` and `test_agy_run.sh` no longer assume the template's layout. They use their own `deploy.yml` fixtures, skip adapters that aren't installed, and use a fixture plan when the template's intent is gone. | A bootstrapped project keeps these tests and runs them in `make test`; before this, 4 of its 9 test files failed |
| 2026-11-15 | Step 4 doesn't add `make bootstrap-target` (spec §4.11, criterion 11) or the README "Start a new project" quick-start (FR-14). Until `bootstrap-target` exists, switching targets is: edit `deploy.yml`, then `DEPLOY_TARGET=<target> scripts/deploy.sh bootstrap`, which is what bootstrap's error message says. Bootstrap also refuses to start on a dirty tree and retries an unpushed commit on rerun. | `bootstrap-target` lands with the second adapter in M3, where criterion 11 is proven; the README quick-start is M4. Claude review on #15 |
| 2026-11-16 | Step 6a ran in `sandbox-node-local`, not `sandbox-node-cloudrun`. The owner bootstrapped it from a Codespace on an Android tablet with `--skip-bot-key`, and a cloud Claude Code session opened the sandbox PRs as the owner, who approved production and merged with the admin bypass. The Dependabot test (criterion 6) waits for the bot key. Findings ([results](spikes/m2-step6a-results.md)) led to: the owner checklist notes the approval bootstrap's own deploy waits for; the `local` adapter no longer logs `No such container`. A `ci-ok` that reports cancelled runs as skipped needs an owner workflow change, and the `typescript-eslint`/`minimatch` npm advisory (dev-only) is left to Dependabot. | Owner on a tablet, no Mac; the bot key lives only in the Mac Keychain (addressed by intent 0002) |

## Risks

| Risk | Mitigation |
|---|---|
| `/swarm` quota is heavy | Default to `/boost` or `/teamwork` for small and medium tasks. Use `/swarm` only for wide parallel work. `agy-run.sh` prints the mode's quota warning. |
| Pro limit consumed by CI reviews while building | Quota guards (max 3 per PR, skip docs/draft); `/sweep` is used sparingly. |
| Setup-token 401s (user reports) | Spike B proves the token first. Regenerate on failure. Never fall back to the API. |
| A production approval left open holds the repo-wide `deploy` group, so later merges wait (and only the newest pending run survives) | Intended: one deploy at a time keeps `cleanup` safe, and classify deploys everything since the last production deploy, so nothing is lost. Approve or reject promptly; M4's `maintain.yml` can remind about stale approvals |
| An auto-created `production` Environment has no reviewer, and the guard step only runs inside the production job, after dev deployed | Bootstrap creates the Environment with the rule before any deploy, and `doctor` checks it. If it's ever missing, the guard stops production and `report` opens an issue; dev is unaffected |
| Ruleset locks the owner out | Applied last in M1, then tested with a docs PR. The PRs-only admin bypass is confirmed before relying on it. |
| Dependabot approve path fails under the ruleset | Proved in M2 step 6 with a real PR. If it fails, revisit C1 with the owner. |
| Sandbox GCP spend | $10 budget alert. Sandbox Cloud Run services scale to zero. The owner is asked before any sandbox repo or GCP resource is deleted. |
| Public repo leaks a secret | Push protection, the gitleaks job and the `no-secrets` hook. Secrets live only in the Keychain and GitHub secrets. |
| Unverified Cloudflare commands and free plan | M3 spike before building the adapter. If it fails, the adapter is deferred to its own intent. |

## Proof (spec §8 acceptance criteria → where they are proven)

| Criterion | Proven in |
|---|---|
| 1 Bootstrap with no UI steps (node / python / go) | M2 step 6 (node), M3 sandboxes (python, go via dry-run + one live) |
| 2 Lint failure → no Claude review | M1 (template's own `pr.yml`), M2 sandbox |
| 3 Docs-only PR → no review, no deploy | M1, M2 sandbox |
| 4 Code PR full chain + approval + gated prod | M2 sandbox |
| 5 Broken live smoke → auto-revert < 2 min (each adapter) | M2 (cloud-run), M3 (pages, cloudflare) |
| 6 Dependabot patch auto-merges, minor waits | M2 sandbox |
| 7 Non-owner `@claude` ignored | M1: comment from a second account, or a workflow unit test on `author_association` |
| 8 `agy-run.sh` draft PR + live check run wakes Claude Code | M1 Track C (fixtures), M2 (real run) |
| 9 Idle project $0 after 30 days | First monthly `sdlc-metrics.sh` run on the M2 sandbox (deferred proof) |
| 10 Template self-test passes | M1 onward, on every PR |
| 11 Switching TARGET changes no workflow | M3: switch the M2 sandbox from cloud-run → github-pages → back |
| 12 README word for word on a clean setup | M4 |

`plan.md` is updated in the same commit whenever implementation departs from it.
