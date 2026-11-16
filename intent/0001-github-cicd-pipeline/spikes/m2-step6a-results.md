# M2 step 6a: sandbox E2E results (local target)

Run on 2026-11-16 in [`Jomaries777/sandbox-node-local`](https://github.com/Jomaries777/sandbox-node-local). The sandbox was created from the template and bootstrapped from a Codespace on an Android tablet with `scripts/bootstrap.sh --stack node --target local --skip-bot-key`. A cloud Claude Code session opened the PRs as the owner; the owner approved production deploys. Step 6b repeats the deploy and revert parts on Cloud Run.

## Setup

`make doctor` after bootstrap: everything passed except `BOT_APP_PRIVATE_KEY` (Actions and Dependabot secrets: FAIL) and "bot App installed" (SKIP). That is expected with `--skip-bot-key`: the key is added later from a Mac.

## Results

| Spec §8 criterion | Sandbox evidence | Result |
|---|---|---|
| 1 Bootstrap with no UI steps (node) | Bootstrap applied repo settings, the ruleset, both environments (production: required reviewer, `main` only), `CLAUDE_CODE_OAUTH_TOKEN` and `BOT_APP_ID`. The bot key was skipped on purpose. | ✅ Except for the bot key, which needs a Mac (see intent 0002) |
| 3 Docs-only PR → no review, no deploy | PR #5 (README only). PR CI ran classify, secrets and hygiene (markdownlint and link check) in about 30 s, and skipped lint, CodeQL, unit, build, acceptance and `claude-review`. After the merge, deploy run #6 classified it as `docs` and skipped artifact, dev, production and report. | ✅ |
| 4 Code PR full chain + approval + gated production | PR #1 (`GET /version`): all CI jobs and the Claude review passed. Deploy run #3: dev deployed, then production waited for the owner and deployed `51d8e2d` with 3/3 live checks. The production job's guard confirmed the required reviewer and the `main`-only branch policy. | ✅ |
| 5 Broken live smoke → auto-revert in under 2 min | PR #2 added a fault: `GET /` returns 500 after its first call, so CI and the pre-traffic smoke pass. Deploy run #4 on dev: promote at 11:03:16.6, live check 1 failed at 11:03:19.8, reverted to `51d8e2d`, and the re-check confirmed the revert at 11:03:21.3. **About 5 s from going live to a confirmed revert, well inside the 2-minute bound.** The time is for the `local` target, where promote and revert only swap a state file; Cloud Run's traffic switch is slower, and 6b measures it. Production was skipped. The report job opened a deploy-failure issue (sandbox #4) with Claude triage. | ✅ For `local`; Cloud Run in 6b |
| — Fix after a revert (test first) | PR #3 on `fix/*`: the regression test was committed first and failed on `main` (`expected 500 to be 200`), then the fix. Deploy run #5: dev, then production approved by the owner. | ✅ |
| 6 Dependabot patch auto-merges, minor waits | The bot key was set from a Codespace through M2 step 7a's Codespaces secret. Sandbox #6 added the npm block that bootstrap had missed (finding 6), and stepped prettier and eslint back as fixtures. Dependabot then opened patch-group PR #7 (prettier 3.10.0 → 3.10.1). **The bot approved it and it merged itself 5 minutes later**, with no owner action; the push was attributed to the bot. Major PRs #8–#10 (`@types/node` 26, TypeScript 7, Vitest 5) stay open for the owner. This also proves the key without its trailing newline works with `create-github-app-token`. The minor-group PR (eslint 10.14 → 10.15) **has not appeared**, so the minor case is open; majors show the non-patch path. | ✅ Patch; ⏳ minor |

Step 6 lists criteria 1–8. The others are not proven by this run:

- **2 Lint failure → no Claude review:** not run in the sandbox. M1 proves it in the template's own `pr.yml`, which the sandbox runs unchanged.
- **7 Non-owner `@claude` ignored:** not run. The proof table assigns it to M1 (a second account, or a workflow test on `author_association`), and the sandbox has only the owner's account.
- **8 `agy-run.sh` draft PR + live check run:** not run. The cloud session has no Antigravity and no bot key (intent 0002). It needs a run on the owner's Mac.

Links: [sandbox PRs](https://github.com/Jomaries777/sandbox-node-local/pulls?q=is%3Apr) (#1, #2, #3, #5) and [deploy runs](https://github.com/Jomaries777/sandbox-node-local/actions/workflows/deploy.yml) (#2–#6).

## Findings

1. **A run left waiting for approval blocks later deploys.** The deploy started by bootstrap's own push (run #2) passed dev and then waited about 40 minutes for a production approval nobody expected. The next merge's deploy queued behind it, because the `deploy` concurrency group runs one at a time. This is the intended behaviour (Risks table), but the owner checklist now says to expect that first approval.
2. **`ci-ok` shows red on a cancelled run.** Marking a draft PR ready starts a new `pr` run that cancels the earlier one, and the cancelled run's `ci-ok` reports `failure`. The newer run then passes, and nothing is blocked, but the red check is confusing. It happened on every PR here (#1, #2, #5). Fix: `ci-ok` treats a run cancelled because a newer one replaced it as skipped. This needs a workflow change by the owner (`ALLOW_WORKFLOW_EDIT=1`).
3. **Docker noise in the `local` adapter.** `start_rev` removed a container that didn't exist yet, so every deploy log showed `Error response from daemon: No such container`. It now checks first.
4. **npm audit in the smoke step.** `npm ci` reports 7 moderate findings. All are one advisory: `minimatch` ReDoS, pulled in by the dev-only `typescript-eslint` linter. It isn't in the runtime image: `stacks/node/Dockerfile`'s runtime stage installs with `npm ci --omit=dev`, and `typescript-eslint` is a `devDependency` in `stacks/node/package.json`. It is left to Dependabot, since the lockfile is protected and npm's suggested fix is a semver-major change.
5. **Sandbox clones only track `main`.** A cloud session's shallow clone fetches only `main`, so a stop hook reported pushed `feat/*` and `fix/*` branches as unpushed. This affects the session tooling, not the template.
6. **Bootstrap never added the stack's Dependabot updates.** `.github/dependabot.yml` claimed stacks add their ecosystems at bootstrap, but nothing did, so every project got GitHub Actions updates only (FR-7). Fixed: each stack ships `dependabot-updates.yml`, and bootstrap appends it.
7. **Lockfiles must be written with npm 11.** npm 10.9 dropped the `libc` fields of the optional native packages (review of sandbox #6). The node stack README now says so.

## Timings

| Stage | Time |
|---|---|
| PR CI, code change (to `ci-ok`) | about 4 min, plus about 30 s for the Claude review |
| PR CI, docs only | about 30 s |
| Artifact build | about 1.5 min |
| Dev or production release (dark deploy, smoke, promote, 3 live checks 60 s apart) | 3.5 to 4 min |
| Promote → confirmed revert (criterion 5) | about 5 s |
