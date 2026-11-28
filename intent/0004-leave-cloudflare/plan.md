# Plan: 0004 Leave Cloudflare — build

| Field | Value |
|---|---|
| Status | Draft |
| Spec | [spec.md](spec.md), accepted by the owner on 2026-11-28 (C1–C14 in #109; Status set with this plan) |
| Intent | [intent.md](intent.md), accepted 2026-11-28 (#107) |
| Builders | Claude Code (CC) and Antigravity (AGY), each with its own tasks per milestone. The owner does every step marked Owner, and every step that touches the broker project |
| Created | 2026-11-28 |

## Context

The broker's Cloudflare account was lost during 0003 M3 step 2, and a replacement account can't be validated (recorded in `intent/0003-per-agent-identity/spikes/cutover.md`, which lands with the 0003 cutover PR at M2 step 0). The old Worker still serves tokens for `jomaries777-agent-bot`, but nobody can change it. This plan moves the broker to Cloud Run in its own GCP project, finishes 0003 M3 on it, retires the Workers sandbox, and removes the `cloudflare-workers` target.

Facts found while planning (2026-11-28):

- **NFR-1's free tiers, checked on the pricing pages on 2026-11-28** for `us-west1`:

  | Service | Free tier | Scope | Bearing on this plan |
  |---|---|---|---|
  | Cloud Run, request-based | 180,000 vCPU-s, 360,000 GiB-s and 2 M requests a month; 1 GiB of egress in North America | Billing account. Applied as a Tier 1 price discount, and `us-west1` is Tier 1 | Idle instances that aren't minimum instances aren't billed. Requests that IAM refuses aren't billed, so removing `allUsers` (FR-5) also stops the cost |
  | Firestore | 1 GiB stored; 50,000 reads, 20,000 writes and 20,000 deletes a day; 10 GiB of egress a month | Project, and only one free database per project: `(default)` | **TTL deletes get no free quota** ($0.01 per 100,000). So the broker prunes with ordinary deletes, and there's no TTL policy (owner, 2026-11-28; Deviations). A count reading up to 1,000 index entries is billed as 1 read. A query with at most one range field isn't charged for the index entries it reads, so the rate guard costs 1 read |
  | Secret Manager | 6 active versions, 10,000 access operations and 3 rotation notifications a month | Billing account. Enabled *and* disabled versions count as active; destroyed ones are free. Automatic replication counts as one location | Each instance start reads 4 secrets, so 10,000 operations cover about 2,500 cold starts a month. `--prune` destroys old versions; disabling them isn't enough |
  | Cloud Build | 2,500 build-minutes a month | Billing account, and only for `e2-standard-2` in the default pool | S3 checks the machine type and pool of a source deploy |
  | Artifact Registry | 0.5 GiB stored | Billing account, so it's shared with every `cloud-run` target project on that account | The cleanup policy keeps 2 images. M2's pre-flight measures what the other projects use |
  | Cloud Storage (the `--source` upload bucket) | 5 GB-months of regional storage | Only in `us-east1`, `us-west1` and `us-central1` | S3 records the bucket's location |
  | Cloud Logging | 50 GiB a month | Project. The `_Required` bucket (Admin Activity) is free | Data Access logs for Secret Manager are a few KB a month |

  Sources: cloud.google.com `/run/pricing`, `/firestore/pricing`, `/secret-manager/pricing`, `/build/pricing`, `/artifact-registry/pricing`, `/products/observability/pricing` and the free-tier summary `docs.cloud.google.com/free/docs/free-cloud-features`. The budget's own cost isn't on these pages.
- **This Mac has one gcloud login, the owner's,** and Claude's Bash uses it. That login will own the broker project, so C10's final guard ("Claude's `gcloud` login has no role in the broker project") doesn't hold here. **Owner decision (2026-11-28):** `no-secrets.sh` blocks every Bash command that runs `gcloud`, `gsutil` or `bq` and names `agent-bot-broker`, plus the three owner scripts and `gcloud secrets versions access`. The owner runs every broker-project command in their own terminal, read-only checks included, and CC reads what they paste. The guard is a hook, not IAM (Deviations).
- **The step-1 `-claude` and `-agy` keys can go sooner than the spec says.** Nothing this plan runs uses them, and the stray Worker holds them. So the owner deletes them on GitHub as soon as the new keys exist (M2 step 4), not at 0003 M3 step 11. The rollback in M2 is the old broker URL, which uses only the old bot key (Deviations).
- **The timeouts already leave room for a cold start.** `bot-token.sh` and `bot-login.sh` use `--max-time 15`, `bot-secrets.sh` 30, `bot-relay.sh` 60, and `doctor.sh` 10. S1 measures the real cold start.
- **The App IDs are known.** 8c00874 (on `chore/0003-cutover-broker`, not on `main`) has `CLAUDE_APP_ID` 5962128, `AGY_APP_ID` 5962149 and `CI_APP_ID` 5766032. They move into `broker/config.yaml`.
- **How the agents split the work.** AGY owns paths that `agy-run.sh`'s gate doesn't protect (`broker/src/**`, `tests/broker/**`, `deploy/targets/**`, `stacks/**`, `README.md`, `intent/**`). CC owns the protected paths (`scripts/**`, `tests/scripts/**`, `.claude/settings.json`, `CLAUDE.md`), anything that touches a key or secret value (`secure-change`), and every runbook step. That way no AGY run needs `--allow-protected`. Each AGY task is one `agy-run.sh` run with `--sandbox` in its own worktree (`boost` for one file, `teamwork` for several). CC checks every AGY diff with `git diff` and `make lint test` before it goes further. Before cutover, AGY's token comes from the old broker, which ignores `agent`, so its PRs show `jomaries777-agent-bot` until M2.

## Files that change

| File | New/Modified | Why |
|---|---|---|
| `intent/0004-leave-cloudflare/plan.md` | New | This plan |
| `intent/0004-leave-cloudflare/spec.md` | Modified | Status: Accepted. Planning amendments to FR-4, NFR-1, S2, C10 and criteria 7 and 9 (Deviations) |
| `intent/0004-leave-cloudflare/spikes/s1-s3-results.md` | New | M0 results, and the deletion of the spike project |
| `intent/0004-leave-cloudflare/spikes/retire-workers.md` | New | M3 record (criterion 13) |
| `broker/src/server.js` | New | Node 22 entry point (Design, Runtime) |
| `broker/src/firestore.js` | New | Audit store: `ready`, `countLastHour`, `insert`, `prune`; metadata token cache |
| `broker/src/handler.js` | Modified | `deps.audit` in place of `env.AUDIT`; IP from `X-Forwarded-For` (S1); the prune moves into the store |
| `broker/src/relay.js` | Modified | Comment on the subrequest cap |
| `broker/src/seal.js` | Modified | Its comment names Workers (criterion 12). Logic unchanged |
| `broker/src/index.js`, `broker/wrangler.toml`, `broker/schema.sql`, `broker/migrations/` | Deleted | Workers and D1 are gone |
| `broker/config.yaml` | New | Non-secret values, with the App IDs from 8c00874 |
| `broker/package.json` | Modified | `engines` (Node 22), `start`; drops "wrangler" from its description |
| `broker/.gcloudignore` | New | Keeps tests, `node_modules` and dotfiles out of the build |
| `broker/Dockerfile` | New | `node:22-alpine` image in place of buildpacks (M0 gate, Deviations) |
| `broker/setup.sh`, `broker/put-secret.sh`, `broker/deploy.sh` | New | Owner scripts (FR-6) |
| `broker/lib.sh` | New | Helpers the three owner scripts share (Deviations) |
| `broker/README.md` | Modified | Rewritten for Cloud Run (FR-13). Points to the cutover record without naming the old host |
| `tests/broker/helpers.mjs` | Modified | Fake Firestore REST and metadata server, in place of the D1 stub |
| `tests/broker/handler.test.mjs`, `relay.test.mjs`, `secrets.test.mjs` | Modified | Use the fake store; IP and prune cases |
| `tests/broker/server.test.mjs`, `tests/broker/firestore.test.mjs` | New | Criterion 8 |
| `tests/scripts/test_broker_setup.sh`, `test_broker_put_secret.sh`, `test_broker_deploy.sh` | New | Criteria 5 and 9 |
| `.claude/settings.json` | Modified | Drops the `wrangler` deny rules; denies `gcloud secrets versions access` and the owner scripts (C10) |
| `scripts/hooks/no-secrets.sh`, `tests/scripts/test_hooks.sh` | Modified | Blocks the C10 commands and any `gcloud`/`gsutil`/`bq` command naming `agent-bot-broker` (planning decision) |
| `scripts/doctor.sh`, `tests/scripts/test_doctor.sh` | Modified | `workers.dev` warning; kill-switch hint names `broker/deploy.sh --disable` (FR-9) |
| `scripts/bot-login.sh`, `tests/scripts/test_bot_login.sh` | Modified | Usage text names a Cloud Run URL |
| `intent/0003-per-agent-identity/plan.md` | Modified | Deviations: M3 finishes on the Cloud Run broker, new keys for all three Apps (C6); Progress |
| `intent/0003-per-agent-identity/spikes/cutover.md` | Modified | The M2 steps, key deletions and fingerprints (criterion 10) |
| `deploy/targets/cloudflare-workers/` | Deleted | FR-10 |
| `stacks/node/src/worker.ts`, `stacks/node/test/worker.test.ts` | Deleted | FR-10 |
| `stacks/node/src/routes.ts`, `stacks/go/README.md`, `stacks/python/README.md` | Modified | Drop the Workers notes |
| `deploy.yml` | Modified | Drops the target from its comment |
| `scripts/bootstrap.sh`, `scripts/sdlc-metrics.sh`, `scripts/release.sh` | Modified | Drop the wrangler comment, the `CLOUDFLARE_API_TOKEN` tracking, and the comment |
| `tests/scripts/test_bootstrap.sh`, `test_bootstrap_target.sh`, `test_deploy.sh`, `test_deploy_config.sh`, `test_sdlc_metrics.sh` | Modified | Drop target cases; `TARGET=cloudflare-workers` is an unknown target |
| `.github/workflows/deploy.yml`, `.github/workflows/maintain.yml` | Modified (owner PR) | FR-11 |
| `README.md` | Modified | Quick-start step 2, prerequisites and the target table |
| `intent/0001-github-cicd-pipeline/spec.md`, `intent/0002-bot-identity-any-device/spec.md`, `intent/0003-per-agent-identity/spec.md` | Modified | "Amended by 0004" notes at each section the spec names |
| `CLAUDE.md` | Modified, only if a command changes | FR-13 |

A file outside this table is a deviation and goes in the Deviations table.

## Order of work

Milestones run in order. Tasks within a milestone own different files and run at the same time (**independent**), unless they're marked **serial**. Every code task ends in a PR the owner approves. M1 lands as **one** PR (spec, cutover step 1): CC merges AGY's branches into the build branch after checking them. The bot can't push workflow files, so FR-11 is an owner PR.

### M0: Spikes ‖ server adapter

| Who | Task | Owns |
|---|---|---|
| Owner | Create a throwaway project `agent-bot-spike-<suffix>`, link billing, and set a $1 budget on it. It is never `pse-advisor-feat001` | – |
| CC | **S1–S3** in that project, in `us-west1`, with dummy header values (never a real token). Every command passes `--project`.<br>• S1: an echo service. Do `Authorization: Bearer <dummy>` and `X-GitHub-Token` arrive unchanged? Which `X-Forwarded-For` entry did Google's front end add, and what happens when the client sends its own? How long does the first request after 15+ idle minutes take (`curl -w '%{time_total}'`, 3 tries)?<br>• S2: a `(default)` Native database with the composite index (`caller_id`, `endpoint`, `ts`). Is the REST `runAggregationQuery` count right? What error does a missing index give? Does a `runQuery` on `expire_at < now` with `limit 50`, plus one `commit` of deletes, remove only the expired documents? How many reads does Query Explain report for each?<br>• S3: with Editor removed from the default compute account, does `gcloud run deploy --source --build-service-account builder@` build and deploy? Record the build's machine type and pool, the source bucket's location, and that `containerscanning.googleapis.com` is off.<br>• Then delete the project, and record its deletion and its billing figure | `spikes/s1-s3-results.md` |
| AGY | **0a Server adapter**, tests first (`boost`). `broker/src/server.js` listens on `$PORT` and turns each Node request into a WHATWG `Request`, passing the body as a stream. It calls `handle(request, env, deps)`, writes the `Response`, and builds `env` once from `process.env`. `server.test.mjs` checks headers, the body stream, the 1 KB and 1 MB caps, and status codes. No spike decides anything here. The branch goes into the M1 PR | `broker/src/server.js`, `tests/broker/server.test.mjs` |

**Gate (end of M0).**
- S1 fixes the IP rule that handler.js uses.
- S2 fixes the error that the store turns into `503 audit_unavailable`, and confirms the prune.
- S3 confirms the build identity, and that its build-minutes and storage are free.
- A cold start over about 2 s goes back to the owner (Decision 7).

Any result outside these stops the build and goes back to the owner.

### M1: Broker build

All three tasks are independent. They land as one PR, and nothing is deployed.

| Who | Task | Owns |
|---|---|---|
| AGY | **1a Runtime**, tests first (`teamwork`).<br>• `firestore.js`: `ready()` is a `limit 1` query, cached once it succeeds. `countLastHour` is a count on the three indexed fields. `insert(row)` is `createDocument` with `expire_at` = `ts` + 90 days. `prune(nowMs)` queries `expire_at < now` with `limit 50` and deletes the results in one `commit`. The metadata token is cached until a minute before it expires, and never logged.<br>• `handler.js` takes `deps.audit`. The prune runs on about 1 in 50 inserts (`deps.random`), as the D1 prune does today, and a prune failure doesn't change the answer. `row.ip` follows the S1 rule. `CF-Connecting-IP` and `env.AUDIT` are gone.<br>• `config.yaml` holds the App IDs from 8c00874. `package.json` and `.gcloudignore` as listed. `index.js`, `wrangler.toml`, `schema.sql` and `migrations/` are deleted, and the `seal.js` and `relay.js` comments change.<br>• `helpers.mjs` is a fake Firestore and metadata server, and the existing cases pass on it | `broker/src/**` except `server.js`, `broker/{config.yaml,package.json,.gcloudignore}`, the deleted files, `tests/broker/**` except `server.test.mjs` |
| CC | **1b Owner scripts**, with `DRY_RUN=1` tests.<br>• `setup.sh` follows the spec's project table, without the TTL policy.<br>• `put-secret.sh` converts to PKCS#8 and refuses empty or non-PEM input. It pipes the key by stdin, deletes the file, and with `--prune` destroys every version but the deployed one.<br>• `deploy.sh` keeps the live `BROKER_ENABLED` and the live secret versions, supports `--enable` and `--disable`, and after deploying checks `/healthz` and that there are no traffic tags.<br>• Every `gcloud` line passes `--project`, and every regional one `us-west1` unless `BROKER_REGION` is set. Each script refuses a project without the label. `setup.sh` and `deploy.sh` also refuse one with a workload identity pool, user-managed keys or another service | `broker/{setup,put-secret,deploy}.sh`, `tests/scripts/test_broker_{setup,put_secret,deploy}.sh` |
| CC | **1c Guards, device scripts and README**.<br>• `.claude/settings.json` deny rules (C10).<br>• `no-secrets.sh` blocks (exit 2): `gcloud secrets versions access`; `broker/put-secret.sh`, `broker/deploy.sh` and `broker/setup.sh`; and any `gcloud`, `gsutil` or `bq` command naming `agent-bot-broker`. It lets `curl` to the service URL and other `gcloud` commands through.<br>• `doctor.sh` gets the FR-9 warning and hint. `bot-login.sh` gets its usage text.<br>• `broker/README.md` is rewritten for Cloud Run, including the M2 runbook in the order below | `.claude/settings.json`, `scripts/hooks/no-secrets.sh`, `scripts/{doctor,bot-login}.sh`, `tests/scripts/test_{hooks,doctor,bot_login}.sh`, `broker/README.md` |

### M2: Cutover, with 0003 M3

The owner runs it in one sitting, serially. CC drives the runbook, checks each step, and records it in `intent/0003-per-agent-identity/spikes/cutover.md`. The owner runs every command that names the broker project, in their own terminal, and pastes the output; the hook blocks CC from running them. AGY has no task until step 6, because the device sign-in changes under it.

0. **CC:** rebase `chore/0003-cutover-broker` onto `main`. Drop its `wrangler.toml` and README changes, which M1 supersedes. Keep `cutover.md`, and replace its "new Cloudflare account" Deviations row with this move. This branch is the step-5 PR.
1. **Owner:** NFR-3. The Google account's second step is a passkey or an authenticator app, and the backup codes are kept offline. CC records only yes or no.
2. **Owner:** billing pre-flight. List the projects on the billing account, with their active Secret Manager versions and Artifact Registry storage, because those free tiers are per billing account. The total stays at most 6 versions and well under 0.5 GiB once the broker is added. Otherwise stop and go back to the owner.
3. **Owner:** create `agent-bot-broker-<suffix>` with the label, and link billing. Run `DRY_RUN=1 broker/setup.sh`, paste the output for CC to review, then run it.
4. **Owner (0003 M3 step 2, on Cloud Run):**
   - On GitHub, make new private keys for `-claude` and `-agy`, and delete their step-1 keys (Deviations).
   - Make a new login client secret.
   - Load the four secrets with `put-secret.sh`. `ci-key` is today's bot key.
   - Run `deploy.sh`. `/healthz` answers `{"ok":true,"enabled":true}`.
5. **Checkpoint (0003 M3 step 3).** With `BOT_BROKER_URL` set to the new URL, CC opens the step-0 branch as a PR through the new broker. Its author must be `app/jomaries777-claude`. Then:
   - Kill switch: the owner runs `deploy.sh --disable`, and CC's `bot-token.sh --agent claude` fails with `disabled (HTTP 503)`. Then `--enable`.
   - Cold start: after 15+ idle minutes, CC times `/healthz`.

   If any check fails, unset `BOT_BROKER_URL`. The old broker still works.
6. **Move devices (FR-7).** The owner revokes the login App's authorization, then runs `scripts/bot-login.sh --broker <url>` on each device. The "Template projects (bot relay)" environment gets the new network secret (path prefix `/relay`) and `BOT_BROKER_URL`. Then CC checks:
   - `make doctor` passes on each device, with no `workers.dev` warning.
   - `bot-token.sh --agent agy` succeeds.
   - A cloud session's `bot-relay.sh` opens a draft PR.

   **AGY:** its first run on the new broker is 0003 M4's docs task, as 0003's plan says. That PR's author is `app/jomaries777-agy`.
7. **0003 M3 steps 4–10, as its plan says.** In step 5, the new `-ci` key goes in through `put-secret.sh ci-key` and `deploy.sh`, and the old bot key is deleted on GitHub. From then on the old Worker answers `401` to everyone.
8. **Owner (in place of 0003 M3 step 11):**
   - Delete the login App's old client secret on GitHub.
   - Run `put-secret.sh --prune` for each secret.
   - Paste the fingerprint of each remaining App key from its settings page.
9. **Owner:** run the Proof commands for criteria 1–4, 7 and 16, and paste the output. The 7 idle days for criterion 15 start now.
10. **CC:** update 0003's Deviations and Progress, the cutover record and this plan's Progress. M2 closes when criterion 15 is recorded; M3 and M4 don't wait for it.

### M3: Workers sandbox

| Who | Task | Owns |
|---|---|---|
| Owner | Archive `sandbox-node-workers`, after its 2026-12-01 metrics run if that hasn't happened yet (Risks). Empty `x7k2-apps`: its project Workers and the stray `agent-bot-broker`. If sign-in fails, try its API token, and note whatever can't be deleted | – |
| CC | Record criterion 13 (`gh repo view … isArchived`, and what's left in `x7k2-apps`) | `spikes/retire-workers.md` |

AGY has no M3 task. It starts its M4 work during M3.

### M4: Remove the target

The tasks start during M3. The bot PR merges only after criterion 13 is recorded. FR-11 merges only after 0003's #106 (C13).

| Who | Task | Owns |
|---|---|---|
| AGY | **4a Target and docs** (`teamwork`).<br>• Delete `deploy/targets/cloudflare-workers/`, `worker.ts` and its test.<br>• Edit `routes.ts`, the Go and Python stack READMEs, and the comment in `deploy.yml`.<br>• `README.md`: quick-start step 2, the prerequisites and the target table.<br>• "Amended by 0004" notes at each section of specs 0001–0003 that the spec names | `deploy/targets/cloudflare-workers/`, `stacks/**`, `deploy.yml`, `README.md`, `intent/000{1,2,3}-*/spec.md` |
| CC | **4b Scripts and tests.** Remove the target from `bootstrap.sh`, `sdlc-metrics.sh`, `release.sh` and the five test files, with a test that `TARGET=cloudflare-workers` fails as an unknown target. `CLAUDE.md` changes only if a command changes | `scripts/{bootstrap,sdlc-metrics,release}.sh`, `tests/scripts/test_{bootstrap,bootstrap_target,deploy,deploy_config,sdlc_metrics}.sh`, `CLAUDE.md` |
| CC | **4c Workflow draft** for the owner: FR-11's removals from `deploy.yml` and `maintain.yml`, on a branch | `.github/workflows/{deploy,maintain}.yml` |
| Owner | Push 4c as an owner PR after #106 merges. Delete the `CLOUDFLARE_*` variables and secrets from the template's settings | – |

## Risks

| Risk | Mitigation |
|---|---|
| AGY reports success but changes nothing (CLAUDE.md) | CC checks `git diff` and `make lint test` after every AGY run |
| Claude shares the owner's gcloud login, which owns the broker project | `no-secrets.sh` blocks every `gcloud`/`gsutil`/`bq` command naming `agent-bot-broker`, the three owner scripts and `gcloud secrets versions access`. The owner runs every broker-project command. Recorded as a deviation from C10 |
| The free tiers are per billing account, and other projects on it use some of them | M2 step 2 measures what they use and stops if the broker would go over. The $1 budget alerts at 50% |
| TTL deletes aren't free | No TTL policy. The broker prunes with ordinary deletes, which fall in the free 20,000 a day (owner decision) |
| A key goes to the wrong project, or an empty key is saved (the 2026-11-28 incident) | Every `gcloud` line passes `--project`, and the scripts refuse a project without the label. `put-secret.sh` refuses empty and non-PEM input (criterion 9) |
| A client forges `X-Forwarded-For` | S1 finds which entry Google's front end adds, and a handler test pins that rule |
| The build fails without Editor on the default compute account | S3 tests it before the build. If it fails, the gate goes back to the owner |
| A cold start exceeds a script's `--max-time` | S1 measures it. The shortest timeout is 10 s, in `doctor.sh` |
| Devices are signed out at step 6 and one is missed | Step 6 lists every device and the cloud environment before the revoke, and runs in the same sitting |
| AGY runs while the sign-in is changing | No AGY run between M2 steps 4 and 6 |
| AGY edits a protected path | AGY owns only unprotected paths, and `agy-run.sh`'s gate refuses anything else |
| FR-11 and #106 both change `deploy.yml` | 4c merges after #106 (C13) |
| Archiving `sandbox-node-workers` stops its monthly metrics run (0001 criterion 9, due 2026-12-01) | Archive it after that run, or record in M3 that the run was skipped |
| The spike project stays up | M0 deletes it, and records the deletion and its bill |

## Progress

| Milestone | Status | PRs |
|---|---|---|
| M0: spikes ‖ server adapter | S1–S3 done 2026-11-28 ([results](spikes/s1-s3-results.md)); gate with the owner (image size, budget). 0a on `agy/0004-leave-cloudflare`, for the M1 PR | – |
| M1: broker build | In progress: 1b and 1c on `feat/0004-broker-build`; 1a with AGY (teamwork, owner-driven); 0a on #111 | – |
| M2: cutover, with 0003 M3 | Not started | – |
| M3: Workers sandbox | Not started | – |
| M4: remove the target | Not started | – |

## Proof

`<P>` is the broker project and `<url>` the service URL. Rows marked **Owner** run in the owner's terminal, because the hook blocks CC from naming `<P>`. CC records the output.

| Check | Command | Expected | Spec criterion |
|---|---|---|---|
| Lint and tests | `make lint test` | exit 0; every test `ok` | all |
| Dedicated project (Owner) | `gcloud projects describe <P> --format 'value(labels.purpose)'`; `gcloud run services list --project <P>`; `gcloud iam workload-identity-pools list --location global --project <P>`; `gcloud iam service-accounts keys list --managed-by user --iam-account <sa> --project <P>` for each account. CC: `gh variable get GCP_PROJECT_ID -R <repo>` for each of the owner's repos | `agent-bot-broker`; only `agent-bot-broker`; empty; empty; `<P>` isn't `pse-advisor-feat001` and isn't any repo's `GCP_PROJECT_ID` | 1 |
| Service settings (Owner) | `gcloud run services list --project <P> --format 'value(metadata.name,region)'`; `gcloud firestore databases describe --database '(default)' --project <P> --format 'value(locationId)'`; `gcloud run services describe agent-bot-broker --project <P> --region us-west1 --format json` | `agent-bot-broker us-west1`; `us-west1`; no min instances, `maxScale` 1, `broker@<P>`, no traffic tags, `BROKER_ENABLED=true`, four secrets at numbered versions | 2 |
| Least privilege (Owner) | `gcloud secrets get-iam-policy <secret> --project <P>` for each secret; `gcloud projects get-iam-policy <P>` | `broker@` is each secret's only accessor; `broker@` has only `roles/datastore.user` at the project; the default compute account has no `roles/editor` | 3 |
| Secret versions (Owner) | `gcloud secrets versions list <secret> --project <P> --filter 'state!=DESTROYED'` for each secret | exactly 1 each | 4 |
| Health and kill switch | `curl -s <url>/healthz`; after the owner's `deploy.sh --disable`, `bot-token.sh --agent claude`; after `--enable`, again; `tests/scripts/test_broker_deploy.sh` | `{"ok":true,"enabled":true}`; `disabled (HTTP 503)` and `"enabled":false`; works; `ok` for "plain deploy keeps disabled" | 5 |
| Tokens through the new broker | `gh pr view <n> --json author -q .author.login` for the M2 step-5 PR; `bot-token.sh --agent agy`; `bot-relay.sh` from the cloud environment | `app/jomaries777-claude`; a token; a draft PR | 6 |
| Audit (amended) | Owner: the console or a `gcloud firestore` query on `audit` after criterion 6, and `gcloud firestore fields ttls list --project <P>`. CC: `node --test tests/broker/handler.test.mjs tests/broker/firestore.test.mjs` | A document per call, with `agent` set and `expire_at` = `ts` + 90 days; no TTL policy; `ok` for `503 audit_unavailable` when the store fails, `429 rate_limited` after 30 owner `/token` calls in an hour, and a prune that deletes only expired documents, at most 50, and never changes the answer | 7 |
| Broker tests | `node --test tests/broker/*.test.mjs`; `grep -rE 'AUDIT\|D1\|CF-Connecting-IP' broker/src` | every case `ok`, including the server adapter (headers, body stream, 1 KB and 1 MB caps), the `X-Forwarded-For` entry, the store's queries and the cached metadata token; grep finds nothing | 8 |
| Owner scripts and hook (amended) | `tests/scripts/test_broker_setup.sh`, `test_broker_put_secret.sh`, `test_broker_deploy.sh`, `test_hooks.sh` | `ok` for: `--project` on every `gcloud` line and `us-west1` on every regional one; refusal without the label, with a pool, or with another service; refusal of empty and non-PEM input, and no key material in the output; the hook blocks (exit 2) the three scripts, `gcloud secrets versions access`, and any `gcloud`/`gsutil`/`bq` command naming `agent-bot-broker`, and lets other `gcloud` commands and `curl` to `<url>` through | 9 |
| Old broker cut off | The cutover record and each App's settings page | Dated deletions of the old bot key, the old login client secret and the step-1 `-claude` and `-agy` keys; the remaining fingerprints; one key per App. No identity is sent to the old URL | 10 |
| Devices moved | `make doctor` on each device; `tests/scripts/test_doctor.sh` | passes with no `workers.dev` warning; `ok` for the warning on a `*.workers.dev` URL | 11 |
| No Cloudflare left | `git grep -nIiE 'cloudflare\|wrangler\|workers\.dev\|CLOUDFLARE_' -- ':!intent/' ':!scripts/doctor.sh' ':!tests/scripts/test_doctor.sh'`; `test -e deploy/targets/cloudflare-workers`; `tests/scripts/test_bootstrap_target.sh` | nothing; exit 1; `ok` for "cloudflare-workers is an unknown target" | 12 |
| Workers sandbox | `gh repo view Jomaries777/sandbox-node-workers --json isArchived -q .isArchived`; `spikes/retire-workers.md` | `true`; says whether `x7k2-apps` was emptied, and what's left | 13 |
| Docs | `make lint test`; `grep -ni 'amended by 0004' intent/000{1,2,3}-*/spec.md`; `grep -n 'Cloud Run broker' intent/0003-per-agent-identity/plan.md` | green; a note at each section the spec names; the Deviations row | 14 |
| Cost (Owner) | `gcloud billing budgets list --billing-account <id>`; the billing report for `<P>` after 7 idle days | the $1 budget scoped to `<P>` with 50/90/100% alerts; `$0.00`, with the date in Progress | 15 |
| Key reads logged (Owner) | `gcloud logging read 'protoPayload.methodName:"AccessSecretVersion"' --project <P> --limit 20` | entries, each with principal `broker@<P>` | 16 |
| Plan check | `verifier` subagent against this table | pass, with evidence | all |

## Deviations

| Date | What changed from the spec | Why | Approved by |
|---|---|---|---|
| 2026-11-28 | **At planning: no TTL policy.** The broker prunes expired audit rows itself (about 1 in 50 inserts, at most 50 rows), and `setup.sh` sets no TTL policy. FR-4, the Firestore row, the audit-store table, S2 and criterion 7 are amended | The Firestore pricing page (2026-11-28) gives TTL deletes no free quota. Ordinary deletes fall in the free 20,000 a day, and an idle broker then makes no Firestore calls | Owner, 2026-11-28 |
| 2026-11-28 | **At planning: the hook blocks the broker project.** `no-secrets.sh` blocks any `gcloud`/`gsutil`/`bq` command naming `agent-bot-broker`, besides the three C10 commands. The owner runs every broker-project command, read-only checks included. C10 and criterion 9 are amended | On this Mac, Claude's Bash uses the owner's only gcloud login, which owns the broker project. So C10's "no role in the broker project" doesn't hold, and the hook is the guard | Owner, 2026-11-28 |
| 2026-11-28 | **At planning: the step-1 `-claude` and `-agy` keys are deleted at M2 step 4**, not at 0003 M3 step 11 | Nothing in this plan uses them, and the stray Worker in `x7k2-apps` holds them. The rollback is the old broker URL, which uses only the old bot key | Owner, with this plan |
| 2026-11-28 | **At the M0 gate: the broker builds from a `node:22-alpine` `Dockerfile`**, not buildpacks. `broker/Dockerfile` is added (owned by 1a), and `deploy.sh` passes `--clear-base-image` | S3: the buildpacks image of a trivial server is 139 MiB, so the 2 kept images would hold about 278 MiB of the 0.5 GiB Artifact Registry tier, which the whole billing account shares (NFR-1). A buildpacks deploy also sets a managed base image, and the first Dockerfile deploy refuses to run without `--clear-base-image` | Owner, 2026-11-28 |
| 2026-11-28 | **At the M0 gate: a cold start of 1.86–1.96 s is accepted** | At the edge of Decision 7's ~2 s; every script's timeout is 10 s or more | Owner, 2026-11-28 |
| 2026-11-28 | **In M1: `broker/lib.sh`** holds the helpers the three owner scripts share (`run`, dry-run fixtures, the label and clean-project checks) | One copy of the checks FR-6 asks of every script, modelled on `deploy/targets/cloud-run/lib.sh` | CC, with this PR |
| 2026-11-28 | **In M1: `setup.sh` sets no Firebase security rules** | A Firestore database made with `gcloud` answers unauthenticated clients `403 PERMISSION_DENIED` (checked 2026-11-28 in the spike project), so "rules deny every client" holds without the Firebase Rules API, which isn't in the spec's API list | CC, with this PR |
| 2026-11-28 | **In M1: `deploy.sh` pins the newest enabled version of each secret** | The spec's "reads the live secret versions first" and "a new version from put-secret.sh" are the same rule: the newest enabled version is the live one until `put-secret.sh` adds another. A rollback before `--prune` disables the new version and deploys | CC, with this PR |
| 2026-11-28 | **In M1: CC fixed `broker/src/server.js` (task 0a)** after AGY's boost run didn't exit: cancelling the body destroyed the socket, so an oversized request got `ECONNRESET` instead of `413 too_large` | AGY owns the file, but its run hung for an hour; the fix is small and has a test | CC, recorded in the 0a commit |
| 2026-11-28 | **In M1: files outside `intent/` refer to the 0004 folder as `intent/0004-*/`** | Criterion 12's grep for `cloudflare` matches the folder's own name, so a path to it would fail the check. Applies to M4's docs too | CC, with this PR |
