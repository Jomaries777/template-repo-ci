# M3 step 6: sandbox E2E results (Cloudflare Workers)

Run on 2026-11-23 in [`Jomaries777/sandbox-node-workers`](https://github.com/Jomaries777/sandbox-node-workers), a public repo created from the template with the README quick-start ("Start a new project"). It deploys to a separate Cloudflare account on the Workers Free plan with no card on file, with the neutral `workers.dev` subdomain `x7k2-apps`.

The owner ran everything from their Mac:
- signed in to the broker (`scripts/bot-login.sh`);
- stored the Claude token in the Keychain;
- ran `scripts/bootstrap.sh --stack node --target cloudflare-workers --dry-run`, then `make bootstrap`;
- installed the bot App on the repo;
- ran `make doctor`.

Claude Code opened the sandbox PRs as the bot, from the same Mac. The owner merged them and approved production.

This repo replaces `sandbox-node-static` for the Workers part of step 6 (plan Deviations, 2026-11-23). Criterion 11 will be proven by switching this repo to github-pages and back.

## Setup

- **Dry run:** every remote call targeted the new repo. Run from the template's own checkout, it targeted the template instead; see Findings.
- **Bootstrap:** ran in one pass.
  - **Cloudflare:** read the subdomain `x7k2-apps`, and deployed the 503 placeholder to `sandbox-node-workers-dev` and `sandbox-node-workers` (adapter `bootstrap`, wrangler 4.165.0).
  - **GitHub:** Environments, secrets and variables, the push to `main`, repo settings and the ruleset.
  - **The bot key:** set through the broker (`bot-secrets.sh`).
  - **The Cloudflare token:** set on the `dev` and `production` Environments only, with no repo-level copy (checked with `gh api`).
- **Doctor:** `make doctor` passed every check after the bot App was installed.

## Results

| Spec §8 criterion | Sandbox evidence | Result |
|---|---|---|
| 1 Bootstrap with no UI steps (node, cloudflare-workers) | See Setup. The browser steps were the Cloudflare account and token, plus installing the bot App, which the spec leaves to the owner. | ✅ |
| 4 Code PR, full chain, approval, gated production | Sandbox PR #10 (`GET /` → `hello, world`), deploy run [45195252580](https://github.com/Jomaries777/sandbox-node-workers/actions/runs/45195252580). See the first bullet list below. | ✅ |
| 5 Broken live smoke → auto-revert in under 2 min | Sandbox PR #11 added a fault: `GET /` returns 500 only on hosts starting with `sandbox-node-workers`. Deploy run [45200374064](https://github.com/Jomaries777/sandbox-node-workers/actions/runs/45200374064), on dev. See the second bullet list below. | ✅ (with finding 3) |
| — Fix after a revert, test first | Sandbox PR #13 on `fix/live-host-500`. See the third bullet list below. | ✅ |
| — Automatic Claude review on bot PRs | Before the fix, every bot PR got the skip comment (template #61, finding 2). After sandbox PR #9 brought the fix in, bot PR #10 got an automatic `<!-- claude-review -->` comment with no `@claude review`. | ✅ |

**Criterion 4, PR #10 (deploy run 45195252580):**
- **CI and review:** every tier passed, and the PR got the automatic advisory review.
- **Dev:**
  - dark upload with a preview URL;
  - the `prod-safe` smoke test passed on the preview URL;
  - promote, then the live URL reported the new sha 20 s later;
  - 3 of 3 live checks, 60 s apart.
- **Production:** waited for the owner's approval, then the same steps (the live URL reported the sha after 9 s).
- **Afterwards:** both Workers answered `hello, world` with `/health` version `3971616`.

**Criterion 5, PR #11 (deploy run 45200374064):**
- **Before the live checks:** CI, the unit tests (`app.example.workers.dev`) and the pre-traffic smoke on the preview URL (`<8hex>-…`) all passed. Promote confirmed the live URL served `9a78ecc`.
- **Live check 2/3** failed at 15:02:47.04 (`GET /` → 500).
- **Revert:** `wrangler rollback 83db0695… --yes` ran without a prompt. The re-check passed, and the log says "revert confirmed" at 15:02:50.92, **3.9 s** after the failure.
- **Afterwards:** `production` was skipped, and issue #12 (`deploy-failure`) was opened.
- **Check 1** also got the 500 at 15:01:44, but was counted as passed (finding 3). From that first 500 to the confirmed revert took **67 s**.

**Fix after the revert, PR #13:**
- The regression test (`GET /` on both live hosts returns 200) was committed first and failed with `expected 500 to be 200`. The fix came second.
- The merge closed #12. It deployed green to dev and production: deploy run [45202181433](https://github.com/Jomaries777/sandbox-node-workers/actions/runs/45202181433), 3 of 3 live checks each, and both Workers then reported `/health` version `5ac6e85`.

## Findings

1. **Cloudflare lags a few seconds (template #60).** The first deploy failed in dev twice ([run 45184414059](https://github.com/Jomaries777/sandbox-node-workers/actions/runs/45184414059)):
   - `wrangler versions list` didn't yet include a version uploaded about 6 s earlier, so `promote` found no `c<sha7>` tag.
   - On the rerun, the live URL still served the 503 placeholder about 3 s after promote returned.
   - **Fix:** `version_for_tag` retries (7 × 5 s), and `promote` waits until `/health` reports the new sha (12 × 5 s, a warning if not).
   - **Proven:** in every later run, the lookup found the version and the URL served the sha 4–20 s after promote.
2. **The automatic review never ran on bot PRs (template #61).** `claude-code-action` refused bot-started runs ("Workflow initiated by non-human actor"), and the skip comment blamed the Pro limit or the token.
   - **Fix:** `allowed_bots` lists the run's actor when it pushed a branch of the same repo and isn't Dependabot. The skip comment links the job log.
   - The fix is an owner PR in each existing project (sandbox PR #9).
3. **Playwright's CI retries hide an intermittent live failure.** `stacks/node/playwright.config.ts` sets `retries: 2` when `CI` is set.
   - In live check 1, `GET /` got 500, and the retry reached an edge still serving the old version and got 200. Playwright reported "1 flaky" and the check passed.
   - Detection moved to check 2, 60 s later. That still met criterion 5, but a fault that only some requests hit could pass every check.
   - **Open:** the smoke suite should run with no retries (or fail on flaky tests), in every stack. This needs its own change.
4. **A failed first deploy can't revert cleanly.** The only earlier version is bootstrap's 503 placeholder, so the re-check after a revert always fails ("revert NOT confirmed healthy: manual action needed").
   - This happened on the first deploy's rerun.
   - **Fixed (2026-11-24, `fix/first-deploy-revert`):** `release.sh` checks the serving version once before deploying. When that baseline failed too, a revert skips the re-check and reports "not healthy before this release: fix forward". This works on every target, the placeholder included.
5. **GitHub marked a skipped job "cancelled".** In run 45195252580, `report` (`if: failure()`) was marked cancelled, with no runner, instead of skipped, so the run showed "cancelled" although `dev` and `production` succeeded. The production deployment status was `success`, which is what `deploy-base.sh` reads.
   - It happened once. The cause is unexplained, probably GitHub's behaviour rather than the workflow's. In the same run, the `production` job waited 9.5 min between being created (14:35:48) and starting (14:45:16). The evidence doesn't show whether that was the environment approval or a runner wait.
6. **README quick-start gaps (criterion 12).** These go to a separate docs PR:
   - the README still says the workflow lacks the Cloudflare settings;
   - step 5 has no example for exporting `CLOUDFLARE_ACCOUNT_ID` and reading the token without echoing it;
   - bootstrap prints "Commit deploy.yml's target… in a PR" during a first bootstrap, where it doesn't apply;
   - `==> Target:` is printed twice;
   - `bootstrap.sh` runs against the template repo itself; its push is stopped by the ruleset, but the local checkout is changed first.

## Timings

| Step | Time |
|---|---|
| Dev release, criterion 4 (current → released) | 2 min 38 s, of which the live checks took 2 min 4 s |
| Production release, criterion 4 | 2 min 25 s, after a 9.5 min wait between job creation and start |
| Promote → live URL serves the new sha | 4–20 s (7 promotes) |
| Failed live check → revert confirmed | 3.9 s |
| First 500 → revert confirmed | 67 s |
