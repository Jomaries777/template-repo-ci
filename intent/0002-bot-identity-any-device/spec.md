# Spec: Act as the agent bot from any device

| Field | Value |
|---|---|
| Status | Draft |
| Intent | [intent.md](intent.md), accepted 2026-11-16 (#19) |
| Created | 2026-11-16 |
| Owner choices still open | C1 broker host, C2 identity token, C3 cloud sessions, C4 bootstrap secrets (see [Flagged concerns](#flagged-concerns-and-policy-conflicts)) |

## Requirements

### Functional

| ID | Requirement | Intent ref |
|---|---|---|
| FR-1 | `scripts/bot-token.sh [owner/repo]` prints a bot installation token on any machine with a working `gh` login (macOS, Linux, Windows with Git Bash or WSL, a Codespace). It no longer needs the macOS Keychain. | Outcome 1, 2; Decision 1 |
| FR-2 | Phase 1, before the broker: inside a Codespace, `bot-token.sh` signs with the key in the Codespaces user secret `BOT_APP_KEY_B64`. Outside a Codespace it keeps the Keychain path. | Decision 2; Constraint "Mac flow keeps working" |
| FR-3 | Phase 2, the broker: `POST /token {"repo": "<name>"}` with `Authorization: Bearer <GitHub token>` returns `{"token", "expires_at"}` only if `GET https://api.github.com/user` with that token returns the owner's numeric ID. | Decision 1 |
| FR-4 | Each broker token is limited to the one repo asked for (`repositories: [name]`), with permissions no wider than the bot App's own (`contents`, `pull_requests`, `issues`, `checks`: write; `metadata`: read). | Decision 4 |
| FR-5 | The broker logs every request: time, GitHub user ID, repo, the result (issued, refused and why), the token's expiry, and the caller's IP. It never logs either token. | Decision 4 |
| FR-6 | `scripts/bootstrap.sh` sets the `BOT_APP_PRIVATE_KEY` Actions and Dependabot secrets on a new repo without a Mac and without the key passing through the device (see C4). `--skip-bot-key` stays. | Outcome 4 |
| FR-7 | `make doctor` checks the bot path that applies: the broker answers and issues a token for this repo; or, in a Codespace, `BOT_APP_KEY_B64` is set; or, on a Mac, the Keychain entry exists. | Outcome 4 |
| FR-8 | Cloud Claude Code sessions act as the bot (decision 3). How depends on the outcome of C3. | Decision 3 |
| FR-9 | Access is revoked in three ways: (a) for one device, by revoking that device's GitHub token; (b) for everyone, with a broker kill switch that refuses every request; (c) by rotating the App key, which only the broker and the repos' Actions secrets hold. | Outcome 3 |

### Non-functional

| ID | Requirement | Intent ref |
|---|---|---|
| NFR-1 | About $0 when idle. Nothing runs always-on. The broker scales to zero and stays inside a free tier at the expected load (under 100 requests a day). | Constraint "Cost" |
| NFR-2 | The App private key exists only in the broker's secret store, the repos' `BOT_APP_PRIVATE_KEY` Actions and Dependabot secrets, and (until the broker is live) the Codespaces user secret and the Mac Keychain. It never reaches a device's disk, a log or a cloud session. | Constraint "Short-lived credentials" |
| NFR-3 | Tokens a device receives last at most 1 hour (GitHub's installation-token lifetime). | Constraint "Short-lived credentials" |
| NFR-4 | The bot gains no permission. The broker can't widen a token past the App's grant, and the App keeps no `workflows` and no `administration` permission. | Constraint "No widening of the bot's power" |
| NFR-5 | The broker answers in under 3 s, including a cold start. | Outcome 2 |
| NFR-6 | The broker is about 150 lines, with no framework. Its tests run offline in `make test` with fixtures for the GitHub API. | Constraint "Artifact loop" (template simplicity) |

## Design

### Overview

```text
device (Mac / PC / Codespace / cloud session)
  │  gh auth token  ─────────────────────────────┐
  ▼                                              │ Bearer
scripts/bot-token.sh ──POST /token {repo}──► broker ──GET /user──► api.github.com   (is it the owner?)
                                              │   ──JWT──► /repos/{o}/{r}/installation
                                              │   ──JWT──► /app/installations/{id}/access_tokens {repositories:[r], permissions}
  ◄── {token, expires_at} ────────────────────┘   └─ audit log line (no tokens)
```

The App key never leaves the broker. The device holds only its own GitHub login, which it already had, and a 1-hour bot token.

### Phase 1: Codespaces secret ($0, ships first)

1. **The owner stores the key once.** In GitHub **Settings → Codespaces → Secrets**, the owner adds `BOT_APP_KEY_B64`: the base64 key, the same value as in the Keychain. Repository access is limited to the template and the projects made from it. The name can't start with `GITHUB_`, so it isn't `GITHUB_APP_*`.
2. **`bot-token.sh` chooses a key source, in this order:**
   1. `BOT_BROKER_URL` is set: ask the broker (phase 2).
   2. `CODESPACES=true` and `BOT_APP_KEY_B64` is set: decode it into the existing `0600` temp file and sign locally.
   3. Otherwise: the macOS Keychain, as today.

   No other source is read. `BOT_APP_KEY_B64` outside a Codespace is ignored, so the key isn't encouraged into ordinary env files.
3. **`bootstrap.sh` in a Codespace** sets the two repo secrets from `BOT_APP_KEY_B64` (piped, never echoed). That closes FR-6 for phase 1.
4. **Exit:** when the broker is live, the owner deletes the Codespaces secret. `make doctor` warns while it still exists.

### Phase 2: the broker

**API.** HTTPS JSON. Every response carries `Cache-Control: no-store`.

| Request | Auth | Effect |
|---|---|---|
| `POST /token` `{"repo":"name"}` | `Bearer <GitHub token>` | Returns a 1-hour token for `OWNER/name`; `403` if the token isn't the owner's; `404` if the bot isn't installed on the repo |
| `POST /secrets` `{"repo":"name","apps":["actions","dependabot"]}` | `Bearer <GitHub token>` with secrets write on the repo (the owner's `gh` token) | The broker seals the key with the repo's public key and sets `BOT_APP_PRIVATE_KEY`, using the caller's token. Only if C4 picks option (a) |
| `GET /healthz` | none | `{"ok":true,"enabled":<kill switch>}` |

**`POST /token` steps:**
1. **Kill switch.** If `BROKER_ENABLED` isn't `true`, return `503`.
2. **Validate `repo`.** It must match `^[A-Za-z0-9._-]{1,100}$`. The owner is fixed by configuration (`OWNER_LOGIN`, `OWNER_ID`), never taken from the request, so a token for another account's repo can't be minted.
3. **Check the caller.** Call `GET https://api.github.com/user` with the caller's token, with a 5 s timeout. Require `id == OWNER_ID`; the numeric ID is used, not the login, which can be renamed. Any other answer returns `403`, with no detail.
4. **Sign the App JWT** in memory: RS256, `iat = now-60`, `exp = now+540`, `iss = APP_ID`.
5. **Mint the token.** Look up `GET /repos/{OWNER_LOGIN}/{repo}/installation`, then call `POST /app/installations/{id}/access_tokens` with `{"repositories":["repo"],"permissions":{"contents":"write","pull_requests":"write","issues":"write","checks":"write","metadata":"read"}}`. GitHub refuses permissions beyond the App's grant and repos outside its installation, so the broker can't widen access even if it is misconfigured.
6. **Log and return.** Write the audit line (FR-5), then return `{token, expires_at}`.
7. **Rate limit.** At most 30 tokens per hour per caller ID, then `429`. This is a guard against a leaked owner token being used to mint bot tokens in bulk. It isn't a security boundary.

**`bot-token.sh` with a broker:** `curl -fsS -X POST "$BOT_BROKER_URL/token" -H "Authorization: Bearer $(gh auth token)" -d "{\"repo\":\"$name\"}" | jq -r .token`. The token is only sent over HTTPS, and `curl` never echoes headers.

### Broker host: Cloudflare Workers (A) or Cloud Run (B)

Free tiers were re-checked on 2026-11-16. The Cloud Run and Secret Manager allowances differ between Google's own pages, so the build PR checks the official pricing page again.

| | **A. Cloudflare Workers** | **B. Cloud Run + Secret Manager** |
|---|---|---|
| Free allowance | 100,000 requests a day, 10 ms CPU per request; time waiting on `fetch()` is not counted ([limits][cf-limits], [pricing][cf-pricing]) | 2 M requests a month, plus vCPU-s and GiB-s allowances (180k or 240k vCPU-s, depending on the page) ([pricing][run-pricing]) |
| Payment card | Not needed for the free plan | Billing account required |
| Key storage | Worker secret (encrypted, write-only once set) | Secret Manager: 6 active versions and 10k accesses a month free ([guide][gcp-free]); the key is read once per container start |
| Audit log | Workers Logs has short retention, so the durable log goes in D1: free tier 5 GB, 5 M rows read and 100k written per day ([D1][cf-pricing]) | Cloud Logging, 50 GiB a month free, 30-day default retention |
| Cold start | None (isolates) | About 0.5 to 1.5 s, inside NFR-5 |
| RS256 signing | WebCrypto `RSASSA-PKCS1-v1_5`. It needs the key in PKCS#8, so `openssl pkcs8 -topk8 -nocrypt` runs once; the App key is PKCS#1 | Node `crypto` reads PKCS#1 directly |
| Sealing secrets (C4 option a) | libsodium sealed box through a WASM build (`libsodium-wrappers`); adds about 200 KB, within the free script-size limit | `libsodium-wrappers` in Node |
| Deploy and auth | `wrangler deploy` with a Cloudflare API token (a new secret in the template's CI if CI deploys it) | `gcloud run deploy` with WIF, which the template already has for M2 step 6b |
| Fit | M3 already plans a Cloudflare account (the `cloudflare-workers` adapter) | Shares step 6b's GCP project; one cloud |
| Lock-in | Low: about 150 lines of standard `fetch` and WebCrypto | Low: a container |

**Recommendation: A.** It meets NFR-1 with no card, has no cold start, and its free limits are about 1,000 times the expected load. Choose B if the owner would rather have one cloud and builds step 6b first. Either way the broker code is shared: a single `handler(request, env)` with a small runtime adapter.

### Cloud sessions (decision 3)

A cloud session has no `gh` login. It proves it's the owner with one credential stored on its cloud environment through the environment's secure form. The network proxy adds that credential as the `Authorization` header on requests to the broker's host, so the session never sees it. The credential is a **fine-grained GitHub token of the owner's with no repository access and the shortest expiry the owner accepts**. It can call `GET /user`, which is all the broker needs, and nothing else. Revoking it in GitHub settings cuts every cloud session off at once.

**Problem: using the bot token.** A cloud session reaches GitHub only through its session git proxy and the GitHub MCP tools, and both act as the owner. In this environment it can't call `api.github.com` or push over HTTPS with another token. So a bot token alone doesn't make its PRs come from the bot. Under the ruleset's last-push approval rule, the account that pushed last can't approve, so the push itself must come from the bot. See C3.

### Logging and revocation

- **Log line (JSON):** `{ts, caller_id, caller_login, repo, outcome, reason, expires_at, ip}`. Retention is 90 days in D1 (A) or 30 days in Cloud Logging (B). The broker never writes request headers or response bodies.
- **Revoke one device:** revoke its GitHub token. For `gh`, that's GitHub **Settings → Applications → Authorized OAuth Apps → GitHub CLI**, or `gh auth logout` on the device. For the cloud credential, delete the fine-grained token.
- **Revoke everyone:** set `BROKER_ENABLED=false` (FR-9b). Tokens already issued still expire within 1 hour.
- **Rotate the key:** generate a new App key, update the broker secret and each repo's `BOT_APP_PRIVATE_KEY` (with `POST /secrets` in a loop, or `bootstrap.sh --only-secrets`), then delete the old key in the App settings.

### Files that change

| Path | Change |
|---|---|
| `scripts/bot-token.sh` | Choose a key source (broker, Codespaces secret, Keychain); refuse `BOT_APP_KEY_B64` outside a Codespace |
| `scripts/bootstrap.sh` | Set the bot secrets from the Codespaces secret (phase 1) or through `POST /secrets` (phase 2, C4a); warn if a Codespaces secret remains after the broker is live |
| `scripts/doctor.sh` | FR-7 checks; SKIP for a source that doesn't apply |
| `broker/` (new) | `handler.js`, `runtime-cloudflare.js` or `runtime-cloudrun.js` (per C1), `wrangler.toml` or `Dockerfile`, `README.md` (setup, kill switch, rotation) |
| `tests/scripts/test_bot_token.sh` (new) | Key-source order with fake `gh`, `curl` and `security` |
| `tests/broker/` (new) | `handler` tests against fixtures: owner accepted; other user `403`; bad repo `400`; kill switch `503`; token never in logs; permissions body exact |
| `intent/0001-github-cicd-pipeline/spikes/m0-owner-setup.md`, `m2-step6-owner-setup.md` | The phone route uses the Codespaces secret, not `--skip-bot-key` |
| `CLAUDE.md` | "Push only as the bot" names the broker; the Keychain line moves to "Mac fallback" |

### Security review (decision 5)

**`secure-change` checklist:**

| Check | Result |
|---|---|
| No secret in code, config, logs or tests | The key lives in a secret store only. Tests use a key generated at test time. The audit log excludes both tokens (FR-5), and a test asserts it. |
| Untrusted input validated at the boundary | `repo` is allow-listed by pattern. The owner comes from config, not the request. The JSON body is size-capped (1 KB). Nothing is built into shell, SQL or templates; D1 uses bound parameters. |
| Dependencies from a package manager | Phase 2 adds `libsodium-wrappers` only if C4a is chosen, otherwise none. |
| Authn and authz on every entry point, default deny | `/token` and `/secrets` need a GitHub token resolving to `OWNER_ID`; anything else is `403`. `/healthz` reveals only the kill-switch state. |
| Workflow permissions minimal, actions pinned | No workflow changes unless the broker deploys from CI, which would then be an owner PR with `ALLOW_WORKFLOW_EDIT=1`, a pinned `wrangler` action and `permissions: contents: read`. |
| Least-privilege IAM, keyless where possible | B: the broker's service account gets only `secretmanager.secretAccessor` on the one secret; it is deployed with WIF. A: a Cloudflare API token scoped to one Worker. |
| Errors don't leak internals | Clients get only a status and a short code (`not_owner`, `not_installed`, `disabled`, `rate_limited`). Details go to the log. |

**Threat model:**

| Threat | Impact | Mitigation |
|---|---|---|
| A stolen owner GitHub token | The thief can already act as the owner, which is more than the bot. The broker adds nothing an attacker didn't have | Rate limit and audit log show abuse; revoke the token; C2 option (b) narrows this further |
| A stolen bot token (1 h) | Push branches and open PRs on one repo until expiry; it can't merge (the ruleset needs owner approval and `ci-ok`) and can't touch workflows | 1 h lifetime, one repo per token, ruleset, owner review |
| A compromised broker (code or host account) | The App key leaks, and so do owner GitHub tokens in transit (C2) | Key rotation runbook; host account 2FA; C2(b) removes owner tokens from the broker's view; the kill switch |
| Broker abuse or denial of service | Requests pile up; free-tier exhaustion stops the broker (it fails closed) | Fails closed, not open. Rate limit per caller. A free-plan Worker stops at its limit with no bill |
| Codespaces secret (phase 1) read by code in a Codespace | The App key leaks to a malicious dependency running there | Limit the secret to the owner's repos; it is temporary until the broker; rotate the key after deleting the secret |
| Replay of a broker request | None useful: the reply is a new token for the same caller | TLS only; `Cache-Control: no-store` |

## Flagged concerns and policy conflicts

| # | Concern | Conflict | Decision (owner fills in) |
|---|---|---|---|
| C1 | **Broker host: A (Cloudflare Workers) or B (Cloud Run).** A is recommended; the table above has the detail. | B needs billing on (constraint: ask before anything billable); A needs a new Cloudflare account now rather than in M3 | |
| C2 | **Which GitHub token does a device send?** (a) The existing `gh auth token`: zero setup, but the broker sees a token that can do anything the owner can. (b) A login through a small extra GitHub App with **no permissions**: devices sign in once with its device flow (like `gh auth login`), and the token can only say who the owner is. A compromised broker then learns nothing useful. **(b) recommended**, at a one-time setup cost. | (a) puts full-power owner tokens in front of a third-party host; that conflicts with "short-lived, least-privilege credentials" | |
| C3 | **Cloud sessions acting as the bot (decision 3) may not be possible in this environment.** The session pushes and opens PRs only through its git proxy and the GitHub MCP, as the owner. Options: (a) a spike tests whether the environment can push to `github.com` with a bot token when its network settings allow it; (b) the broker gains a relay endpoint that takes a patch and creates the commit and PR as the bot through GitHub's Git Data API (about 100 more lines, a larger attack surface); (c) cloud sessions stay as the owner for now. That is today's accepted Deviation, and decision 3 moves to a later phase. **Recommend: run spike (a) first; fall back to (c).** | Conflicts with decision 3 ("from the broker's first release") if the spike fails | |
| C4 | **How bootstrap sets the repo secrets without a Mac.** (a) The broker seals and sets them (`POST /secrets`): the key never touches a device, but the broker gains a write path. (b) Phase 1 only: bootstrap reads the Codespaces secret. (c) Later: workflows get bot tokens from the broker through GitHub Actions OIDC, so repos need no key at all. It's unclear whether Dependabot-triggered runs may request an OIDC token, so this needs a spike. **Recommend (b) now, (a) with the broker, (c) as a follow-up spike.** | (a) adds a second broker endpoint; (c) is unproven for Dependabot | |
| C5 | **The Codespaces secret holds the full App key (phase 1).** | Conflicts with NFR-2's "never on a device" while phase 1 lasts; the owner accepted this in decision 2 | Accepted (decision 2) |
| C6 | **Broker deploy from CI** would need a new CI secret (Cloudflare token) or WIF (B), plus a workflow change. | `.github/workflows/` changes go through the owner with `ALLOW_WORKFLOW_EDIT=1` | |

## Acceptance criteria

Each criterion is checkable by a command; together they become `plan.md` "Proof".

1. **Phase 1, Codespace:** in a Codespace with `BOT_APP_KEY_B64` set and no Keychain, `GH_TOKEN="$(scripts/bot-token.sh)" gh api /installation/repositories --jq '.repositories[].full_name'` lists the repo, and a test PR opened with that token shows the bot as its author (`gh pr view N --json author`).
2. **Phase 1, scoping:** outside a Codespace, `BOT_APP_KEY_B64=… scripts/bot-token.sh` ignores the variable and uses the Keychain (`test_bot_token.sh`).
3. **Broker, owner:** `curl -s -X POST $BOT_BROKER_URL/token -H "Authorization: Bearer $(gh auth token)" -d '{"repo":"sandbox-node-local"}' | jq -r .expires_at` is about 1 h ahead. `gh api /installation/repositories` with the returned token lists **only** `sandbox-node-local`.
4. **Broker, not the owner:** the same call with a second account's token returns `403` and `{"error":"not_owner"}`. With no token it returns `401`.
5. **Broker, permissions:** with the token, `gh api -X PUT repos/OWNER/sandbox-node-local/contents/.github/workflows/x.yml …` fails (no `workflows` permission). A repo where the bot isn't installed returns `404 not_installed`.
6. **Audit log:** each call in 3–5 has exactly one log line with `caller_id`, `repo`, `outcome`; `grep` for both tokens in the log export finds nothing.
7. **Kill switch:** with `BROKER_ENABLED=false`, criterion 3 returns `503 disabled` within 1 minute of the change.
8. **Any device:** criterion 3 succeeds from a non-Mac machine (a Codespace or a Linux box) with only `gh` and `curl`.
9. **Bootstrap without a Mac:** `scripts/bootstrap.sh --stack node --target local` (no `--skip-bot-key`) in a Codespace ends with both `BOT_APP_PRIVATE_KEY` secrets set (`gh secret list --app actions` and `--app dependabot`), and `make doctor` reports no FAIL.
10. **Dependabot unblocked:** in `sandbox-node-local`, a Dependabot patch PR is approved by the bot and auto-merges, which is `0001` criterion 6.
11. **Cost:** after 30 idle days, the host's billing page shows $0 (A: no paid plan; B: $0.00 on the project).
12. **Cloud sessions (decision 3):** if C3's spike passes, a cloud session's PR shows the bot as author and the owner approves it without the bypass. If not, the 0001 Deviation stays and this criterion moves to a later phase.

[cf-limits]: https://developers.cloudflare.com/workers/platform/limits
[cf-pricing]: https://developers.cloudflare.com/workers/platform/pricing/
[run-pricing]: https://cloud.google.com/run/pricing
[gcp-free]: https://agentdeals.dev/gcp-free-tier-2026
