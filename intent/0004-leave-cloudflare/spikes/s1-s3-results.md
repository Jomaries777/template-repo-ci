# Spikes S1–S3: results

| Field | Value |
|---|---|
| Plan | [plan.md](../plan.md) M0 |
| Run | 2026-11-28, by Claude Code on the owner's Mac |
| Project | `agent-bot-spike-test` (number 305792762631), throwaway, billing linked. Every command passed `--project agent-bot-spike-test` |
| Region | `us-west1` |
| Values | Dummy header values only (`dummy-123`, `dummy-456`). No real token, key or identity was sent |

## Summary for the M0 gate

| Gate item | Result | Decides |
|---|---|---|
| S1 IP rule | Google's front end **appends** the client address as the **last** `X-Forwarded-For` entry. Entries the client sends come before it, unchanged | `handler.js` takes the last comma-separated entry, trimmed |
| S1 headers | `Authorization: Bearer <non-Google token>` and `X-GitHub-Token` reach the container unchanged on a public (`allUsers`) service | No change to the HTTP contract (FR-2) |
| S1 cold start | 1.86 s, 1.93 s and 1.96 s on the first request after idle (warm: 0.21 s) | Accepted by the owner on 2026-11-28 (item 3). Well under the shortest `--max-time` (10 s, `doctor.sh`) |
| S2 error | A query whose index is missing answers **HTTP 400** with `"status": "FAILED_PRECONDITION"`, inside a JSON array | The store throws on any non-2xx answer, and on any array entry with `error`; `identify` gives `503 audit_unavailable` |
| S2 count | Right count; **1 read** | `countLastHour` as specified |
| S2 prune | `expire_at < now`, `limit 50`, then one `commit` of deletes removed exactly the expired documents; 1 read per document returned | `prune` as specified |
| S3 build | `--build-service-account builder@` with only `roles/run.builder` builds and deploys, with Editor removed from the default compute account | `setup.sh` and `deploy.sh` as specified (C2) |
| S3 free tier | Default pool, no machine type set (so the default `e2-standard-2`); 23 s build; source bucket in `US-WEST1`; container scanning off | Build minutes and the upload bucket are free. Image size: a `node:22-alpine` `Dockerfile` (owner, item 1) |

**For the owner:**

1. **Image size.** The buildpacks image of a trivial Node server is 145,871,130 bytes (139 MiB). Keeping the 2 newest images (NFR-1) holds about 278 MiB of the 0.5 GiB Artifact Registry free tier, which is shared by every project on the billing account (M2 step 2 measures the others). The broker's image will be about the same, since its dependencies are small. **Decided by the owner on 2026-11-28: a `node:22-alpine` `Dockerfile`.** Measured below (S3, "Dockerfile build"): 58.5 MiB, so 2 kept images hold about 117 MiB.
2. **Budget.** No budget is scoped to `agent-bot-spike-test`; only the account-wide "Free Tier Alert" ($1) covers it. M0 asked for a $1 budget on the spike project. The spike was short and its cost is recorded below.
3. **Cold start at the edge.** 1.86–1.96 s for a trivial server, and the broker loads a little more. Every script's timeout is 10 s or more, so nothing fails. The plan's gate sends anything over about 2 s back to the owner, so it went to the owner. **Accepted by the owner on 2026-11-28.**

## S1: headers, caller IP and cold start

An echo service (Node 22, `node:http`, 12 lines) answered each request with its method, URL, headers, socket address and uptime. Deployed with:

```sh
gcloud run deploy echo --source . --project agent-bot-spike-test --region us-west1 \
  --service-account runtime@agent-bot-spike-test.iam.gserviceaccount.com \
  --build-service-account projects/agent-bot-spike-test/serviceAccounts/builder@agent-bot-spike-test.iam.gserviceaccount.com \
  --allow-unauthenticated --max-instances 1 --quiet
```

`runtime@` has no role. The service got `maxScale=1` and `startup-cpu-boost=true` (a default).

**Headers.** The client's public address in these runs was an IPv6 address, written `<client>` below.

| Request | `authorization` | `x-github-token` | `x-forwarded-for` received |
|---|---|---|---|
| A: no client `X-Forwarded-For` | `Bearer dummy-123` | `dummy-456` | `<client>` |
| B: client sends `1.2.3.4` | `Bearer dummy-123` | – | `1.2.3.4,<client>` |
| C: client sends `1.2.3.4, 5.6.7.8` | – | – | `1.2.3.4, 5.6.7.8,<client>` |

The socket address is always `169.254.169.126` (Google's front end), so it can't serve as the caller IP. The headers the container sees are `accept`, `forwarded`, `host`, `traceparent`, `user-agent`, `x-cloud-trace-context`, `x-forwarded-for`, `x-forwarded-proto`, plus whatever the client sent. **Rule:** `row.ip` is the last entry of `X-Forwarded-For`, trimmed. The entries before it are the client's own and are ignored.

**Cold start** (`curl -w '%{time_total}'` on `/`, after the idle time shown):

| Try | When (UTC) | Idle before | `time_total` | `ttfb` | Instance uptime at answer |
|---|---|---|---|---|---|
| 1 | 09:50:46 | about 70 min | 1.863 s | 1.855 s | 88 ms |
| 2 | 10:31:49 | about 41 min | 1.931 s | 1.922 s | 20 ms |
| 3 | 10:49:07 | 17 min | 1.962 s | 1.953 s | 55 ms |
| warm | 09:50:48 | – | 0.211 s | 0.211 s | – |

An uptime of under 100 ms confirms each cold try started a new instance. Two background timers built on a long `sleep` produced nothing (the Mac slept), so tries 1 and 2 were taken by hand after longer idle times, and try 3 by a loop that checked the clock every 20 s. The broker's own start adds module loading for `tweetnacl` and `@noble/hashes`, a few tens of milliseconds.

## S2: Firestore count, missing index and prune

`(default)` database, Firestore Native, `us-west1`. Calls went to the REST API with `curl`, using the owner's access token, which was never printed. `ts` and `expire_at` are integer milliseconds, as `ts` is in today's D1 rows.

Seeded 9 documents in `audit`: caller 1 `token` ×5 in the last hour and ×2 older; caller 1 `relay` ×1; caller 2 `token` ×1. Three of them have `expire_at` in the past.

| Step | Result |
|---|---|
| `runAggregationQuery` count on (`caller_id` = 1, `endpoint` = `token`, `ts` ≥ now − 1 h), **before** the composite index | HTTP 400, `[{"error":{"code":400,"message":"The query requires an index. You can create it here: …","status":"FAILED_PRECONDITION"}}]` |
| Composite index `audit` (`caller_id`, `endpoint`, `ts`), `gcloud firestore indexes composite create` | `READY` |
| The same count, with `explainOptions.analyze` | `5`. `readOperations` 1; 5 index entries scanned, 0 documents |
| Count for caller 2 `token`; caller 1 `relay` | `1`; `1` |
| `runQuery` on `expire_at` < now, `limit 50`, with `explainOptions.analyze` | 3 documents (the 3 expired). `readOperations` 3 |
| One `commit` with 3 `delete` writes | HTTP 200 |
| Count of all documents; `expire_at` < now again | `6`; `0` |
| A count on fields the index doesn't cover (`caller_id`, `outcome`, `ts`) | HTTP 400 `FAILED_PRECONDITION` again |

The single-field query on `expire_at` uses Firestore's automatic single-field index, so it needs no composite index. **Cost per `/token`:** 1 read (the count) and 1 write (the insert). Each prune costs 1 read and 1 delete per expired document, at most 50 each, all within the free 50,000 reads and 20,000 deletes a day.

## S3: build identity

| Check | Result |
|---|---|
| Default compute account before | `roles/editor` (C2 confirmed) |
| After `remove-iam-policy-binding … --role roles/editor` | No `roles/editor` binding in the project |
| `builder@` | `roles/run.builder` only, at the project |
| `gcloud run deploy --source … --build-service-account builder@` | Built and deployed (`echo-00001-cxq`), 66 s end to end |
| Build (`gcloud builds describe`) | `serviceAccount` `builder@`; `status` `SUCCESS`; `options.pool` empty and no `machineType`, so the default pool and machine type; build step 23 s |
| Source bucket | `run-sources-agent-bot-spike-test-us-west1`, location `US-WEST1` |
| Artifact Registry | `cloud-run-source-deploy` in `us-west1`; the image is 145,871,130 bytes |
| `containerscanning.googleapis.com` | Not enabled |

### Dockerfile build (after the gate decision)

The echo service was rebuilt from this `Dockerfile`, with the same `builder@` and `runtime@`:

```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY package.json server.js ./
USER node
CMD ["node", "server.js"]
```

| Check | Result |
|---|---|
| First deploy without `--clear-base-image` | Refused: `Missing required argument [--clear-base-image]: Base image is not supported for services built from Dockerfile`. The buildpacks deploy had set a managed base image on the service. `deploy.sh` passes `--clear-base-image` (harmless on a service that has none) |
| Deploy with `--clear-base-image` | `echo-00002-ggg`, revision ready in 7.6 s, built as `builder@` |
| Image size | 61,376,109 bytes (58.5 MiB), against 145,871,130 (139 MiB) from buildpacks |

The legacy Cloud Build account `305792762631@cloudbuild.gserviceaccount.com` keeps `roles/cloudbuild.builds.builder` in a new project. It didn't run this build. `setup.sh` should check that it can't read the secrets: secrets grant access per secret, so it can't unless someone grants it.

## Deletion

Pending. The project still holds the `echo` service, its image, the source bucket, the Firestore database with 6 test documents, and the `builder@` and `runtime@` accounts. It is deleted after the owner has read this record, and the deletion date and the project's billing figure are added here.
