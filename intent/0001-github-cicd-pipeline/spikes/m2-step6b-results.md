# M2 step 6b: sandbox E2E results (Cloud Run)

Run on 2026-11-17 and 2026-11-18 in [`Jomaries777/sandbox-node-cloudrun`](https://github.com/Jomaries777/sandbox-node-cloudrun), a public repo created from the template, against a new GCP project used only for this sandbox. The owner did the setup from a Codespace on an Android tablet:
- created the GCP project and linked billing in the console;
- installed `gcloud` in the Codespace;
- signed in to Google, GitHub and the broker;
- ran `scripts/bootstrap.sh --stack node --target cloud-run`.

A cloud Claude Code session opened the PRs as the owner. The owner approved production deploys. Step 6a ran the same scenarios on the test-only `local` target ([results](m2-step6a-results.md)). 6b repeats the deploy and revert parts on the real default target.

## Setup

Bootstrap ran in one pass after a dry run that the owner and Claude reviewed:
- **Google Cloud:** APIs, Artifact Registry with its cleanup policy, the WIF pool and provider, the deployer and runtime service accounts, the `-dev` and `-prod` services, and the $10 budget.
- **GitHub:** repo settings, the ruleset and both Environments.
- **Secrets and variables:** the Claude token secret, `BOT_APP_ID`, and the `GCP_*` and `APP_NAME` variables.
- **The bot key:** set **through the broker** (`bot-secrets.sh`, spec 0002 phase 2), so the App key never reached the Codespace.

`make doctor` passed everything except one WARN: the retired phase 1 Codespaces secret `BOT_APP_KEY_B64` was still stored. The owner deletes it.

## Results

| Spec §8 criterion | Sandbox evidence | Result |
|---|---|---|
| 1 Bootstrap with no UI steps (node, cloud-run) | See Setup. The only browser steps were creating the GCP project and linking billing, which the spec leaves to the owner, plus the sign-ins. | ✅ |
| 3 Docs-only PR → no review, no deploy | Sandbox PR #13 (README only):<br>• Both PR runs (draft, then ready for review) ran classify, secrets and hygiene, and skipped lint, CodeQL, unit, build, acceptance and `claude-review`.<br>• Deploy run 44238625002 classified the merge as docs and skipped artifact, dev, production and report. | ✅ |
| 4 Code PR, full chain, approval, gated production | Sandbox PR #8 (the `/health` fix), deploy run 44052817314:<br>• **WIF:** keyless sign-in.<br>• **Artifact:** built and published to Artifact Registry in 1.5 min.<br>• **Dev:** dark deploy of `dev-00004-sal` at 0 %, pre-traffic smoke on its tagged URL, promote (image tagged `:dev`), 3/3 live checks.<br>• **Production:** waited for the owner, then the same sequence on `prod-00002-hec`, 3/3 live checks.<br>Merge to production done: 12 min 47 s, about 4 min of it waiting for the approval. PR #12 repeated the whole chain (run 44235892976). | ✅ |
| 5 Broken live smoke → auto-revert in under 2 min | Sandbox PR #9 added a fault: `GET /` returns 500 after its first call, so CI and the pre-traffic smoke pass. Deploy run 44058261222, attempt 2, on dev:<br>• **17:04:19.4** promote routes 100 % to `dev-00007-weh`.<br>• **17:04:22.6** live check 1 fails (`GET /` → 500).<br>• **17:04:25.4** traffic is back on `dev-00004-sal`.<br>• **17:04:30.9** the re-check passes, "revert confirmed".<br>**11.5 s from live to a confirmed revert; the bad revision served for about 6 s.** Production was skipped, and the report job opened a deploy-failure issue. Attempt 1 failed earlier, at promote (finding 3), without moving traffic. | ✅ |
| — Fix after a revert, test first | Sandbox PR #12 on `fix/*`:<br>• The regression test (three calls to `/`) was committed first and failed with `expected 500 to be 200`. The fix came second.<br>• Deploy run 44235892976: dev passed 3/3 live checks, which call `/` repeatedly. Promote moved the existing `:dev` tag, which proves finding 3's fix.<br>• Production, approved by the owner, passed 3/3. | ✅ |
| 6 Dependabot patch auto-merges, minor waits | Not repeated on Cloud Run: the workflow doesn't depend on the target, and 6a proved the patch case. Right after bootstrap, Dependabot opened five **major** PRs here: node 26 image, TypeScript 7, Vitest 5, `@types/node` 26, minimatch 11. They wait for the owner as designed, and the TypeScript 7 PR fails CI. The minor case is still open. | ⏳ minor (as in 6a) |
| 2, 7, 8 | Not run here; 6a says where each is proven. Criterion 8 still needs the owner's Mac. | — |

## Cloud checks

The owner ran a read-only `gcloud` check in the Codespace and sent a budget screenshot.

| Check | Result |
|---|---|
| Services scale to zero | `autoscaling.knative.dev/minScale` is unset on both services (default 0). Max 2 instances, set by bootstrap. |
| WIF limited to `main` of this repo | Provider condition: `assertion.repository=='Jomaries777/sandbox-node-cloudrun' && assertion.ref=='refs/heads/main'` |
| Artifact Registry cleanup | `delete-untagged-7d`, `delete-tagged-30d`, `keep-5-most-recent`, `keep-deployed`. The repository held 82 MB after five builds, inside the 0.5 GB free tier. |
| Budget | `sandbox-node-cloudrun-budget`: monthly, this project only, alerts at 10 %, 50 % and 100 %. **Spend $0.00 of $10.00** after all the runs above. |
| Cold start | Not measured: the cloud session's network doesn't allow `*.run.app`. The pre-traffic smoke against each new revision, the first request it ever gets, passed in under 1 s of test time. |

Criterion 9 (an idle project costs $0 after 30 days) stays a deferred proof for the first monthly metrics run.

Links: [sandbox PRs](https://github.com/Jomaries777/sandbox-node-cloudrun/pulls?q=is%3Apr) (#8, #9, #12, #13) and [deploy runs](https://github.com/Jomaries777/sandbox-node-cloudrun/actions/workflows/deploy.yml).

## Findings

1. **Cloud Run reserves `/healthz`.**
   - **What happened:** the first live deploy got 404 on `GET /healthz` at the pre-traffic smoke, because Cloud Run's front end answers some paths that end in `z` itself ([known issues](https://docs.cloud.google.com/run/docs/known-issues)). The candidate was discarded with no traffic sent.
   - **Fix:** the health route is now `/health` in the stack, the release live check, the `local` target, compose and the docs. A unit test checks that `/healthz` returns 404. #35.
2. **Bootstrap pushed `main` before the target bootstrap.**
   - **What happened:** the first deploy started before the `GCP_*` variables existed and failed at sign-in. Bootstrap's own push also starts a deploy that the owner may not expect (6a finding 1).
   - **Fix:** bootstrap now pushes last, after the Environments, secrets and target. It applies the ruleset after the push, and a failed setup step leaves the commit local for a rerun. #36.
   - **Correction:** #36's description also gave a production Environment without a reviewer as a risk. The `production` job already refuses to deploy without a required reviewer and branch policy (Deviations, 2026-11-15), so the real effect was the early failure only.
3. **Promote needs `artifactregistry.tags.delete`.**
   - **What happened:** moving an existing `<env>` tag removes it first. `roles/artifactregistry.writer` can't do that, so the first release worked only because `:dev` didn't exist yet. Promote failed before traffic moved.
   - **Fix:** the deployer now gets `roles/artifactregistry.repoAdmin`, still on the `app` repository only, and never `artifactregistry.admin`. #37. The sandbox got the binding with one `gcloud` command.
4. **A promote that fails leaves its candidate in place.**
   - **What happened:** `release.sh` stops when `promote` fails, so the dark revision keeps its tag and public tagged URL at 0 % traffic until a later `cleanup`.
   - **Effect:** no traffic reaches it, but the URL answers.
   - **Follow-up:** run `discard` when promote fails before moving traffic, test first.
5. **The tablet and Codespace route works, with these rough edges.** They belong in the README quick-start (M4):
   - `gcloud auth login --no-launch-browser` prints a URL that wraps in the terminal, so tapping it opens only part. Fix: write it to a file and open that in the editor.
   - `claude setup-token` redirects to `localhost`, which the tablet can't reach. Fix: `curl` the full callback URL from a second terminal tab in the Codespace.
   - A Codespace's own `GITHUB_TOKEN` covers only its repo. Bootstrapping a second repo from it needs `env -u GITHUB_TOKEN gh auth login` and `gh auth git-credential` as the clone's credential helper.
   - Typing long commands on a tablet is error-prone (`role/` for `roles/`). Give one-line, copy-pasteable commands.
6. **Deploy-failure issues pile up during a test.**
   - **What happened:** each failed run opened one (sandbox #1, #7, #10, #11).
   - **Proposal:** none for now. They are accurate, and the owner closes them after reading.
7. **Cloud sessions can't reach the deployed service.** The network policy blocks `*.run.app`, so verification relies on the workflow's own smoke and live checks plus the owner's `gcloud` output. That is enough evidence, and no network change is proposed.

## Timings

| Stage | Time |
|---|---|
| PR CI, code change (to `ci-ok`) | about 4 to 5 min |
| PR CI, docs only | about 25 s |
| Artifact build and publish | about 1.5 min |
| Dev or production release (dark deploy, pre-traffic smoke, promote, 3 live checks 60 s apart) | 3 to 3.5 min |
| Promote → confirmed revert (criterion 5) | 11.5 s, against about 5 s on the `local` target |
| Merge → production released, including about 4 min waiting for approval | 12 min 47 s |
