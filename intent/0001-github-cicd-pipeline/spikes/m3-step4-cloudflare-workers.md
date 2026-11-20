# M3 step 4: cloudflare-workers spike (C10)

Plan step 4 asks for a short spike before the adapter: check that `wrangler versions upload`, `versions deploy` and `rollback` work as spec §4.11 assumes, and check how the Workers Free plan behaves. This spike has two phases.

- **Phase 1 (offline):** done 2026-11-20 in a cloud session, with no Cloudflare account.
- **Phase 2 (live):** the owner's run, on the separate account (plan decision 4).

The adapter is built against the phase 1 results. Phase 2 confirms them, or reopens the adapter.

## Phase 1: verified offline (wrangler 4.165.0, the version the adapter pins)

| Spec assumption (§4.11, ⚠ verify) | Result | Evidence |
|---|---|---|
| `wrangler versions upload` makes a version with no traffic and a preview URL | Command and flags exist: `--tag`, `--message`, `--var`, `--preview-alias`. Preview URLs need `preview_urls = true`, which the adapter's generated config sets | `wrangler versions upload --help` |
| The version ID and preview URL can be read without scraping human output | Yes. With `WRANGLER_OUTPUT_FILE_PATH` set, wrangler appends a `{"type": "version-upload", "version_id", "preview_url", ...}` line | wrangler source (`versionsUpload` → `writeOutput`) |
| `wrangler versions deploy <id>@100%` promotes | Yes, `[<version-id>@<percentage>..]` with `--yes` and `--message` | `wrangler versions deploy --help` |
| `wrangler rollback <id>` reverts without prompts in CI | Yes, with `--yes --message`. It asks again only if secrets changed since that version; the adapter's Workers have no secrets | `wrangler rollback --help`; wrangler source |
| `current` can read the serving version | `wrangler deployments status --json` gives `versions[].version_id` and `percentage` | wrangler source |
| `promote` can find the version for a commit | `wrangler versions list --json` gives `annotations["workers/tag"]`, the `c<sha7>` tag set at upload | wrangler source |
| The node stack runs on Workers | `stacks/node/src/worker.ts` (shares `route()`) bundles to 1.1 KiB. Under `wrangler dev` (local workerd) it answers `/` 200, `/health` 200 with the version binding, and `/nope` 404, all JSON | `wrangler deploy --dry-run`; `wrangler dev` with curl |
| GitHub OIDC federation (C10) | None used. The adapter uses a least-privilege API token held as an Environment secret, as C10 decided | — |

## Phase 2: the owner's live checklist

Every item needs the separate Cloudflare account (plan decision 4), on the Workers Free plan with **no card on file**. Record each result in this file.

1. **Account.** The account has a neutral `workers.dev` subdomain: not derived from the owner's email, because it appears in public CI logs.
2. **Token.** In the dashboard, under My Profile → API Tokens, create a custom token with only **Account → Workers Scripts → Edit**, scoped to that one account. Note its expiry for the yearly rotation (C10).
3. **Bootstrap.** In the new sandbox `sandbox-node-static`, with `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` exported, run `make bootstrap-target` with `target: cloudflare-workers`.
   - Expect: `<app>` and `<app>-dev` exist with a 503 placeholder.
   - Expect: the variables `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_WORKERS_SUBDOMAIN` and `APP_NAME` are set.
   - Expect: `CLOUDFLARE_API_TOKEN` is set on the `dev` and `production` Environments only.
4. **Token scope.** Check whether a Workers-Scripts-Edit-only token can read `/accounts/<id>/workers/subdomain`, which bootstrap uses. If it can't, record the extra read permission needed.
5. **Full chain.** One code PR goes through dev and production, with the preview URL smoke-tested before promote (criterion 4).
6. **Auto-revert.** A broken `/` is reverted automatically, and the revert is confirmed in under 2 minutes (criterion 5). Record the time.
7. **wrangler's real output matches what the adapter parses.** Pass or fail each one. A mismatch breaks `current`, `promote` or `deploy-dark`, and a wrong `current` removes the revert target.
   - `wrangler deployments status --json --name <worker>` has `versions[].version_id` and `versions[].percentage` (`current`).
   - `wrangler versions list --json --name <worker>` has `id`, `metadata.created_on` and `annotations["workers/tag"]` = `c<sha7>` for an upload made with `--tag` (`promote`).
   - With `WRANGLER_OUTPUT_FILE_PATH` set, `wrangler versions upload` writes a `{"type": "version-upload", "preview_url": "https://..."}` line (`deploy-dark`).
   - `wrangler rollback <id> --yes` returns without a prompt in CI (`revert`).
8. **Environments.** The adapter's `bootstrap` sets `CLOUDFLARE_API_TOKEN` on the `dev` and `production` Environments, which `scripts/bootstrap.sh` creates in an earlier step. Confirm that `make bootstrap-target` on the existing sandbox finds both.
9. **Free-plan facts.** Cloudflare's docs couldn't be reached from the cloud session, so these are open:
   - What happens over the daily request limit: an error, not a charge?
   - Are preview URLs public by default?
   - How many versions are kept, and can an undeployed version be deleted?
   - How far back can `rollback` go?

## Results so far

Phase 1 found no blocker, so the adapter was built (plan Deviations, 2026-11-20). Phase 2 is open.
