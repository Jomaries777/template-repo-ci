# M3 step 6: sandbox E2E results (GitHub Pages, 2026-11-18)

Run on 2026-11-18 in [`Jomaries777/sandbox-node-static`](https://github.com/Jomaries777/sandbox-node-static), a public repo created from the template and bootstrapped straight onto `github-pages` with the node stack.

Written on 2026-11-24 from the run logs, the sandbox's PRs and its `gh-pages` commits. At the time the results lived only in chat (slip PD-17 in `docs/playbook-deviations.md`). Every time below comes from a log timestamp.

## Results

| Spec §8 criterion | Sandbox evidence | Result |
|---|---|---|
| 1 Bootstrap with no UI steps (node, github-pages) | The first bootstrap stopped at the Pages step with HTTP 409 (finding 1). After template #45, it ran in one pass. | ✅ after #45 |
| 4 Code PR, full chain, gated production | Deploy run [44331686328](https://github.com/Jomaries777/sandbox-node-static/actions/runs/44331686328). See the first bullet list below. | ✅ |
| 5 Broken live smoke → auto-revert in under 2 min | Sandbox PR #5, deploy run [44334822339](https://github.com/Jomaries777/sandbox-node-static/actions/runs/44334822339). The revert ran in 26.8 s, but its re-check failed, so it was **never confirmed healthy** (finding 2). | ⚠ revert ran, not confirmed |
| — Fix after the revert | Sandbox PR #6, deploy run [44336391601](https://github.com/Jomaries777/sandbox-node-static/actions/runs/44336391601). | ✅ |

**Criterion 4, first deploy (run 44331686328):**
- **Jobs:** `dev` was skipped, because Pages has production only (`deploy-config.sh`).
- **Pre-traffic:** the pre-traffic test against the local preview (`http://127.0.0.1:51303/`) passed 2 of 2.
- **Promote:** `98f754b` became `gh-pages` commit `52da7e4`. It was live 27.0 s after promote started (15:09:11.58 → 15:09:38.57), which includes waiting for the Pages build.
- **Live checks:** 3 of 3 on `https://jomaries777.github.io/sandbox-node-static`, 60 s apart.

**Criterion 5, PR #5 (run 44334822339):**
- **The fault:** PR #5 changed the smoke test to request the absolute `/health`. Under the site's sub-path, that resolves to `https://jomaries777.github.io/health`.
- **Pre-traffic:** passed. The local preview serves at the root, where `/health` exists.
- **Promote:** `85d08db` became `b034987`.
- **Live check 1/3** failed at 15:25:56.50: `GET /health` got 404. Playwright then retried it twice, and both retries also got 404.
- **Revert:** `gh-pages` commit `26b16a1` ("revert to 52da7e4") has the same tree as `52da7e4` (`3302940800…`), so the files were restored. The adapter reported "reverted to the files of 52da7e4" at 15:26:23.26, **26.8 s** after the failure.
- **Re-check:** failed at 15:26:26.6 with the same 404. The log said "revert did not pass the live check; manual action needed".
- **Afterwards:** issue #7 (`deploy-failure`) was opened, with a triage comment.

**Fix, PR #6 (run 44336391601):**
- **Serving before:** `26b16a1`, the revert.
- **Promote:** `7ac9c73` became `2bc9d17`.
- **Live checks:** 3 of 3.
- **Afterwards:** #7 was closed at 15:41.

**Dependabot majors** (sandbox #1, #2, #3: node 26-slim, @types/node 26, vitest 5):
- They waited for the owner, as the policy says majors must.
- They were merged together at 15:40 on the owner's word in chat (slip PD-16).
- The run for #2 was replaced while pending (run 44338414321, cancelled). Runs 44338395033 and 44338434600 deployed green.
- `deploy-base.sh` classifies everything since the last production deploy, so the cancelled run skipped nothing.

## Findings

1. **Bootstrap stopped at Pages with HTTP 409 (fixed, template #45).** Creating `gh-pages` makes GitHub turn Pages on by itself a moment later. The adapter's check ran too early, and its POST then got 409. Bootstrap now sets the source with `PUT` on a 409.
2. **The revert was never confirmed: the fault was in the test, not the app.**
   - The re-check after a revert runs the **new** commit's smoke suite. A fault in that suite fails against every version, the restored one included.
   - So the run proved the revert **mechanism** (26.8 s to the same tree), not a confirmed rollback.
   - `docs/playbook-deviations.md` PB-41 recorded "Pages 27 s" as met. That figure is the time to run the revert command, not the time to a confirmed revert.
   - The rollback was rehearsed again with a fault in the **app** during the criterion 11 switch in `sandbox-node-workers` (plan.md M3 step 6). That sandbox's PR #17 broke the links on `GET /` under the Pages sub-path. In deploy run [45407649448](https://github.com/Jomaries777/sandbox-node-workers/actions/runs/45407649448), live check 1/3 failed at 22:22:46.46 on 2026-11-24, and the revert to `484817e` was confirmed healthy at 22:23:13.54: **27.1 s** to a confirmed revert. PB-41 now cites this figure.
3. **Playwright's CI retries ran on live checks.** Live check 1 shows the failing test retried twice before it counted. Here the fault was steady, so retries changed nothing. On Workers, a retry hid an intermittent 500 (the Workers results, finding 3). Fixed since: smoke runs never retry (template #63).
4. **Process slips.** These are recorded as PD-14, PD-15 and PD-16 in `docs/playbook-deviations.md`:
   - PR #5 and PR #6 came from the owner's account, not the bot;
   - #6 was merged before its Claude review ran;
   - the change was not started in plan mode.
5. **A deploy is still waiting.** Run 45280725440 (sandbox #9, a vitest patch, 2026-11-23) has waited at the `production` approval since 22:35 UTC on 2026-11-23.

## Timings

| Step | Time |
|---|---|
| Promote → `gh-pages` commit live (includes the Pages build) | 27.0 s (first deploy), 31.1 s (PR #5), 36.1 s (PR #6) |
| Failed live check → revert done (files restored, Pages built) | 26.8 s |
| Failed live check → revert confirmed | never: the re-check failed (finding 2) |
| Whole deploy run, first deploy | 5 min 41 s |
