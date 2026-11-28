# Spec: Leave Cloudflare

| Field | Value |
|---|---|
| Status | Draft |
| Intent | [intent.md](intent.md), accepted by the owner on 2026-11-28 (#107) |
| Created | 2026-11-28 |
| Owner decisions | Intent decisions 1–9 (2026-11-28). C1–C14 decided by the owner on 2026-11-28: each follows the [playbook](https://claude.com/resources/articles/the-ai-native-sdlc-playbook) where it speaks to the concern, and the proposal where it doesn't. Each row names its basis. C4: `us-west1`. Only C10 goes further than the proposal |
| Amends | [0001 spec](../0001-github-cicd-pipeline/spec.md) FR-13, §3, §4.1, §4.5, §4.9, §4.11 and C10; [0002 spec](../0002-bot-identity-any-device/spec.md) NFR-1, NFR-6, "Phase 2: the broker", C1 and criteria 9 and 13; [0003 spec](../0003-per-agent-identity/spec.md) NFR-1, NFR-5 and criteria 6 and 13. Each amended section gets an "amended by 0004" note; their history isn't rewritten |
| Next artifact | `plan.md` in this folder, written in plan mode once this spec is accepted. The acceptance criteria below become its Proof |

## Requirements

### Functional

| ID | Requirement | Intent ref |
|---|---|---|
| FR-1 | The broker runs as one Cloud Run service, `agent-bot-broker`, in a new GCP project that holds only the broker. Request-based billing, no minimum instances, at most 1 instance, no traffic tags. Anyone can reach the URL (`allUsers` has `run.invoker`), because callers prove who they are with the login App's token, not a Google one (C1). | Constraints "the host is decided"; Decisions 2, 7 |
| FR-2 | The HTTP contract doesn't change: `POST /token`, `/relay`, `/relay/`, `/secrets` and `GET /healthz` take the same bodies and give the same answers and error codes as today (`broker/README.md`). `handler.js`, `relay.js`, `secrets.js`, `jwt.js`, `github.js` and `seal.js` keep their logic. Only the audit store and the caller's IP change (FR-4, Design). | Outcome "keeps every guarantee it has today" |
| FR-3 | The four secrets live in Secret Manager: `claude-key`, `agy-key`, `ci-key` (each a PKCS#8 PEM) and `login-client-secret`. Cloud Run gives them to the service as the environment variables it reads today (`CLAUDE_KEY_PKCS8`, `AGY_KEY_PKCS8`, `CI_KEY_PKCS8`, `LOGIN_CLIENT_SECRET`), each from a pinned version number, never `latest` (C8). The service's own identity can read those four secrets and nothing else in Secret Manager. | Constraints "Secret Manager holds the keys", "security holds" |
| FR-4 | The audit log is the `audit` collection of the project's `(default)` Firestore database, in Native mode. Each document has today's columns plus `expire_at` (`ts` + 90 days), and a Firestore TTL policy on `expire_at` deletes old rows. The rate guard counts the caller's rows of the last hour with a count query. If Firestore can't be reached, or the query's index is missing, the broker answers `503 audit_unavailable`, as today. The new log starts empty (Decision 5). | Outcome "every token is audited"; Decision 5 |
| FR-5 | **Kill switch.** `BROKER_ENABLED` is an environment variable of the service. `broker/deploy.sh --disable` sets it to `false` in a new revision, without a rebuild, and every request then gets `503 disabled`. `--enable` sets it back. A plain deploy keeps the live value, so a deploy never turns a disabled broker back on. For an emergency, removing `allUsers` from `run.invoker` makes Google refuse every request before it reaches the broker. | Outcome "the kill switch works" |
| FR-6 | **Owner scripts**, run by the owner with their own `gcloud` login, never from CI and never by an agent:<br>• `broker/setup.sh`: one-time, idempotent project setup (Design, "The broker project").<br>• `broker/put-secret.sh <secret> <file>`: converts a key to PKCS#8, refuses empty input or anything that isn't a PEM private key, adds a version, deletes the file, and destroys the older versions once the new one is deployed.<br>• `broker/deploy.sh`: builds from `broker/` and deploys with the pinned secret versions.<br>Every `gcloud` command passes `--project`. Each script refuses a project without the label `purpose=agent-bot-broker`, and `setup.sh` and `deploy.sh` refuse one that has a workload identity pool, user-managed service account keys or another Cloud Run service. Each has a `DRY_RUN=1` mode that prints its commands, for tests. | Constraints "security holds", "only the owner runs steps that touch a key"; the cutover incident |
| FR-7 | **Devices and cloud sessions move once.** After the new broker passes its checkpoint, the owner revokes the login App's authorization, which signs every device out (C5). Each device then runs `scripts/bot-login.sh --broker https://<service URL>`. The "bot relay" cloud environment gets the new identity as its network secret for the new host (path prefix `/relay`) and the new `BOT_BROKER_URL`. `bot-token.sh`, `bot-relay.sh` and `bot-secrets.sh` need no change: they already accept any `https://host`. | Outcome "devices and cloud sessions sign in once" |
| FR-8 | **Nothing the Cloudflare accounts hold still works.** On GitHub, the owner deletes every key and secret a Cloudflare account has held: the old `jomaries777-agent-bot` key (0003 M3 step 5, rotating the `-ci` key), the login App's old client secret, and the `-claude` and `-agy` keys made at 0003 M3 step 1 (C6). The new broker gets new keys and a new client secret. `doctor.sh` gets no check for the old keys (Decision 8). | Outcome "the old Worker is no longer trusted"; Decision 8 |
| FR-9 | `scripts/doctor.sh` warns when the device's broker URL is still a `*.workers.dev` host (C9), and its broker hint names `broker/deploy.sh --disable` instead of `wrangler.toml`. | Outcome "devices … sign in once" |
| FR-10 | **The `cloudflare-workers` target is removed**, after the broker has moved (Decision 6) and after `sandbox-node-workers` is archived (FR-12): `deploy/targets/cloudflare-workers/`, `stacks/node/src/worker.ts` and its test, the Workers comments in `stacks/node/src/routes.ts`, the Workers notes in the stack READMEs, the target from `deploy.yml`'s comment, the `CLOUDFLARE_API_TOKEN` tracking in `scripts/sdlc-metrics.sh`, the wrangler comment in `bootstrap.sh`, and every test case that names the target. `make bootstrap TARGET=cloudflare-workers` fails as an unknown target. `cloud-run`, `github-pages`, `local` and `none` stay (Decision 9). | Outcome "the template has no Cloudflare dependency left"; Decisions 6, 9 |
| FR-11 | **Workflows (owner PR).** `deploy.yml` drops `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_WORKERS_SUBDOMAIN` and both `CLOUDFLARE_API_TOKEN` step variables. `maintain.yml` drops `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_WORKERS_SUBDOMAIN` and `CLOUDFLARE_API_TOKEN_SET_AT`. This PR comes after 0003's #106, which also changes `deploy.yml` (C13). | Constraint "the bot never edits `.github/workflows/`" |
| FR-12 | **Retire the Workers sandbox.** `sandbox-node-workers` is archived. The `x7k2-apps` account is emptied: its project Workers, and the stray `agent-bot-broker` Worker made at the failed 0003 M3 step 2. If the owner can't sign in to it, its API token is tried, and whatever can't be deleted is recorded. Either way, FR-8 has already revoked every key it holds. | Decision 4 |
| FR-13 | **Docs follow the change.** `broker/README.md` is rewritten for Cloud Run (setup, keys, deploy, kill switch, audit queries, rotation). `README.md` quick-start step 2, the prerequisites and the target table drop Cloudflare. The "amended by 0004" notes go in specs 0001–0003. 0003's `plan.md` records in Deviations that M3 finishes on the new broker. `.claude/settings.json` drops its `wrangler` deny rules and adds deny rules for `gcloud secrets versions access` and for `broker/put-secret.sh` and `broker/deploy.sh`. `scripts/hooks/no-secrets.sh` blocks the same three commands on Bash, so the rule doesn't rest on the deny list alone (C10). The spike records under `intent/` stay as they are. | Outcome "Workers proofs stay in the spike records" |

### Non-functional

| ID | Requirement | Intent ref |
|---|---|---|
| NFR-1 | **$0 when idle** (`cost-guard`). Nothing runs always-on: Cloud Run scales to zero, and the service has at most 1 instance. Everything stays inside the free tiers: Cloud Run requests and CPU, at most 6 active Secret Manager versions (4 at rest, 5 during a rotation) and its free access operations, Firestore's free daily reads, writes and deletes and its 1 GiB, Cloud Build's free build minutes and Artifact Registry's 0.5 GB, kept with a cleanup policy that keeps the 2 newest images. A budget of $1 on the project sends alerts at 50%, 90% and 100%. The free tiers are checked again on the pricing pages while the plan is written, and the date is recorded. | Constraint "$0 when idle" |
| NFR-2 | **Security holds, or gets stronger** (`secure-change`). Keys never reach a device, a log, the repo or Claude. The service runs as its own service account, `broker@`, with `secretAccessor` on the four secrets only and `datastore.user` on the project, and no other role. Builds run as their own service account, `builder@`, which can't read secrets (C2). The project has no workload identity pool and no service account keys, so no deploy credential of another project can reach it. Secret Manager's data-access audit logs are on, so every read of a key is logged with who read it. | Constraint "security holds as today, or gets stronger" |
| NFR-3 | **Sign-in without email codes.** Before the cutover, the owner's Google account has a passkey or an authenticator app as its second step, and its backup codes are kept offline. The plan records this check. | Constraint "sign-in must not depend on email codes" |
| NFR-4 | **No downtime for agents.** The old Worker serves until the new broker passes its checkpoint. After that, a device can't get a token only between the owner revoking the login App (FR-7) and that device signing in again, which happens in the same sitting. | Constraint "no downtime for agents" |
| NFR-5 | **Cold start.** A first request after idle may take about 1–2 s (Decision 7). The plan measures it, and the scripts' `curl --max-time` must leave room for it. | Decision 7 |
| NFR-6 | **No new runtime dependency.** The broker talks to Firestore and the metadata server over REST with `fetch` (C3), so its dependencies stay `tweetnacl` and `@noble/hashes`. `make test` stays offline: GitHub, Firestore and the metadata server are fakes. | 0002 NFR-6 |

## Design

### Overview

```text
device:  scripts/bot-token.sh --agent claude owner/repo
           → POST https://agent-bot-broker-<number>.us-west1.run.app/token
Cloud Run (project: agent-bot-broker-<suffix>, service account broker@)
  broker/src/server.js   Node 22 http server → Request → handle() → Response
  env:   config.yaml values + 4 secrets from Secret Manager (pinned versions)
  audit: Firestore (default) / audit   ← REST, token from the metadata server
GitHub:  "Check a token" (login App), App JWT → installation token
```

### The broker project

`broker/setup.sh` creates or checks each of these. The owner runs it once per owner, and again whenever it changes.

| Resource | Setting |
|---|---|
| Project | A new project, `agent-bot-broker-<suffix>`, label `purpose=agent-bot-broker`, linked to the owner's billing account. Never `pse-advisor-feat001`, and never a project that a deploy target uses (`GCP_PROJECT_ID` of any repo) |
| APIs | Cloud Run, Cloud Build, Artifact Registry, Secret Manager, Firestore, IAM, Billing Budgets |
| Service accounts | `broker@` (runtime) and `builder@` (builds). The default compute service account loses its automatic Editor role (C2) |
| Secret Manager | The four secrets, created empty, with automatic replication. `broker@` gets `roles/secretmanager.secretAccessor` on each secret, not on the project |
| Firestore | `(default)` database, Native mode, location `us-west1`, the service's region. Security rules deny every client. Composite index on `audit` (`caller_id`, `endpoint`, `ts`). TTL policy on `audit.expire_at` |
| Artifact Registry | The `cloud-run-source-deploy` repository with a cleanup policy that keeps the 2 newest images |
| Audit logs | `DATA_READ` audit logs on for `secretmanager.googleapis.com` |
| Budget | $1 on this project, alerts at 50%, 90%, 100% |
| Region | **`us-west1`** for the Cloud Run service, Firestore and Artifact Registry (C4). `setup.sh` and `deploy.sh` use it by default, and refuse another region unless `BROKER_REGION` is set, so a new owner can pick their own |

### Runtime

- **Entry point.** `broker/src/server.js` replaces the Workers entry point `broker/src/index.js`. It listens on `$PORT`, turns each Node request into a WHATWG `Request` (the body is passed as a stream, so `readJson`'s byte caps still hold), calls `handle(request, env, deps)` and writes the `Response` back. Node 22 has `fetch`, `Request`, `Response`, `crypto.subtle`, `atob` and `btoa`, so `jwt.js` and `seal.js` run unchanged.
- **Configuration.** Non-secret values (`OWNER_LOGIN`, `OWNER_ID`, the three App IDs and slugs, `LOGIN_CLIENT_ID`) move from `wrangler.toml` to `broker/config.yaml`, which `deploy.sh` passes with `--env-vars-file`. `BROKER_ENABLED` comes from the live service (FR-5). `env` is built from `process.env` once, at start.
- **Caller IP.** `row.ip` comes from `X-Forwarded-For`, taking the entry that Google's front end added, not one the client can write (S1). `CF-Connecting-IP` is gone.
- **Size.** 1 vCPU, 512 MiB, concurrency 80, request timeout 60 s, at most 1 instance. The relay's limit of about 21 GitHub calls stays, though Cloud Run doesn't need it.

### Audit store

`handler.js` stops using `env.AUDIT` (D1) and calls an audit store passed in `deps.audit`, with three methods:

| Method | Firestore REST call | Replaces |
|---|---|---|
| `ready()` | A `runQuery` on `audit` with `limit 1`, cached once it succeeds | `schemaOk` (D1 table check) |
| `countLastHour(callerId, endpoint, sinceMs)` | `runAggregationQuery` with `count`, filtered on the three indexed fields | `requestsLastHour` |
| `insert(row)` | `createDocument` in `audit`, with `expire_at` | the D1 `INSERT` and the 1-in-50 prune |

`broker/src/firestore.js` implements it. It gets an access token for `broker@` from the metadata server (`Metadata-Flavor: Google`), caches it until a minute before it expires, and never logs it. When a call fails, the store throws, and `identify` answers `503 audit_unavailable`, as it does today. One `/token` costs one count query and one write: well inside the free tier for 30 requests an hour.

`broker/schema.sql`, `broker/migrations/` and `broker/wrangler.toml` are deleted. The audit rows keep their fields (`ts`, `caller_id`, `endpoint`, `agent`, `repo`, `outcome`, `reason`, `expires_at`, `ip`, `branch`, `files`, `paths`), so `broker/README.md`'s audit query becomes a `gcloud firestore` or console query over the same fields.

### Keys and rotation

```text
owner:  broker/put-secret.sh claude-key ~/claude.pem
          openssl pkcs8 -topk8 -nocrypt → non-empty PEM check → versions add (stdin)
          → rm ~/claude.pem → prints the new version number
owner:  broker/deploy.sh    (pins claude-key:<new>; the old version stays until this passes)
owner:  broker/put-secret.sh --prune claude-key   (destroys every version but the deployed one)
```

The key is read from the file and piped to `gcloud secrets versions add --data-file=-`, so it is never in a command line, an environment variable or the scripts' output. `put-secret.sh` refuses an empty or non-PEM input: on 2026-11-28 an empty Worker secret was saved because nothing checked. Rotating an App key adds `bot-secrets.sh` for `claude` and `ci`, as today. Destroying old versions keeps the project at 4 active versions (NFR-1).

### Deploy

`broker/deploy.sh` runs `gcloud run deploy agent-bot-broker --source broker --project <P> --region us-west1 --service-account broker@… --build-service-account builder@… --env-vars-file broker/config.yaml --set-secrets <4 pinned versions> --max-instances 1 --allow-unauthenticated`, then checks `/healthz` and that the service has no traffic tags. It reads the live `BROKER_ENABLED` and the live secret versions first, so a deploy changes neither unless the owner asks (`--enable`, or a new version from `put-secret.sh`). The broker is never deployed from CI: the project has no workload identity pool, and no CI holds a credential for it.

### Cutover, with 0003 M3

The order, in short. The plan gives the steps.

1. **Build.** The Cloud Run broker, the owner scripts and their tests merge as one PR. Nothing is deployed.
2. **Spikes** S1–S3, in a throwaway project that is deleted after.
3. **Project.** The owner checks NFR-3, creates the project, and runs `setup.sh`.
4. **Keys (0003 M3 step 2, on Cloud Run).** The owner makes new private keys for `-claude` and `-agy` and a new login client secret, and loads them with today's bot key as `ci-key`. Then deploys.
5. **Checkpoint (0003 M3 step 3).** From a device that has saved the new URL, the owner opens a PR through the new broker. Its author must be `app/jomaries777-claude`. If the check fails, devices keep the old broker URL, which still works.
6. **Move devices (FR-7).** The owner revokes the login App's authorization, then signs in each device and the cloud environment again, in the same sitting.
7. **The rest of 0003 M3** (steps 4–11), as its plan says. Its step 5 deletes the old bot key. Step 11 deletes the old login client secret and the step-1 `-claude` and `-agy` keys (FR-8). After that the old Worker answers `401 bad_token` to everyone, and the stray Worker in `x7k2-apps` holds only revoked keys.
8. **Workers sandbox.** `sandbox-node-workers` is archived and `x7k2-apps` emptied (FR-12).
9. **Remove the target.** A bot PR for FR-10 and FR-13, and an owner PR for FR-11.

### Spikes before the build

| Spike | Question | Where |
|---|---|---|
| S1 | Does a public Cloud Run service pass `Authorization: Bearer <non-Google token>` and `X-GitHub-Token` to the container unchanged? Which `X-Forwarded-For` entry is the client's, and can the client forge it? How long is a cold start of the Node server? | A throwaway project in `us-west1`, with an echo service and dummy header values (never a real token) |
| S2 | Does the REST count query with the composite index return the right count, and does a missing index give an error the store turns into `503`? Does the TTL policy delete an expired document? | The same project |
| S3 | Does `gcloud run deploy --source --build-service-account builder@` build and deploy when the default compute service account has no Editor role? | The same project |

Results go in `intent/0004-leave-cloudflare/spikes/`. The throwaway project is deleted after, and its deletion is recorded.

### Security review

| Check | How this design meets it |
|---|---|
| No secret in code, config, logs or tests | Keys only in Secret Manager. `put-secret.sh` pipes them from a file. `config.yaml` holds IDs only. Tests generate keys at run time |
| Least privilege | `broker@`: four `secretAccessor` bindings and `datastore.user`. `builder@`: build roles only. No workload identity pool or service account keys in the project |
| Who can change the broker | Only the owner's Google account, with passkey or authenticator 2FA (NFR-3). Admin activity and secret reads are in Cloud Audit Logs |
| Untrusted input | The same validation as today. The caller IP is taken only from the entry Google's front end added (S1) |
| A compromised broker project | The App keys leak, as with a compromised Cloudflare account today. Same response: kill switch, delete the keys on GitHub, revoke the login App |
| The lost Cloudflare accounts | They hold only keys and identities that FR-7 and FR-8 revoke |

### Files that change

| Area | Files |
|---|---|
| Broker | `broker/src/server.js` (new), `broker/src/firestore.js` (new), `broker/src/handler.js` (audit store, IP), `broker/src/relay.js` (comment on the subrequest cap), `broker/src/index.js`, `wrangler.toml`, `schema.sql`, `migrations/` (deleted), `broker/config.yaml` (new), `broker/package.json` (`engines`, `start`), `broker/.gcloudignore` (new), `broker/README.md` |
| Owner scripts | `broker/setup.sh`, `broker/put-secret.sh`, `broker/deploy.sh` (new), `tests/scripts/test_broker_setup.sh`, `test_broker_put_secret.sh`, `test_broker_deploy.sh` (new) |
| Broker tests | `tests/broker/helpers.mjs` (a fake Firestore and metadata server in place of the D1 stub), `handler.test.mjs`, `relay.test.mjs`, `secrets.test.mjs`, `server.test.mjs` (new), `firestore.test.mjs` (new) |
| Device scripts | `scripts/bot-login.sh` (usage text), `scripts/doctor.sh` (FR-9), `tests/scripts/test_bot_login.sh`, `test_doctor.sh` |
| Target removal | `deploy/targets/cloudflare-workers/` (deleted), `stacks/node/src/worker.ts`, `stacks/node/test/worker.test.ts` (deleted), `stacks/node/src/routes.ts`, `stacks/go/README.md`, `stacks/python/README.md`, `deploy.yml`, `scripts/bootstrap.sh`, `scripts/sdlc-metrics.sh`, `scripts/release.sh` (comment), `tests/scripts/test_bootstrap.sh`, `test_bootstrap_target.sh`, `test_deploy.sh`, `test_deploy_config.sh`, `test_sdlc_metrics.sh` |
| Workflows (owner PR) | `.github/workflows/deploy.yml`, `.github/workflows/maintain.yml` |
| Config | `.claude/settings.json`, `scripts/hooks/no-secrets.sh`, `tests/scripts/test_hooks.sh` |
| Docs | `README.md`, `CLAUDE.md` (only if a command changes), the amended sections of specs 0001–0003, `intent/0003-per-agent-identity/plan.md` (Deviations, Progress), `intent/0003-per-agent-identity/spikes/cutover.md` |

## Flagged concerns and policy conflicts

| # | Concern | Conflict | Decision (owner, 2026-11-28) |
|---|---|---|---|
| C1 | The service must allow unauthenticated calls (`allUsers` invoker), because devices prove who they are with a GitHub token, not a Google one. Anyone with the URL can send requests, as with `workers.dev` today. | Least privilege at the network edge. Floods cost requests and "Check a token" calls. | **Accept.** The playbook says nothing about the network edge of a service like this, so the proposal holds. Junk tokens write nothing; at most 1 instance caps cost; the budget alert warns. The emergency stop is removing `allUsers` (FR-5) |
| C2 | In a project with no organization, the default compute service account gets Editor, and source deploys used to build as it. A build identity with Editor could reach the secrets. | NFR-2, "the broker's GCP identity can read only its own secrets". | **Builds run as `builder@`, and setup removes Editor from the default compute account.** Playbook, Deploy ("CI/CD integration and deployment"): automated jobs get short-lived, scoped tokens and no standing production credentials. A build identity that could read the App keys would be one. S3 proves the build still works |
| C3 | Firestore through its REST API and `fetch`, or through `@google-cloud/firestore`. | The client library is a large dependency tree (gRPC) in a service that holds App keys. REST means more code of our own. | **REST** (NFR-6). The playbook says nothing about the number of dependencies, so the proposal holds. Three calls, offline tests with a fake |
| C4 | Region: `us-central1` (the `cloud-run` target's default), `us-west1`, or an Asian region close to the owner (UTC+8). | Latency against free-tier certainty. Every call goes on to GitHub anyway. | **`us-west1`**, for the service, Firestore and Artifact Registry. The playbook says nothing about regions; this was the owner's direct choice. Its free tier is rechecked with NFR-1, and the spikes run there too, so S1's cold start is measured where the broker will run |
| C5 | Revoking the login App's authorization signs every device and the cloud environment out at once. | NFR-4, "no downtime". Without it, an identity that the old Worker has seen would also work on the new broker, and the lost account may be recovered by someone else. | **Revoke**, in the same sitting as signing in again. Playbook, Deploy: no standing credentials, and each agent run acts under its own identity. An identity the old Worker has seen is a standing credential the owner no longer controls |
| C6 | The `-claude` key from 0003 M3 step 1 was deleted after loading, so the owner has no copy. The `-agy` key and today's bot key sit in a Worker in `x7k2-apps`. | Needs new keys for both agent Apps, which the 0003 plan didn't expect. | **New keys for all three Apps and a new client secret.** Same playbook basis as C5: no key the owner can't reach stays valid. Recorded in 0003's Deviations |
| C7 | A new owner now needs a GCP billing account (a card) for the broker, even if their project deploys to `github-pages`. Workers Free needed no card. | The template's "$0, no card" path for owners without GCP. | **Accept.** The playbook says nothing about what a new user must pay to start, so the proposal holds. The billing account is only an identity check, the budget alert guards it, and `cloud-run` is already the default target |
| C8 | Pinned secret versions mean a key rotation needs a deploy. `latest` would avoid that, but a new key would then take effect at whatever cold start comes next. | Simplicity of rotation against knowing which key is live. | **Pinned.** Playbook, Deploy: rollback is a single, rehearsed command, and the commit chain is the audit trail. A pinned version says exactly which key is live, and until `put-secret.sh --prune` runs, going back is one `deploy.sh` with the previous version. `deploy.sh` reports which versions are live |
| C9 | `doctor.sh` warns about a `*.workers.dev` broker URL. | Decision 8 ruled out a check for the old Worker's key. This check is about the device's URL, not the key. | **Add the warning.** Playbook: deterministic scripts do the checking, and AI is kept for judgment. `doctor.sh` is that check, and it shows which devices haven't moved |
| C10 | `.claude/settings.json` deny rules: the `wrangler` rules become dead, and new rules deny `gcloud secrets versions access` and the two owner scripts. | The deny list is a convenience, not a guard (CLAUDE.md). The real guard is that Claude's `gcloud` login has no role in the broker project. | **Back the rule with a hook** (playbook, Build, "Hooks as build-time guardrails": a skill or deny rule is advisory, and a policy that must hold without exception is backed by a hook). The deny rules change as proposed. `scripts/hooks/no-secrets.sh` also blocks a Bash command that runs `gcloud secrets versions access`, `broker/put-secret.sh` or `broker/deploy.sh`. The playbook also notes that a tool-level deny doesn't close every shell route, so the guard that holds in the end is still that Claude's `gcloud` login has no role in the broker project (NFR-2) |
| C11 | `docs/playbook-deviations.md` PB-41 cites a run in `sandbox-node-workers`, which will be archived. | History against links that still work. | **Keep it.** Playbook: every stage commits an artifact, and the commit chain is the audit trail, so records aren't rewritten. Archived repos keep their Actions runs readable |
| C12 | Max 1 instance means a flood could make the owner's own requests wait or fail with `429` from Cloud Run. | Availability against cost. | **Accept.** The playbook says nothing about rate limiting or instance caps, so the proposal holds. The kill switch is the answer to a flood anyway |
| C13 | FR-11's workflow PR and 0003's #106 both change `deploy.yml`. | Merge order. | **FR-11 waits until #106 is merged** (0003 M3 step 7). Playbook, Build: tasks that share files run one after another |
| C14 | The owner scripts live in `broker/`, which `bootstrap.sh` leaves out of new projects, while target adapters live in `deploy/targets/`. | Where template-only infrastructure goes. | **`broker/`.** The playbook places intents and skills in the product repo but says nothing about shared infrastructure, so the proposal holds. The broker isn't a deploy target, and one broker serves every project |

## Acceptance criteria

Each is checked by a command, a test, or a step recorded in the plan's Progress or in `intent/0004-leave-cloudflare/spikes/`. Together they become `plan.md`'s Proof. `<P>` is the broker project.

1. **Dedicated project.** `gcloud projects describe <P> --format 'value(labels.purpose)'` gives `agent-bot-broker`. `gcloud run services list --project <P>` lists only `agent-bot-broker`. `gcloud iam workload-identity-pools list --location global --project <P>` is empty. `gcloud iam service-accounts keys list --managed-by user` is empty for every account in `<P>`. `<P>` isn't `pse-advisor-feat001` and isn't the `GCP_PROJECT_ID` variable of any of the owner's repos.
2. **Service settings.** `gcloud run services list --project <P> --format 'value(metadata.name,region)'` gives `agent-bot-broker us-west1`. `gcloud firestore databases describe --database '(default)' --project <P> --format 'value(locationId)'` gives `us-west1`. `gcloud run services describe agent-bot-broker --project <P> --region us-west1 --format json` shows no minimum instances, `maxScale` 1, service account `broker@<P>`, no traffic tags, `BROKER_ENABLED=true`, and the four secrets at numbered versions (no `latest`).
3. **Least privilege.** `gcloud secrets get-iam-policy` on each secret gives `broker@` as its only accessor. `gcloud projects get-iam-policy <P>` gives `broker@` only `roles/datastore.user`, and the default compute account no `roles/editor`.
4. **Secret versions.** `gcloud secrets versions list <secret> --project <P> --filter 'state!=DESTROYED'` gives exactly 1 version for each of the four secrets.
5. **Health and kill switch.** `curl -s <url>/healthz` gives `{"ok":true,"enabled":true}`. After `broker/deploy.sh --disable`, `bot-token.sh --agent claude` fails with `disabled (HTTP 503)`, and `/healthz` gives `"enabled":false`. After `--enable`, it works again. A plain `deploy.sh` run while disabled leaves it disabled (script test).
6. **Tokens through the new broker.** The 0003 M3 step 3 PR, opened through the Cloud Run URL, has `gh pr view <n> --json author -q .author.login` = `app/jomaries777-claude`. `bot-token.sh --agent agy` also succeeds, and `bot-relay.sh` from the cloud environment opens a draft PR.
7. **Audit.** After criterion 6, the `audit` collection has a document for each call, with `agent` set and `expire_at` 90 days after `ts`. `gcloud firestore fields ttls list --project <P>` shows the policy on `audit.expire_at` as active. Broker tests show `503 audit_unavailable` when the store fails, and `429 rate_limited` after 30 owner `/token` calls in an hour.
8. **Broker tests.** `node --test tests/broker/*.test.mjs` gives `ok` for every existing case, plus: the server adapter passes headers and the body stream, and keeps the 1 KB and 1 MB caps; the IP comes from the right `X-Forwarded-For` entry; the Firestore store sends the count query and the insert, and caches the metadata token. `grep -rE 'AUDIT|D1|CF-Connecting-IP' broker/src` finds nothing.
9. **Owner scripts.** Script tests with `DRY_RUN=1` show: every `gcloud` line has `--project`, and every regional one `--region us-west1` (or `--location us-west1`) unless `BROKER_REGION` is set; `setup.sh` and `deploy.sh` refuse a project without the label, with a workload identity pool, or with another service; `put-secret.sh` refuses an empty file and a non-PEM file, and never prints key material. Hook tests show `no-secrets.sh` blocks (exit 2) a Bash command running `gcloud secrets versions access`, `broker/put-secret.sh` or `broker/deploy.sh`, and lets other `gcloud` commands through (C10).
10. **Old broker cut off.** The cutover record lists, with dates, the deletion on GitHub of the old bot key, the old login client secret, and the step-1 `-claude` and `-agy` keys, and the fingerprints of the keys that remain. Each App's settings page shows only the new key. No identity is sent to the old URL to check it.
11. **Devices moved.** On each device, `make doctor` passes and gives no `workers.dev` warning. Doctor tests show the warning for a `*.workers.dev` URL.
12. **No Cloudflare left.** `git grep -nIiE 'cloudflare|wrangler|workers\.dev|CLOUDFLARE_' -- ':!intent/' ':!scripts/doctor.sh' ':!tests/scripts/test_doctor.sh'` finds nothing (doctor keeps the FR-9 warning; `broker/README.md` points to the cutover record without naming the old host). `deploy/targets/cloudflare-workers` doesn't exist. A bootstrap test shows `TARGET=cloudflare-workers` fails as an unknown target.
13. **Workers sandbox.** `gh repo view Jomaries777/sandbox-node-workers --json isArchived -q .isArchived` gives `true`. The record says whether `x7k2-apps` was emptied or couldn't be reached, and what is left in it.
14. **Docs and checks.** `make lint test` is green. Specs 0001–0003 have "amended by 0004" notes at each section this spec amends. 0003's `plan.md` has the Deviations row for the move.
15. **Cost.** `gcloud billing budgets list --billing-account <id>` shows the $1 budget, limited to `<P>`. After 7 idle days, the billing report for `<P>` shows $0.00, and the plan's Progress records the figure and the date.
16. **Key reads logged.** `gcloud logging read 'protoPayload.methodName:"AccessSecretVersion"' --project <P> --limit 20` gives entries, and every principal in them is `broker@<P>`.
