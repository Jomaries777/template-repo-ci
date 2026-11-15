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
| Loop artifacts | `intent/0001-…/plan.md` (this file), status lines in `intent.md` / `spec.md`, `intent/0001-…/spikes/*.md` and fixtures |
| Agent config | `CLAUDE.md`, `AGENTS.md`, `REVIEW.md`, `.claude/settings.json`, `.claude/{agents,commands,skills}/**`, `scripts/hooks/*.sh` |
| Repo scaffolding | `.gitignore`, `.github/{CODEOWNERS,pull_request_template.md,dependabot.yml,rulesets/main.json}`, `Makefile`, `README.md` |
| CI | `.github/workflows/{pr,claude,deploy,dependabot-automerge,maintain}.yml`, `.github/actions/{classify,release}/action.yml`, `.template/selftest.yml` |
| Scripts | `scripts/{classify,gh-settings,bootstrap,doctor,bot-token,agy-run,agy-events,agy-report,deploy,sdlc-metrics}.sh`, `scripts/bot-app-manifest.json`, `tests/scripts/**` (plain-bash tests with fixtures) |
| Stacks | `stacks/{node,python,go}/**`: hello service with `/healthz`, lint/type/test configs, Dockerfile, acceptance suite (service containers), `prod-safe` smoke tag |
| Deploy adapters | `deploy.yml` (written by bootstrap), `deploy/targets/{cloud-run,none,github-pages,cloudflare-workers}/{target.yml,bootstrap,publish,current,deploy-dark,promote,revert,url,discard,cleanup}` |

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
5. `dependabot-automerge.yml` (bot approves security/patch PRs, C1). Independent of the other steps.
6. **E2E on a sandbox repo** `sandbox-node-cloudrun` (public, created from the template): prove criteria 1–8 for this slice, including a deliberately broken live smoke test → auto-revert in under 2 min, and a real Dependabot patch auto-merge.

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
| M2: Node + Cloud Run slice | Next | — |
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
| 2026-11-15 | M2 step 2 (deploy contract) was finished by Claude Code in a cloud session as an owner PR. Antigravity's partial output (dispatcher, `none` adapter, `cloud-run/target.yml`) was kept; Claude Code wrote the `cloud-run` verbs, `lib.sh` and `tests/scripts/test_deploy.sh`, and made the `none` verbs executable. A real Antigravity re-run is deferred. | The cloud session has no Antigravity and no bot key |
| 2026-11-15 | Adapter verbs print only their result (URL or revision) on stdout. `DRY-RUN:` lines, progress and CLI output go to stderr. In dry run, read-only queries return built-in fixtures. | `release` captures results with `$(deploy.sh …)` (spec §4.10). Fixtures let every verb, including `cleanup`'s keep-5 logic, run without credentials |
| 2026-11-15 | Cloud Run: `bootstrap` creates `<app>-dev` and `<app>-prod` once, public and idle, from Google's sample image. `deploy-dark` doesn't pass `--allow-unauthenticated`. `bootstrap` also enables `iam.googleapis.com`. | `roles/run.developer` can't set IAM policy, so the deploy SA couldn't make a new service public. The service's IAM policy persists across deploys. Service accounts and WIF pools need the IAM API |
| 2026-11-15 | `deploy.sh discard <env> <sha>` takes the SHA (spec §4.10 step 3 shows `discard <env>`). `cleanup` also removes tags from revisions at 0% traffic. | The candidate tag is derived from the SHA. A tagged revision can't be deleted |

## Risks

| Risk | Mitigation |
|---|---|
| `/swarm` quota is heavy | Default to `/boost` or `/teamwork` for small and medium tasks. Use `/swarm` only for wide parallel work. `agy-run.sh` prints the mode's quota warning. |
| Pro limit consumed by CI reviews while building | Quota guards (max 3 per PR, skip docs/draft); `/sweep` is used sparingly. |
| Setup-token 401s (user reports) | Spike B proves the token first. Regenerate on failure. Never fall back to the API. |
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
