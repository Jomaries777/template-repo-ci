# Plan: 0003 Each AI agent acts as its own GitHub App — build

| Field | Value |
|---|---|
| Status | Draft |
| Spec | [spec.md](spec.md), accepted by the owner on 2026-11-27 (#94) |
| Intent | [intent.md](intent.md), accepted 2026-11-27 (#93) |
| Builders | Claude Code (CC) and Antigravity (AGY) in parallel, each with its own tasks per milestone (owner decision, 2026-11-27). The owner does every step marked Owner |
| Created | 2026-11-27 |

## Context

Today every agent acts as `jomaries777-agent-bot[bot]`, and Claude in CI posts as `github-actions[bot]` (#86, PD-10, PB-42). The spec gives each agent its own App: `jomaries777-claude` and `jomaries777-agy`. Automation with no AI in it gets `jomaries777-ci`, the renamed `jomaries777-agent-bot`. A `main-review` ruleset makes the owner's approval the only one that counts.

Facts found while planning (2026-11-27):

- **S2 is half answered already.** `gh api /user/installations` with the owner's `gh` login returns 403: "You must authenticate with an access token authorized to a GitHub App". S2 still tests the `PUT`, but the C6 fallback, a manual README step 6, is the likely outcome.
- **Seven repos hold today's key**: `template-repo-ci` and six sandboxes (`sandbox-node-local`, `sandbox-node-static`, `sandbox-node-cloudrun`, `sandbox-node-workers`, `sandbox-python-static`, `sandbox-go-static`). **Owner decision: retire the sandboxes.** Their `BOT_APP_*` secrets and their App access are removed, and the repos stay as the record of past proofs. Only the template migrates. The monthly metrics run in `sandbox-node-workers` (0001 criterion 9, due 2026-12-01) doesn't need the bot.
- **The order is safe for tokens, but not for secrets.**
  - Tokens: the deployed broker ignores an extra `agent` field, so the new `bot-token.sh` works against it. The new broker refuses requests without `agent`, so it is deployed only at cutover, after the new scripts are on `main`.
  - Secrets: the deployed broker's `/secrets` requires `apps`, and the new `bot-secrets.sh` sends `key`. So from the M1 merge until cutover step 2, no new repo is bootstrapped from `main`.
- **The spec's decisions missed #94.** #94 merged only its first commit, so the C1–C12 decisions, the `-agy` rename and S4 were not on `main`. This PR carries that commit (`b051535`) as well.
- **How the agents work.** Each AGY task is one `agy-run.sh` run with `--sandbox`, in its own worktree (never `--mode auto`). CC checks every AGY diff with `git diff` and `make lint test` before the PR goes to the owner. The verifier checks CC's work against the Proof below.

## Files that change

| File | New/Modified | Why |
|---|---|---|
| `intent/0003-per-agent-identity/plan.md` | New | This plan |
| `intent/0003-per-agent-identity/spec.md` | Modified | Status: Accepted (#94). Also carries the owner's C1–C12 decisions commit, which missed #94 (`-agy` rename, S4) |
| `intent/0003-per-agent-identity/spikes/s1-s4-results.md` | New | M0 spike results |
| `intent/0003-per-agent-identity/spikes/cutover.md` | New | M3 cutover record |
| `intent/0003-per-agent-identity/spikes/m4-proofs.md` | New | M4 proof runs |
| `broker/src/handler.js` | Modified | Multi-App config; `/token` takes `agent`; `login` and `id` in the answer (FR-2) |
| `broker/src/relay.js` | Modified | Acts as the Claude App; branch-head check uses its slug (FR-3) |
| `broker/src/secrets.js` | Modified | `key: claude\|ci` with fixed targets; only reader of `CI_KEY_PKCS8` (FR-4) |
| `broker/wrangler.toml` | Modified | Three Apps' IDs and slugs in place of `APP_ID`/`APP_SLUG` |
| `broker/migrations/0003_agent.sql` | New | `agent` audit column (NFR-5) |
| `broker/README.md` | Modified | Migration runbook (FR-11) and new secrets |
| `tests/broker/handler.test.mjs`, `relay.test.mjs`, `secrets.test.mjs`, `helpers.mjs` | Modified | Criterion 6 |
| `scripts/bot-token.sh` | Modified | `--agent` required; broker only (FR-5, D6) |
| `scripts/bot-secrets.sh` | Modified | `--key claude\|ci` (FR-4) |
| `scripts/agy-run.sh`, `scripts/agy-report.sh` | Modified | `--agent agy`; git author from the broker's answer (FR-5) |
| `scripts/bot-app-manifest.json` | Modified | Becomes a template with `<login>`, `<agent>` and permissions (FR-1) |
| `scripts/app-manifest.sh` | New | Renders one App's manifest and applies the C9 name rule |
| `tests/scripts/test_bot_token.sh`, `test_bot_secrets.sh`, `test_agy_gate.sh`, `test_agy_run.sh` | Modified | Criterion 7 |
| `tests/scripts/test_app_manifest.sh` | New | C9 name rule and per-App permissions |
| `CLAUDE.md`, `.claude/commands/sweep.md` | Modified | Push commands use `--agent claude` |
| `scripts/bootstrap.sh` | Modified | Adds the repo to the Apps or prints the manual step (S2); sets `CLAUDE_APP_*`/`CI_APP_*` (FR-9) |
| `scripts/doctor.sh` | Modified | FR-10 checks and leftover warnings |
| `scripts/gh-settings.sh` | Modified | Applies both rulesets; fills in the `-ci` App ID (FR-7) |
| `.github/rulesets/main.json` | Modified | Checks and `ci-ok` only (FR-7) |
| `.github/rulesets/main-review.json` | New | Code-owner review; `-ci` bypass (FR-7) |
| `tests/scripts/test_bootstrap.sh`, `test_doctor.sh`, `test_gh_settings.sh` | Modified | Criteria 9–11 |
| `.github/workflows/claude.yml`, `pr.yml`, `deploy.yml`, `dependabot-automerge.yml` | Modified (owner PR) | Claude App tokens per the token table; review cap; `CI_APP_*` (FR-6, FR-8) |
| `tests/scripts/test_workflow_tokens.sh` | New | Criteria 3 and 8 |
| `README.md` | Modified | Three Apps, step 6, new commands |
| `docs/playbook-deviations.md` | Modified | PD-2 fixed; PD-10, PB-42 updated; new Deliberate entry for C2 (FR-12) |
| `intent/0001-github-cicd-pipeline/spec.md`, `intent/0002-bot-identity-any-device/spec.md` | Modified | "Amended by 0003" notes (FR-12) |

A file outside this table is a deviation and goes in the Deviations table.

## Order of work

Each milestone has one task table. Tasks in a milestone, CC and AGY alike, are **independent**: they own different files and run at the same time. Milestones are **serial**, except that M1 and M2 run side by side after M0: they own different files. Every task ends in a PR that the owner approves. The bot can't push workflow files, so those come in an owner PR.

### M0: Spikes ‖ broker

The broker doesn't depend on any spike, so both start at once.

| Who | Task | Owns |
|---|---|---|
| Owner | Create the repo `sandbox-agent-apps` from the template. Create three throwaway Apps, `jomaries777-tclaude`, `jomaries777-tagy` and `jomaries777-tci`, with the permissions in the spec's token table, and install them on that repo only. In the sandbox, apply a `main-review` ruleset by hand, with `-tci` as a bypass actor. | – |
| CC | **Spikes S1–S4** in `sandbox-agent-apps`, recorded in the results file.<br>• S1: with `main-review` bypassed by `-tci` and `ci-ok` pending in `main`, does `gh pr merge --auto` from `-tci` wait for `ci-ok`? Does it merge when `ci-ok` passes, and stay open when it fails?<br>• S2: does `PUT /user/installations/{id}/repositories/{repo_id}` accept the `gh` token?<br>• S3: does `claude-code-action` post an inline review comment with a token that has `contents: read` and `pull_requests`/`issues: write`?<br>• S4: can a run Dependabot didn't start read the Dependabot secret `CI_APP_PRIVATE_KEY` and mint a `-tci` token?<br>• Criterion 4 early: approve a `-tagy` PR with a `-tclaude` token, and check that `reviewDecision` stays `REVIEW_REQUIRED` and a merge with that token is refused. | `spikes/s1-s4-results.md` |
| AGY | **1a Broker**, tests first. Not deployed in this step.<br>• `wrangler.toml` lists `claude`, `agy` and `ci` (ID and slug each). The Worker secrets are `CLAUDE_KEY_PKCS8`, `AGY_KEY_PKCS8` and `CI_KEY_PKCS8`.<br>• `/token` requires `agent` `claude` or `agy`, and refuses `ci`, unknown or missing values with `400 bad_agent`. Its answer adds the bot's `login` and `id`.<br>• `/relay` always mints with `claude`, and its branch-head rule uses the Claude slug.<br>• `/secrets` takes `key`: `claude` writes only the Actions secret `CLAUDE_APP_PRIVATE_KEY`, and `ci` writes only the Dependabot secret `CI_APP_PRIVATE_KEY`. No other file reads `CI_KEY_PKCS8`.<br>• Migration `0003_agent.sql` adds the `agent` audit column.<br>• `broker/README.md` gains the FR-11 runbook, in the order of M3 below, not the spec's FR-11 order (see Deviations). | `broker/**`, `tests/broker/**` |

**Gate (end of M0).** The spike results decide three things:
- S1 picks the Dependabot merge path: `--auto` if it waits for `ci-ok`, otherwise a `workflow_run` merge (C3).
- S2 picks the bootstrap path: the API if it accepts the token, otherwise the manual step (C6).
- S3 confirms the review token.

A result outside these decided fallbacks stops the build and goes back to the owner.

### M1: Device scripts ‖ setup

| Who | Task | Owns |
|---|---|---|
| CC | **1b Device scripts**. CC owns this step, not AGY, because it changes `agy-run.sh`, the script AGY runs under. Merged before cutover, and it works with the deployed broker.<br>• `bot-token.sh --agent <claude\|agy>` is required and gets tokens from the broker only; the Codespaces and Keychain paths are removed.<br>• `agy-run.sh` and `agy-report.sh` use `--agent agy`. The git author comes from the broker's `login` and `id`. Until cutover, the deployed broker gives neither, so today's author is kept for that window only.<br>• `bot-secrets.sh --key <claude\|ci>`.<br>• `app-manifest.sh <login> <agent>` renders a manifest, cutting the login so the name fits 34 characters.<br>• `CLAUDE.md` and `sweep.md` use `--agent claude`. | `scripts/{bot-token,bot-secrets,agy-run,agy-report,app-manifest}.sh`, `scripts/bot-app-manifest.json`, `tests/scripts/test_{bot_token,bot_secrets,agy_gate,agy_run,app_manifest}.sh`, `CLAUDE.md`, `.claude/commands/sweep.md` |
| AGY | **1c Setup**, following the M0 gate.<br>• `main.json` holds the checks and `ci-ok`. `main-review.json` holds the `pull_request` rule with `require_code_owner_review: true`, and bypasses for the admin and for the `-ci` App (from `CI_APP_ID`).<br>• `gh-settings.sh` applies both rulesets.<br>• `bootstrap.sh` adds the repo to the Apps (or prints README step 6), and sets `CLAUDE_APP_ID`, `CLAUDE_APP_SLUG` and `CI_APP_ID`. It works out App names with the same C9 rule as `app-manifest.sh`, by calling it rather than copying the rule. It sets both secrets with `bot-secrets.sh --key claude` and `--key ci` (the interface 1b provides; FR-9). It drops the Codespaces and Keychain key paths (`bootstrap.sh:372-382`, D6), and `--skip-bot-key` still skips the secrets.<br>• `doctor.sh` does the FR-10 checks: it fails if `CI_APP_PRIVATE_KEY` is an Actions secret or `CLAUDE_APP_PRIVATE_KEY` is a Dependabot secret, and warns on leftover `BOT_APP_*` copies. | `scripts/{bootstrap,doctor,gh-settings}.sh`, `.github/rulesets/*`, `tests/scripts/test_{bootstrap,doctor,gh_settings}.sh` |

### M2: Workflows

Runs after M0, alongside M1. One owner PR, merged at cutover step 7.

| Who | Task | Owns |
|---|---|---|
| AGY | **Workflow test first**, written from the spec's token table and review-cap rule, before CC's draft exists. It checks each Claude job's `permission-*` inputs, that `claude-review` has no `contents: write`, and that the review cap selects `vars.CLAUDE_APP_SLUG`. It also checks that `dependabot-automerge.yml` runs only when both the actor and the PR author are `dependabot[bot]` (C2). It must fail against today's workflows. | `tests/scripts/test_workflow_tokens.sh` |
| CC | **Draft the workflow changes** on a branch for the owner.<br>• `actions/create-github-app-token` (pinned by SHA) with `CLAUDE_APP_ID` and `CLAUDE_APP_PRIVATE_KEY` and the token table's `permission-*` inputs, passed as `github_token` in `claude.yml`, `claude-review` and deploy triage.<br>• The review cap counts `vars.CLAUDE_APP_SLUG`.<br>• `dependabot-automerge.yml` uses `CI_APP_ID` and `CI_APP_PRIVATE_KEY`, with the S1 merge path. It keeps its check that both the actor and the PR author are Dependabot. | `.github/workflows/{claude,pr,deploy,dependabot-automerge}.yml` |
| Owner | Push both into one PR. `test_workflow_tokens.sh` passes and `ci-ok` is green. Its advisory `claude-review` fails until cutover step 6 sets `CLAUDE_APP_*`, which is expected. | – |

### M3: Cutover

The owner runs this in one sitting, serially. CC drives the runbook, checks each step, and records it in `spikes/cutover.md`. AGY has no task: its App is being created.

1. **Owner:** create `jomaries777-claude` and `jomaries777-agy` from `app-manifest.sh`, and add `template-repo-ci` to both.
2. **Owner:** load `CLAUDE_KEY_PKCS8`, `AGY_KEY_PKCS8` and `CI_KEY_PKCS8` into the broker. `CI_KEY_PKCS8` is today's key for now. Apply migration 0003 (`wrangler d1 migrations apply`), and run `wrangler deploy` from a local branch whose `wrangler.toml` holds the new App IDs.
3. **CC:** open that branch as a PR through the new broker (`bot-token.sh --agent claude`). Its author must be `app/jomaries777-claude`, the first proof for criterion 1. If it isn't, roll back by deploying the old broker. Its source is `b065bb8`, the last `main` commit before 1a (`git worktree add /tmp/broker-old b065bb8`, then `wrangler deploy` there). It still uses the Worker secret `APP_KEY_PKCS8`.
4. **Owner:** rename `jomaries777-agent-bot` to `jomaries777-ci`, and cut its permissions to `contents` and `pull_requests` write.
5. **Owner:** create a new `-ci` key, load it into `CI_KEY_PKCS8`, and delete the old key on GitHub.
6. **Owner:** run `scripts/bot-secrets.sh Jomaries777/template-repo-ci`, and set `CLAUDE_APP_ID`, `CLAUDE_APP_SLUG` and `CI_APP_ID`.
7. **Owner:** merge the M2 PR.
8. **Owner:** run `scripts/gh-settings.sh` to apply `main` and `main-review`.
9. **Owner:** delete the old copies: the template's `BOT_APP_ID` and `BOT_APP_PRIVATE_KEY`, the Keychain entry `github-app-private-key`, and the Codespaces secret `BOT_APP_KEY_B64`. Retire the six sandboxes: delete their `BOT_APP_*`, and remove them from the `-ci` App.
10. **CC:** `make doctor` passes in the template.
11. **Owner:** delete the old Worker secret that the step 3 rollback needed: `wrangler secret delete APP_KEY_PKCS8`. After step 5 it holds a deleted key, so after that the old broker can no longer serve as a rollback.

Dependabot auto-merge is down from step 5 until step 7, so steps 5–7 run back to back.

### M4: Proofs ‖ docs

| Who | Task | Owns |
|---|---|---|
| AGY | **Docs**, as AGY's first run under its new App, so the PR is also criterion 1 for Antigravity.<br>• In `docs/playbook-deviations.md`: PD-2 becomes `fixed`; PD-10 and PB-42 are updated; a new Deliberate entry records the `-ci` bypass with its key limit (C2).<br>• `README.md`: the three Apps, step 6, and the new commands.<br>• "Amended by 0003" notes in specs 0001 (§4.4–§4.8) and 0002 (FR-1, 2, 5, 6, 8, 9).<br>• A note in the PD-10 entry that `can_approve_pull_request_reviews=false` stays on but is no longer the guard for Claude in CI (C11). | `README.md`, `docs/playbook-deviations.md`, `intent/0001-github-cicd-pipeline/spec.md`, `intent/0002-bot-identity-any-device/spec.md` |
| CC | **Proof runs** in the template, recorded in `spikes/m4-proofs.md` and the Progress table:<br>• Criterion 2: Claude's CI comments on the docs PR.<br>• Criterion 4: approve AGY's docs PR with a `-claude` token; `reviewDecision` stays `REVIEW_REQUIRED`, then the owner approves as usual.<br>• Criterion 5: the next Dependabot patch PR.<br>• Criterion 9: the owner's fresh sandbox below.<br>• Criterion 11: the live rulesets. | `plan.md`, `spikes/m4-proofs.md` |
| Owner | Create a fresh repo `sandbox-agent-apps-2` from the template's `main`, run `make bootstrap`, and add it to the three Apps if S2 failed. Then close #86, and delete both spike sandboxes and the throwaway Apps `jomaries777-tclaude`, `jomaries777-tagy` and `jomaries777-tci`. | – |

## Risks

| Risk | Mitigation |
|---|---|
| AGY reports success but changes nothing (CLAUDE.md) | CC checks `git diff` and `make lint test` after every AGY run, before any PR |
| AGY edits `agy-run.sh` while running under it | 1b, which changes `agy-run.sh`, is a CC task |
| CC and AGY edit the same file | Every task owns its files, and no two tasks in a milestone share one. Needing another task's file is a deviation the owner approves |
| The workflow test is shaped by the YAML it tests | AGY writes it from the spec before CC's draft exists, and it must fail against today's workflows |
| The new broker is live before the new scripts, and every agent push fails | The broker is deployed only at cutover step 2, after 1b is merged. Until step 5, rollback is deploying the old broker from `b065bb8`, which still has its `APP_ID` and `APP_SLUG`. The Worker secret `APP_KEY_PKCS8` stays until M3 step 11 |
| A new repo is bootstrapped between the M1 merge and cutover step 2, and its secrets step fails against the deployed broker | No new repo is bootstrapped in that window. The spike sandbox is made in M0, before M1 merges |
| Cutover leaves agents or auto-merge broken | One sitting, a runbook with checkpoints, and today's key stays in the broker until step 3 proves the new broker. Steps 5–7 run back to back |
| A spike fails beyond its decided fallback | The build stops at the M0 gate and goes back to the owner |
| The rename shows past PRs as `-ci` | Accepted (C4) |
| Claude's pushes now start CI and use Pro quota | The cap of 3 automatic reviews per PR (C7) |
| Owner-only steps hold up the bot | They're marked Owner, and nothing waits on an unmarked step |

## Progress

| Milestone | Status | PRs |
|---|---|---|
| M0: spikes ‖ broker | Not started | – |
| M1: device scripts ‖ setup | Not started | – |
| M2: workflows | Not started | – |
| M3: cutover | Not started | – |
| M4: proofs ‖ docs | Not started | – |

## Proof

| Check | Command | Expected | Spec criterion |
|---|---|---|---|
| Lint and tests | `make lint test` | exit 0; every test `ok` | all |
| Session and Antigravity PRs | `gh pr view <n> --repo Jomaries777/template-repo-ci --json author -q .author.login` for the M3 step 3 PR and the M4 docs PR | `app/jomaries777-claude`; `app/jomaries777-agy` | 1 |
| CI comments | `gh api repos/Jomaries777/template-repo-ci/issues/<n>/comments -q '.[].user.login'` on a PR with a `claude-review` comment and an `@claude` reply, and on a deploy-failure issue | `jomaries777-claude[bot]`; at least one inline comment in the sandbox (S3) | 2 |
| Review cap | `tests/scripts/test_workflow_tokens.sh` | `ok` for "cap counts only CLAUDE_APP_SLUG" and "marker from others ignored" | 3 |
| Cross-agent approval | M0: approve a `-tagy` PR with a `-tclaude` token in the sandbox. M4: approve AGY's docs PR with a `-claude` token. Each time, `gh pr view <n> --json reviewDecision`, then `gh pr merge <n>` with that token | `REVIEW_REQUIRED`; merge refused | 4 |
| Dependabot patches | Sandbox and template: a Dependabot patch PR, `gh pr view <n> --json mergedBy,state`; plus S1 with `ci-ok` failing and S4 | merged by the `-ci` App after `ci-ok`; open while `ci-ok` fails; S4 finds the secret empty | 5 |
| Broker | `node --test tests/broker` | `ok` for the `bad_agent` cases, `login`/`id`, relay as claude, `/secrets` targets, `CI_KEY_PKCS8` read only in `secrets.js`, `agent` audited; `wrangler d1 migrations list agent-bot-audit` shows `0003_agent.sql` applied | 6 |
| Device script | `tests/scripts/test_bot_token.sh`; `grep -E 'Keychain\|BOT_APP_KEY_B64\|security find-generic-password' scripts/bot-token.sh` | `ok` for "no --agent" and "broker down, no fallback"; grep finds nothing | 7 |
| Token table | `tests/scripts/test_workflow_tokens.sh` | `ok` for each job's `permission-*` inputs; `claude-review` has no `contents: write` | 8 |
| Bootstrap | `sandbox-agent-apps-2`: `make bootstrap`, then `make doctor` | doctor passes, including its check that the repo is in all three installations. "No web step" holds only if S2 passed. Otherwise the C6 fallback applies and the manual step is recorded | 9 |
| Doctor | `tests/scripts/test_doctor.sh` | `ok` for each leftover warning, and failures for `CI_APP_PRIVATE_KEY` as an Actions secret and `CLAUDE_APP_PRIVATE_KEY` as a Dependabot secret | 10 |
| Rulesets | `gh api repos/Jomaries777/template-repo-ci/rulesets/<id>` for each ruleset | `main` and `main-review` exist; `main-review` has `require_code_owner_review: true` and the `-ci` App in `bypass_actors`; `main` doesn't | 11 |
| Docs | `grep -nE '^\| PD-2 \|' docs/playbook-deviations.md`; `grep -nE '^\| PB-42 \|' docs/playbook-deviations.md` | PD-2 `fixed`; PB-42 `Met`; the new Deliberate entry exists | 12 |
| Cost | `grep -c '^name = ' broker/wrangler.toml; grep -c '^\[\[d1_databases\]\]' broker/wrangler.toml; grep -c '^\[\[' broker/wrangler.toml` | `1`, `1`, `1`: one Worker, one D1 database, and no other binding | 13 |

## Deviations

| Date | What changed from this plan | Why | Approved by |
|---|---|---|---|
| 2026-11-27 | **From the spec, at planning time.** The cutover order in M3, which `broker/README.md` follows, differs from FR-11's order. The agent Apps are created and the new broker is deployed before the rename and the new `-ci` key. | Today's key stays usable until the new broker is proven (M3 step 3), so a rollback is still possible. FR-11's order deletes the old key before anything is tested | Owner, with this plan |
