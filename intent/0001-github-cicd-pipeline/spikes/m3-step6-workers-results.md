# M3 step 6: sandbox E2E results (Cloudflare Workers)

Run on 2026-11-23 in [`Jomaries777/sandbox-node-workers`](https://github.com/Jomaries777/sandbox-node-workers), a public repo created from the template with the README quick-start ("Start a new project"). It deploys to a separate Cloudflare account on the Workers Free plan with no card on file, with the neutral `workers.dev` subdomain `x7k2-apps`.

The owner ran everything from their Mac:
- signed in to the broker (`scripts/bot-login.sh`);
- stored the Claude token in the Keychain;
- ran `scripts/bootstrap.sh --stack node --target cloudflare-workers --dry-run`, then `make bootstrap`;
- installed the bot App on the repo;
- ran `make doctor`.

Claude Code opened the sandbox PRs as the bot, from the same Mac. The owner merged them and approved production.

This repo replaces `sandbox-node-static` for the Workers part of step 6 (plan Deviations, 2026-11-23). Criterion 11 was proven on 2026-11-24/25 by switching this repo to github-pages and back (see [Criterion 11](#criterion-11-switching-targets) below).

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
| 11 Switching TARGET changes no workflow | Sandbox PR #16 (cloudflare-workers → github-pages) and PR #20 (back), each after `make bootstrap-target`. Each PR changed only `deploy.yml` line 1. See [Criterion 11](#criterion-11-switching-targets) below. | ✅ |
| 5 Broken live smoke → auto-revert, on github-pages | Sandbox PR #17, deploy run [45407649448](https://github.com/Jomaries777/sandbox-node-workers/actions/runs/45407649448), during the switch: **27.1 s** from the failed check to a confirmed revert. The details are in [m3-results.md](m3-results.md), finding 2. | ✅ |
| 6 Dependabot minor waits | Dependabot PR #1 (2026-11-23), the github-actions group with 5 updates: `actions/create-github-app-token` 3.3.0 → 3.4.0 is minor, and the other four (`claude-code-action`, `dependency-review-action`, `codeql-action/init` and `/analyze`) are patches. In auto-merge run [45184623089](https://github.com/Jomaries777/sandbox-node-workers/actions/runs/45184623089), `fetch-metadata` reported `version-update:semver-minor`, a group takes its largest bump. The job logged "Not a patch update (version-update:semver-minor); the owner reviews this one." It neither approved nor enabled auto-merge. On 2026-11-27 the PR was still open, unmerged, with auto-merge off and `ci-ok` green. A group with any minor bump waits as a whole. The patch half was proven in M2 6a (`sandbox-node-local` #7). | ✅ |

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

## Criterion 11: switching targets

Spec §8 criterion 11: changing `target` in `deploy.yml` and running `make bootstrap-target` moves an existing project's deploys to the new adapter without any workflow file changing. Every PR below was opened by the bot, then merged by the owner, who also approved production.

**Leg 1: cloudflare-workers → github-pages, PR #16 (deploy run [45406850461](https://github.com/Jomaries777/sandbox-node-workers/actions/runs/45406850461), 2026-11-24):**
- **Bootstrap:** `make bootstrap-target` ran with the branch's `deploy.yml` before the merge. It created `gh-pages` at `6d65669`. GitHub turned Pages on by itself, and bootstrap set the source.
- **The change:** `deploy.yml` line 1, `target: cloudflare-workers` → `target: github-pages`. Nothing else.
- **Dev:** skipped, because Pages has production only.
- **Baseline:** failed twice, with the 10 s retry in between. Pages was serving bootstrap's `gh-pages` commit `6d65669`, which has no export. "Not healthy before this release" is expected on the first deploy to a new target, and the release went on.
- **Pre-traffic:** the test against the local preview passed 2 of 2.
- **Promote:** `3222714` became `gh-pages` commit `484817e`, live 41.4 s after promote started (13:51:46.26 → 13:52:27.61 UTC).
- **Live checks:** 3 of 3 on `https://jomaries777.github.io/sandbox-node-workers`.

**On github-pages, PRs #17 and #19:** PR #17 rehearsed the Pages revert with a fault in the app (27.1 s to a confirmed revert, run 45407649448; see the results table). PR #19 fixed it, with the failing test committed first. Its deploy run, [45611782361](https://github.com/Jomaries777/sandbox-node-workers/actions/runs/45611782361), passed the baseline and the pre-traffic test. `9634b5e` became `e597cb4`, live after 36.5 s, and passed 3 of 3 live checks.

**Leg 2: github-pages → cloudflare-workers, PR #20 (deploy run [45636669802](https://github.com/Jomaries777/sandbox-node-workers/actions/runs/45636669802), 2026-11-25):**
- **Bootstrap:** the owner ran `make bootstrap-target`. It found both Workers already there and left them as they were, so no placeholder replaced a live Worker. It updated the repo variables `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_WORKERS_SUBDOMAIN`, `APP_NAME` and `CLOUDFLARE_API_TOKEN_SET_AT`, and set the `CLOUDFLARE_API_TOKEN` secret on the `dev` and `production` Environments. This was the first standalone `bootstrap-target` on an existing repo.
- **The change:** `deploy.yml` line 1 back to `target: cloudflare-workers`. Nothing else.
- **Dev:**
  - the baseline passed on the version the Worker had served since leg 1 (finding 7);
  - dark upload, then the pre-traffic test passed 3 of 3 on the preview URL;
  - promote, and the live URL served `6e22d1a` 4.3 s later;
  - 3 of 3 live checks.
- **Production:** waited for the owner's approval, then the same steps. The live URL served the sha 8.6 s after promote, and 3 of 3 live checks passed.

**No workflow file changed.** Comparing the sandbox before the switch (`38cbab1`, PR #15's merge) with after it (`6e22d1a`, PR #20's merge) lists only `stacks/node/**` files, from PRs #17 and #19. Nothing under `.github/` changed, and `deploy.yml` is back where it started.

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
   - **Fixed** on branch `fix/smoke-no-retries`: the node `smoke` script passes `--retries=0`, and `tests/scripts/test_stacks.sh` keeps every stack's smoke suite retry-free. Python (pytest, no rerun plugin) and Go (`go test -count=1`) already ran each test once.
4. **A failed first deploy can't revert cleanly.** The only earlier version is bootstrap's 503 placeholder, so the re-check after a revert always fails ("revert NOT confirmed healthy: manual action needed").
   - This happened on the first deploy's rerun.
   - **Fixed (2026-11-24, `fix/first-deploy-revert`):** `release.sh` checks the serving version once before deploying. When that baseline failed too, a revert skips the re-check and reports "not healthy before this release: fix forward". This works on every target, the placeholder included.
   - **Follow-up (2026-11-24, `fix/release-recheck-after-revert`):** the re-check now always runs after a revert; a failed baseline only changes a failed re-check's message to "not healthy before this release either: fix forward" (see the plan.md Deviations row after finding 4). A second follow-up (`fix/revert-lost-health`) keeps "NOT confirmed" when `/health` passed before the release and fails after the revert, so a release that adds a smoke test can't hide a revert that lost service.
5. **GitHub marked a skipped job "cancelled".** In run 45195252580, `report` (`if: failure()`) was marked cancelled, with no runner, instead of skipped, so the run showed "cancelled" although `dev` and `production` succeeded. The production deployment status was `success`, which is what `deploy-base.sh` reads.
   - It happened once. The cause is unexplained, probably GitHub's behaviour rather than the workflow's. In the same run, the `production` job waited 9.5 min between being created (14:35:48) and starting (14:45:16). The evidence doesn't show whether that was the environment approval or a runner wait.
6. **README quick-start gaps (criterion 12).** **Fixed (2026-11-24, `fix/bootstrap-quickstart-gaps`):** the README's Workers note is current, step 5 shows each target's exports (the token read with `read -rs`), the hint and the second header are gone from a first bootstrap, and bootstrap refuses the template repo before changing anything. The gaps were:
   - the README still says the workflow lacks the Cloudflare settings;
   - step 5 has no example for exporting `CLOUDFLARE_ACCOUNT_ID` and reading the token without echoing it;
   - bootstrap prints "Commit deploy.yml's target… in a PR" during a first bootstrap, where it doesn't apply;
   - `==> Target:` is printed twice;
   - `bootstrap.sh` runs against the template repo itself; its push is stopped by the ruleset, but the local checkout is changed first.
7. **The old target keeps serving after a switch.** No adapter tears down the target a project leaves:
   - during the Pages leg, both Workers still served `38cbab1`;
   - Pages still serves `e597cb4`.

   `make doctor` checks only the active target, so nothing flags the stale copy. It costs $0 on both free plans, and it is what leg 2's baseline checked. The README said a switch is "No workflow changes", but not that the old host stays live. **Documented** in the README by agy PR #76 (2026-11-26, the criterion 8 run).
8. **The advisory review reports a missing intent folder on sandbox PRs.** The Claude review marked "no `intent/NNNN-*/` folder" as Important on PRs #17, #19 and #20, but not on #16. Bootstrap deletes the template's `intent/` folders, so a new project has none until its first intent. The finding is noise there. No fix yet.

## Timings

| Step | Time |
|---|---|
| Dev release, criterion 4 (current → released) | 2 min 38 s, of which the live checks took 2 min 4 s |
| Production release, criterion 4 | 2 min 25 s, after a 9.5 min wait between job creation and start |
| Promote → live URL serves the new sha | 4–20 s (7 promotes) |
| Failed live check → revert confirmed | 3.9 s |
| First 500 → revert confirmed | 67 s |
| Pages promote → `gh-pages` commit live (includes the Pages build), criterion 11 | 41.4 s (PR #16), 36.5 s (PR #19) |
| Workers promote → live URL serves the new sha, after switching back | 4.3 s (dev), 8.6 s (production), PR #20 |
| Pages: failed live check → revert confirmed | 27.1 s (PR #17) |
