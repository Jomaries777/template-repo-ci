# Spec: Act as the agent bot from any device

| Field | Value |
|---|---|
| Status | **Accepted** by the product owner on 2026-11-16, with C1–C4 and C6 decided |
| Intent | [intent.md](intent.md), accepted 2026-11-16 (#19) |
| Created | 2026-11-16 |
| Owner decisions | C1–C4 and C6 decided 2026-11-16; C5 accepted with decision 2; C7 measured in the build (see [Flagged concerns](#flagged-concerns-and-policy-conflicts)) |
| Amends | [0001 spec](../0001-github-cicd-pipeline/spec.md) §4.5 and §8, as **Amendment 2** |
| Plan | No `plan.md` here. Once this spec is accepted, the build is written as **M2 step 7** in [0001's plan.md](../0001-github-cicd-pipeline/plan.md), before step 6b, and the acceptance criteria below become its Proof rows |

## Requirements

### Functional

| ID | Requirement | Intent ref |
|---|---|---|
| FR-1 | `scripts/bot-token.sh [owner/repo]` prints a bot installation token on any machine with `curl` and `jq` that has signed in once with `scripts/bot-login.sh` (macOS, Linux, Windows with Git Bash or WSL, a Codespace). It no longer needs the macOS Keychain. | Outcome 1, 2; Decision 1 |
| FR-2 | Phase 1, before the broker: inside a Codespace, `bot-token.sh` signs with the key in the Codespaces user secret `BOT_APP_KEY_B64`. Outside a Codespace it keeps the Keychain path. | Decision 2; Constraint "Mac flow keeps working" |
| FR-3 | `scripts/bot-login.sh` signs the device in once with the device flow of a **login-only GitHub App** that has no permissions (C2). It stores the resulting identity token in `~/.config/agent-bot/identity` (mode `0600`). | Decision 1; C2 |
| FR-4 | Broker `POST /token {"repo": "<name>"}` with `Authorization: Bearer <identity token>` returns `{"token", "expires_at"}` only if `GET https://api.github.com/user` with that token returns the owner's numeric ID. | Decision 1 |
| FR-5 | Each broker token is limited to the one repo asked for (`repositories: [name]`), with permissions no wider than the bot App's own (`contents`, `pull_requests`, `issues`, `checks`: write; `metadata`: read). | Decision 4 |
| FR-6 | Broker `POST /relay` (C3) creates a branch, one commit and optionally a PR **as the bot** from a file payload sent by a caller that can't push as the bot (a cloud Claude Code session). `scripts/bot-relay.sh` builds the payload from `git diff`. | Decision 3; C3 |
| FR-7 | The broker logs every request: time, GitHub user ID, endpoint, repo, branch (relay), the result (issued, refused and why), the token's expiry, and the caller's IP. It never logs a token or file contents. | Decision 4 |
| FR-8 | `scripts/bootstrap.sh` sets the `BOT_APP_PRIVATE_KEY` Actions and Dependabot secrets without a Mac (C4): phase 1 from the Codespaces secret; phase 2 through broker `POST /secrets`, so the key never touches the device. `--skip-bot-key` stays. | Outcome 4; C4 |
| FR-9 | `make doctor` checks the bot path that applies: the broker answers and issues a token for this repo; or, in a Codespace, `BOT_APP_KEY_B64` is set; or, on a Mac, the Keychain entry exists. While the broker is live, it warns if the Codespaces secret still exists. | Outcome 4 |
| FR-10 | Access is revoked in three ways: (a) for one device, by revoking its identity token; (b) for everyone, with a broker kill switch; (c) by rotating the App key, which only the broker and the repos' Actions secrets hold. | Outcome 3 |

### Non-functional

| ID | Requirement | Intent ref |
|---|---|---|
| NFR-1 | About $0 when idle. Nothing runs always-on. The broker runs on the Cloudflare Workers free plan with no paid add-ons, and stays inside its limits at the expected load (under 100 requests a day). | Constraint "Cost" |
| NFR-2 | The App private key exists only in the broker's Worker secret, the repos' `BOT_APP_PRIVATE_KEY` Actions and Dependabot secrets, and (until the broker is live) the Codespaces user secret and the Mac Keychain. It never reaches a device's disk, a log or a cloud session. | Constraint "Short-lived credentials" |
| NFR-3 | Bot tokens a device receives last at most 1 hour (GitHub's installation-token lifetime). | Constraint "Short-lived credentials" |
| NFR-4 | The bot gains no permission. The broker can't widen a token past the App's grant, and the App keeps no `workflows` and no `administration` permission. The relay refuses `.github/workflows/**` and the default branch even before GitHub would. | Constraint "No widening of the bot's power" |
| NFR-5 | The broker answers `/token` in under 3 s, and a `/relay` with 20 files in under 10 s. | Outcome 2 |
| NFR-6 | The broker is plain `fetch` and WebCrypto, with no framework; the one dependency is `libsodium-wrappers` for `/secrets`. *Amended 2026-11-17 (#33): `libsodium-wrappers` can't load its WebAssembly on Workers, so `/secrets` seals with `tweetnacl` + `@noble/hashes` (pure JS, audited), and `libsodium-wrappers` is a test-only dependency that opens every sealed value.* Its handler tests run offline in `make test` with GitHub API fixtures. | Template simplicity |

## Design

### Overview

```text
device (Mac / PC / Codespace)              cloud session (no gh, owner-only GitHub access)
  │ ~/.config/agent-bot/identity             │ identity token injected by the environment's proxy
  ▼                                          ▼
scripts/bot-token.sh ──POST /token──►   ┌─────────── broker (Cloudflare Worker) ───────────┐
scripts/bot-relay.sh ──POST /relay──►   │ 1. GET /user with the identity token == OWNER_ID? │
scripts/bootstrap.sh ──POST /secrets─►  │ 2. App JWT (key in Worker secret)                 │
                                        │ 3. /token:   1-hour token, one repo               │
                                        │    /relay:   tree + commit + ref + PR as the bot  │
                                        │    /secrets: seal key, set repo secret            │
                                        │ 4. audit row in D1 (no tokens, no contents)       │
                                        └────────────────────────────────────────────────────┘
```

### Phase 1: Codespaces secret ($0, ships first)

1. **The owner stores the key once.** In GitHub **Settings → Codespaces → Secrets**, the owner adds `BOT_APP_KEY_B64`: the base64 key, the same value as in the Keychain. Repository access is limited to the template and the projects made from it. The name can't start with `GITHUB_`.
2. **`bot-token.sh` chooses a key source, in this order:**
   1. `BOT_BROKER_URL` is set and an identity token exists: ask the broker (phase 2).
   2. `CODESPACES=true` and `BOT_APP_KEY_B64` is set: decode it into the existing `0600` temp file and sign locally.
   3. Otherwise: the macOS Keychain, as today.

   `BOT_APP_KEY_B64` outside a Codespace is ignored, so the key isn't encouraged into ordinary env files.
3. **`bootstrap.sh` in a Codespace** sets the two repo secrets from `BOT_APP_KEY_B64` (piped, never echoed).
4. **Exit:** when the broker is live, the owner deletes the Codespaces secret and rotates the App key (the key was in a second place). `make doctor` warns while the secret still exists.

### Phase 2: identity (C2, login-only App)

- **A second GitHub App, `<owner>-agent-login`.** It has **no permissions** and is installed nowhere. Device flow is on, and user-token expiry is **off**: the token can't do anything except say who the user is, and it is revoked per device instead.
- **`scripts/bot-login.sh` (once per device).** It runs the device flow (`POST https://github.com/login/device/code`, then polling `/login/oauth/access_token`) with the App's client ID, which is public. No client secret is needed on the device. *(Amended 2026-11-16, review of #25: the broker holds the login App's client secret as a Worker secret, `LOGIN_CLIENT_SECRET`, and checks each token with GitHub's "Check a token" endpoint, so only tokens this App issued are accepted, not any token of the owner's.)* It shows the code to enter at `github.com/login/device` and writes the token to `~/.config/agent-bot/identity` with mode `0600`.
- **Cloud environment.** The owner runs `bot-login.sh` once anywhere, then saves that token on the cloud environment's credential form for the broker's host. The proxy injects it as `Authorization: Bearer …` on requests to the broker. The session sends a dummy value and never sees the real one.
- **What the token can do.** The identity token unlocks bot tokens through the broker, so it is **bot-equivalent**, not harmless. It is still less than the owner's own `gh` token, which can change settings or delete repos.

### Phase 2: the broker (C1, Cloudflare Workers)

**Configuration:**
- **Worker secrets:** `APP_ID`, `APP_KEY_PKCS8` (the App key converted once with `openssl pkcs8 -topk8 -nocrypt`, because WebCrypto needs PKCS#8), `OWNER_ID`, `OWNER_LOGIN`.
- **Variable:** `BROKER_ENABLED`.
- **D1 database:** `audit`.

Every response carries `Cache-Control: no-store`. Every request body is capped: 1 KB for `/token` and `/secrets`, 2 MB for `/relay`.

**Authentication on every endpoint except `/healthz`:**
1. **Kill switch.** If `BROKER_ENABLED != "true"`, return `503 disabled`.
2. **Check the caller.** Call `GET https://api.github.com/user` with the caller's bearer token (5 s timeout). Require `id == OWNER_ID`; the numeric ID is used, not the login. Otherwise return `401` (no token) or `403 not_owner`.
3. **Rate limit.** Allow 30 `/token` and 20 `/relay` calls per hour per caller, counted in D1; otherwise `429`. This guards against a leaked identity token being used in bulk. It isn't a security boundary.
4. **Validate `repo`.** It must match `^[A-Za-z0-9._-]{1,100}$`. The owner comes from configuration, never from the request.

**Endpoints:**

| Endpoint | Body | Effect |
|---|---|---|
| `POST /token` | `{"repo"}` | JWT (`iat = now-60`, `exp = now+540`), then `GET /repos/{OWNER_LOGIN}/{repo}/installation`, then `POST /app/installations/{id}/access_tokens` with `{"repositories":[repo],"permissions":{contents:write,pull_requests:write,issues:write,checks:write,metadata:read}}`. Returns `{token, expires_at}`; `404 not_installed` if the bot isn't on the repo |
| `POST /relay` | `{"repo","branch","base","parent","message","files":[{"path","content_b64"}\|{"path","delete":true}],"pr":{"title","body","draft"}}` | See the relay rules below |
| `POST /secrets` | `{"repo","apps":["actions","dependabot"]}` | The bot App has no secrets permission, and NFR-4 forbids adding one, so this uses the **caller's** GitHub authority. `bootstrap.sh` sends the owner's `gh auth token` in `X-GitHub-Token`. With it, the broker reads the repo's public key itself (`GET …/{app}/secrets/public-key`); it never accepts a public key from the caller, which could otherwise get the App key sealed to a key of its choosing. It seals the App key (libsodium sealed box) and `PUT`s `BOT_APP_PRIVATE_KEY`. The `gh` token is used for this one call only and is never stored or logged |
| `GET /healthz` | none | `{"ok":true,"enabled":<bool>}` |

**Relay rules (C3).** These are enforced in the broker, before any GitHub call:

1. **Branch.** `branch` must match `^(feat|fix|docs|chore|test|ci)/[a-z0-9._/-]{1,80}$`. It may never be the default branch or `main`.
2. **Paths.** Every path is normalized and must not start with `.github/workflows/` or contain `..`, a leading `/`, or `.git/`. There are at most 100 files per call.
3. **New branch.** If `branch` doesn't exist, it is created from `base` (default `main`).
4. **Existing branch.** The update is fast-forward only: `parent` must equal the branch's current head, otherwise `409 stale_parent`. The branch's head commit must also be the bot's, otherwise `409 not_bot_branch`. The relay never moves someone else's branch. *Amended 2026-11-17 (live test, #29): a commit the App makes through the API has GitHub's `web-flow` as committer, so the head counts as the bot's when its author is the bot, its committer is the bot or `web-flow`, and GitHub marks it Verified. Someone with write access could imitate this; accepted while the owner is the only writer.*
5. **Commit.** `POST /git/trees` with `base_tree = parent's tree`. Text files go inline as `content`. Binary files become blobs first, at most 10 per call, which keeps the call within the free plan's 50-subrequest limit. Then `POST /git/commits`, whose author and committer are the bot. GitHub marks API commits by an App as **Verified**.
6. **Branch update.** `POST /git/refs` for a new branch, or `PATCH /git/refs/heads/{branch}` with `force: false`.
7. **PR.** If `pr` is set and no PR exists for the branch, `POST /pulls`, with `draft` defaulting to `true`.
8. **Response.** It returns `{commit, branch, pr_url}`, and the audit row records the file **paths and count**, never their contents.

Because the bot makes the commit and the push, it is the last pusher, and the owner can approve without the bypass.

**`scripts/bot-relay.sh [--pr "title"]` in a cloud session:**
1. Build the payload from `git diff --name-status --no-renames origin/<base>...HEAD` (renames are sent as a delete plus an add) and the file contents at `HEAD`.
2. `POST` it to `$BOT_BROKER_URL/relay/` (the broker also accepts `/relay`; *amended 2026-11-17, #29: a network secret limited to the path `/relay` is attached only under `/relay/`*), where the environment's proxy adds the identity token.
3. Afterwards, run `git fetch origin <branch>` and `git reset --soft origin/<branch>`, so the local branch matches the bot's commit and the next relay passes the fast-forward check.

**`bot-token.sh` with a broker:** `curl -fsS -X POST "$BOT_BROKER_URL/token" -H "Authorization: Bearer $(cat ~/.config/agent-bot/identity)" -d "{\"repo\":\"$name\"}" | jq -r .token`. The token is only sent over HTTPS, and `curl` never echoes headers.

**Why Cloudflare Workers (C1).** Free tiers were re-checked on 2026-11-16:
- **Workers Free:** 100,000 requests a day, 10 ms CPU per request; waiting on `fetch()` isn't counted ([limits][cf-limits], [pricing][cf-pricing]). No payment card, no cold start.
- **D1:** 5 GB, 5 M rows read and 100k written per day, free ([pricing][cf-pricing]).
- **The alternative.** Cloud Run would need billing on, a roughly 1 s cold start and step 6b's GCP project first ([pricing][run-pricing]).

**CPU budget.** The 10 ms limit covers JSON parsing and RS256 signing; GitHub calls are I/O. The 2 MB `/relay` cap keeps parsing within budget, and the build PR measures it. If it doesn't fit, the relay moves to the $5 Workers Paid plan only with the owner's approval, never automatically.

### Logging and revocation

- **Audit row in D1:** `{ts, caller_id, endpoint, repo, branch, files_count, paths, outcome, reason, expires_at, ip}`. Rows older than 90 days are deleted on each write, with one cheap `DELETE … WHERE ts < ?`. No request headers, tokens or file contents are stored.
- **Revoke one device or the cloud environment:** in GitHub **Settings → Applications → Authorized GitHub Apps → `<owner>-agent-login` → Revoke**. That revokes every identity token at once. For one device only, delete its file and run `bot-login.sh` again on the others. GitHub has no per-token list for App user tokens, which the C2 row records.
- **Revoke everyone:** set `BROKER_ENABLED=false` with `wrangler secret put` or in the dashboard. Bot tokens already issued expire within 1 hour.
- **Rotate the App key:** generate a new key, update the Worker secret, update each repo's `BOT_APP_PRIVATE_KEY` (with `POST /secrets` in a loop), then delete the old key in the App settings.

### Files that change

| Path | Change |
|---|---|
| `scripts/bot-token.sh` | Choose a key source (broker, Codespaces secret, Keychain); refuse `BOT_APP_KEY_B64` outside a Codespace |
| `scripts/bot-login.sh` (new) | Device-flow sign-in to the login-only App; writes `~/.config/agent-bot/identity` with mode `0600` |
| `scripts/bot-relay.sh` (new) | Build the payload from `git diff`, `POST /relay`, then resync the local branch |
| `scripts/bootstrap.sh` | Bot secrets from the Codespaces secret (phase 1) or `POST /secrets` (phase 2) |
| `scripts/doctor.sh` | FR-9 checks; SKIP for a source that doesn't apply |
| `broker/` (new) | `src/handler.js` (routing, auth, `/token`, `/relay`, `/secrets`), `src/github.js`, `src/jwt.js`, `schema.sql` (D1 `audit`, `rate`), `wrangler.toml`, `package.json` (`tweetnacl`, `@noble/hashes`; `libsodium-wrappers` for tests only, amended in #33, `wrangler` as a dev dependency), `README.md` (setup, kill switch, rotation) |
| `tests/scripts/test_bot_token.sh`, `test_bot_relay.sh` (new) | Key-source order and payload building, with fake `curl`, `security` and `git` |
| `tests/broker/` (new) | Handler tests on Node's test runner with fetch fixtures: owner accepted; other user `403`; bad repo `400`; kill switch `503`; relay refuses workflow paths, `main`, `..`, stale parent and non-bot branches; tokens and contents never in the audit row; permissions body exact |
| `Makefile` | `make test` also runs `node --test tests/broker` when `broker/` exists |
| `intent/0001-github-cicd-pipeline/spikes/m0-owner-setup.md`, `m2-step6-owner-setup.md` | New-device setup is `bot-login.sh`; the phone route uses the Codespaces secret or the broker, not `--skip-bot-key` |
| `CLAUDE.md` | "Push only as the bot" names `bot-token.sh` (any device) and `bot-relay.sh` (cloud sessions) |

### Security review (decision 5)

**`secure-change` checklist:**

| Check | Result |
|---|---|
| No secret in code, config, logs or tests | The App key lives in the Worker secret only. Tests generate a throwaway RSA key at run time. The audit row excludes tokens and contents (FR-7), and a test asserts it. |
| Untrusted input validated at the boundary | `repo`, `branch` and paths are allow-listed by pattern. The owner comes from config. Bodies are size-capped. D1 uses bound parameters. Nothing is built into shell, SQL or templates. File contents go to GitHub only as JSON strings. |
| Dependencies from a package manager | `broker/package.json` with a lockfile; `dependency-review` covers it. |
| Authn and authz on every entry point, default deny | Every endpoint except `/healthz` resolves the bearer to `OWNER_ID` or returns `401`/`403`. `/relay` adds branch and path deny-lists. |
| Workflow permissions minimal, actions pinned | No workflow change in this spec. C6 keeps deploys manual. |
| Least privilege, keyless where possible | The Cloudflare API token, used only from the owner's machine, is scoped to "Edit Workers" on one account, plus D1 for this one database. The bot App's permissions are unchanged. The login App has none. |
| Errors don't leak internals | Clients get a status and a short code (`not_owner`, `not_installed`, `disabled`, `rate_limited`, `stale_parent`, `not_bot_branch`, `path_denied`). Details go to the audit row. |

**Threat model:**

| Threat | Impact | Mitigation |
|---|---|---|
| A stolen identity token (device file or cloud credential) | Bot-equivalent: mint bot tokens and relay commits to any repo the bot is on, until revoked. It can't merge (the ruleset needs owner approval and `ci-ok`), touch workflows or change settings | `0600` file; the audit log shows every use; the rate limit; revoke the login App's authorization; the kill switch |
| A stolen bot token (1 h) | Push branches and open PRs on one repo until expiry | 1 h lifetime, one repo, ruleset, owner review |
| A compromised broker (code or Cloudflare account) | The App key leaks, plus any `gh` token passing through `/secrets` at that moment | Cloudflare account with 2FA; key rotation runbook; `/secrets` is the only path that sees a `gh` token, and it's used only during bootstrap |
| The relay as a write path | A crafted payload tries `main`, workflows or path traversal | Deny-lists in the broker; GitHub's own limits behind them (the App has no `workflows` permission; the ruleset blocks direct pushes to `main`); fast-forward only; non-bot branches refused |
| Broker abuse or denial of service | Free-plan limits reached; the broker stops (it fails closed) | Fails closed. Rate limit per caller. A free plan can't create a bill |
| Codespaces secret (phase 1) read by code in a Codespace | The App key leaks to a malicious dependency running there | Limit the secret to the owner's repos; temporary until phase 2; rotate the key when deleting it |
| Replay of a broker request | `/token` returns a fresh token to the same caller. `/relay` is refused by the parent check if replayed after the branch moved | TLS only; `no-store`; fast-forward parent check |

## Flagged concerns and policy conflicts

| # | Concern | Conflict | Decision (owner fills in) |
|---|---|---|---|
| C1 | Broker host: Cloudflare Workers or Cloud Run | Workers needs a Cloudflare account now rather than in M3; Cloud Run needs billing | **Cloudflare Workers**, free plan (owner, 2026-11-16) |
| C2 | Which token a device sends: the full `gh` token, or a login-only App token | The `gh` token would put full-power owner credentials in front of a third-party host | **Login-only App token** (owner, 2026-11-16). Consequence: revocation covers all devices at once, since GitHub can't revoke one App user token on its own; the identity token is bot-equivalent *Amended 2026-11-16 (review of #25): the broker also holds the login App's client secret, to check that a token was issued by that App.* |
| C3 | Cloud sessions can't push as the bot through their own git connection | Decision 3 wants cloud sessions in the first release | **Build the relay** (owner, 2026-11-16): `POST /relay` plus `bot-relay.sh`, with the rules above. A relayed change arrives as one commit per call, so local history isn't kept |
| C4 | How bootstrap sets the repo secrets without a Mac | `/secrets` gives the broker a write path and briefly sees a `gh` token | **Codespace secret now, broker `/secrets` in phase 2, OIDC spike later** (owner, 2026-11-16) |
| C5 | The Codespaces secret holds the full App key during phase 1 | NFR-2's "never on a device" while phase 1 lasts | Accepted (decision 2). The key is rotated when phase 1 ends |
| C6 | Deploying the broker from CI would need a Cloudflare API token as a CI secret and a workflow change | `.github/workflows/` changes go through the owner with `ALLOW_WORKFLOW_EDIT=1`; a new long-lived CI secret | **Deploy by hand** (owner, 2026-11-16): the owner runs `wrangler deploy` from a Codespace or a Mac, following `broker/README.md`. No CI secret and no workflow change; CI deploy is a later option |
| C7 | The relay's CPU on the Workers free plan (10 ms) | Large relays may exceed it | Measured in the build PR. Moving to Workers Paid ($5 a month) needs the owner's approval |

## Acceptance criteria

Each criterion is checkable by a command; together they become the Proof rows of M2 step 7 in 0001's `plan.md`. `$B` is `$BOT_BROKER_URL`, and `$ID` is `$(cat ~/.config/agent-bot/identity)`.

1. **Phase 1, Codespace:** in a Codespace with `BOT_APP_KEY_B64` set and no Keychain, `GH_TOKEN="$(scripts/bot-token.sh)" gh api /installation/repositories --jq '.repositories[].full_name'` lists the repo. A test PR opened with that token shows the bot as its author (`gh pr view N --json author`).
2. **Phase 1, scoping:** outside a Codespace, `BOT_APP_KEY_B64=… scripts/bot-token.sh` ignores the variable and uses the Keychain (`test_bot_token.sh`).
3. **Login:** `scripts/bot-login.sh` on a non-Mac machine ends with `~/.config/agent-bot/identity` at mode `600`, and `curl -s -H "Authorization: Bearer $ID" https://api.github.com/user | jq .id` prints the owner's ID.
4. **Login token has no reach:** `curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ID" https://api.github.com/repos/OWNER/sandbox-node-local/contents/README.md` on a private repo returns `404`, and a write attempt returns `403` or `404`.
5. **Broker, owner:** `curl -s -X POST $B/token -H "Authorization: Bearer $ID" -d '{"repo":"sandbox-node-local"}' | jq -r .expires_at` is about 1 h ahead, and `gh api /installation/repositories` with the returned token lists **only** `sandbox-node-local`.
6. **Broker, not the owner:** the same call with a second account's identity token returns `403 not_owner`; with no token it returns `401`; with `"repo":"../x"` it returns `400`.
7. **Relay, cloud session:** in a cloud Claude Code session with the identity credential on its environment, `scripts/bot-relay.sh --pr "test: relay"` opens a draft PR where `gh pr view N --json author,commits` shows the bot as author and committer, and the commit is Verified. The owner approves it in the GitHub UI **without** the admin bypass.
8. **Relay, refusals:** a payload with `.github/workflows/x.yml` returns `400 path_denied`; `"branch":"main"` returns `400`; a stale `parent` returns `409 stale_parent`; relaying onto a branch whose head the owner pushed returns `409 not_bot_branch`. Each is also covered by `tests/broker`.
9. **Audit:** each call in 5–8 has exactly one D1 row (`wrangler d1 execute audit --command "select endpoint,outcome from audit order by ts desc limit 10"`). A search of the export for the identity token, the bot token and a known file string finds nothing.
10. **Kill switch:** with `BROKER_ENABLED=false`, criterion 5 returns `503 disabled` within 1 minute.
11. **Bootstrap without a Mac:** `scripts/bootstrap.sh --stack node --target local` (no `--skip-bot-key`) in a Codespace ends with both `BOT_APP_PRIVATE_KEY` secrets set (`gh secret list --app actions` and `--app dependabot`), and `make doctor` reports no FAIL. This passes in phase 1 (Codespaces secret) and again in phase 2 (`/secrets`).
12. **Dependabot unblocked:** in `sandbox-node-local`, a Dependabot patch PR is approved by the bot and auto-merges, which is `0001` criterion 6.
13. **Cost:** after 30 idle days, the Cloudflare account is still on the Free plan with no invoices, and `wrangler d1 info audit` is under 5 GB.
14. **Tests:** `make test` runs `tests/broker` offline and passes; deleting any relay deny-list check makes at least one test fail.

[cf-limits]: https://developers.cloudflare.com/workers/platform/limits
[cf-pricing]: https://developers.cloudflare.com/workers/platform/pricing/
[run-pricing]: https://cloud.google.com/run/pricing
