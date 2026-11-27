# Bot token broker

A Cloudflare Worker that gives a device a **1-hour agent App token for one repo** once the owner proves who they are. The three GitHub Apps' private keys live here as Worker secrets (spec 0002 [`intent/0002-bot-identity-any-device/spec.md`](../intent/0002-bot-identity-any-device/spec.md) and spec 0003 [`intent/0003-per-agent-identity/spec.md`](../intent/0003-per-agent-identity/spec.md)). This is the template's own infrastructure: one broker serves every project, so bootstrap leaves this folder out of new projects.

```text
device: scripts/bot-login.sh (once)  → ~/.config/agent-bot/identity
device: scripts/bot-token.sh --agent claude owner/repo
          → POST /token {"repo": "owner/repo", "agent": "claude"}  (Authorization: Bearer <identity>)
broker:   "Check a token" with the login App's client credentials:
          issued by that App, and its user == OWNER_ID?  → mint a token for that agent App & repo only
          → look up <slug>[bot]'s numeric user id  → return {token, expires_at, login, id}
          → one audit row in D1 with agent set for identified callers (never a token or key)
```

| Endpoint | Answer |
|---|---|
| `POST /token` | Requires `"agent": "claude"` or `"agy"` and `"repo": "owner/name"`. Returns `200 {token, expires_at, login, id}` where `login` is `<slug>[bot]` and `id` is the bot's numeric GitHub user ID (from `GET /users/<slug>%5Bbot%5D`). Refusals: `400 bad_agent` (`"ci"`, unknown or missing) / `bad_repo` / `wrong_owner` (only the owner's repos) / `bad_json`, `401 no_token` / `bad_token`, `403 not_owner`, `404 not_installed`, `413 too_large`, `429 rate_limited` (30 requests an hour for the owner across agents, 1 for anyone else), `500 missing_key` / `misconfigured`, `502 github_error`, `503 disabled` / `audit_unavailable` |
| `POST /relay` | Always acts as the `claude` App (`CLAUDE_APP_ID` / `CLAUDE_KEY_PKCS8`). Makes one bot commit on a `feat/ fix/ docs/ chore/ test/ ci/` branch, plus an optional draft PR: `200 {commit, branch, pr_url}`. Refusals: `400 bad_branch` / `bad_base` / `bad_parent` / `bad_message` / `bad_files` / `path_denied` (workflows, `.git`, `..`, absolute) / `bad_mode` / `bad_content` / `too_many_blobs` (10 binary files) / `bad_pr`, `409 stale_parent` (the branch or base moved) / `not_bot_branch` (its head isn't a Verified commit with `<CLAUDE_APP_SLUG>[bot]` as author and `<CLAUDE_APP_SLUG>[bot]` or GitHub's `web-flow` as committer; someone with write access could imitate that, which is accepted while the owner is the only writer), `413 too_large` (1 MB), `429 rate_limited` (20 an hour), `500 missing_key` / `misconfigured`, plus the `/token` identity errors. A PR is opened only if the branch has no **open** one; after a PR is closed or merged, the next relay with `--pr` opens a new one |
| `POST /secrets` | Takes `{repo, key}` where `key` is `"claude"` or `"ci"`, with the caller's GitHub token in `X-GitHub-Token` (the Apps have no secrets permission): `200 {key, app, secret}`. Each key has one fixed target that the caller cannot override: `"claude"` writes only the Actions secret `CLAUDE_APP_PRIVATE_KEY` (`CLAUDE_KEY_PKCS8`), and `"ci"` writes only the Dependabot secret `CI_APP_PRIVATE_KEY` (`CI_KEY_PKCS8`). Only `broker/src/secrets.js` reads `CI_KEY_PKCS8`. The GitHub token must be the owner's (`403 github_token_not_owner`); the broker reads the repo public key itself and seals the key there, so the key and token are never stored or returned. Refusals: `400 bad_key` / `bad_repo` / `wrong_owner` / `no_github_token`, `401 bad_github_token`, `403 github_denied`, `404 not_found`, `429 rate_limited` (10 an hour), `500 missing_key`, `502 github_error`, plus the identity errors. Not reachable from cloud sessions (their secret is limited to `/relay`). Use it with `scripts/bot-secrets.sh owner/repo` |
| `GET /healthz` | `{ok, enabled}` |

The identity comes from the login-only GitHub App `jomaries777-agent-login`, which has **no permissions**. Its token can only say who you are. The broker accepts only tokens that this App issued: it checks each one with GitHub's [Check a token](https://docs.github.com/en/rest/apps/oauth-applications#check-a-token) endpoint, so a `gh` CLI token, a PAT or another app's token of yours gets `401 bad_token`. Because the broker turns the identity into agent tokens, treat it like a bot credential: the file is mode `0600`, and every use is audited with its `agent` (`claude` or `agy` for `/token` and `/relay`; `claude` or `ci` for `/secrets`). Requests without a valid identity, and throttled requests, are refused without writing to the database, and another GitHub user who signs in to the login App gets one audited refusal an hour, so nobody can fill it. If the audit database is missing or can't be read (or hasn't had migration `0003_agent.sql` applied), the broker refuses everything with `503 audit_unavailable` rather than issue tokens without a log or a rate limit. The App's **"Expire user authorization tokens" must stay off**; otherwise identities stop working after 8 hours.

## Configuration (vars and secrets)

`broker/wrangler.toml` holds non-secret `[vars]`:

- `OWNER_LOGIN`, `OWNER_ID`: the single GitHub owner the broker serves.
- `CLAUDE_APP_ID`, `CLAUDE_APP_SLUG`: the Claude App (`jomaries777-claude`). Used by `/token` (`agent: "claude"`) and `/relay`.
- `AGY_APP_ID`, `AGY_APP_SLUG`: the Antigravity App (`jomaries777-agy`). Used by `/token` (`agent: "agy"`).
- `CI_APP_ID`, `CI_APP_SLUG`: the CI App (`jomaries777-ci`), used for Dependabot auto-merge only.
- `LOGIN_CLIENT_ID`: the login-only App (`jomaries777-agent-login`).
- `BROKER_ENABLED`: `"true"` or `"false"` (kill switch).

App IDs in `broker/wrangler.toml` stay `"0"` until the M3 cutover creates the agent Apps.

Worker secrets (set with `wrangler secret put`, never in `wrangler.toml`):

- `CLAUDE_KEY_PKCS8`: PKCS#8 PEM private key of `<login>-claude` (used by `/token`, `/relay`, `/secrets`).
- `AGY_KEY_PKCS8`: PKCS#8 PEM private key of `<login>-agy` (used by `/token` only).
- `CI_KEY_PKCS8`: PKCS#8 PEM private key of `<login>-ci` (read only by `broker/src/secrets.js`; never reachable from `/token` or `/relay`).
- `LOGIN_CLIENT_SECRET`: client secret of the login-only App (`jomaries777-agent-login`).

## Deploy a fresh broker (by hand)

It costs $0 on the Workers Free plan; no card is needed.

1. **Create a Cloudflare API token:** <https://dash.cloudflare.com/profile/api-tokens> → **Create Token** → template **Edit Cloudflare Workers** → add the permission **Account · D1 · Edit** → **Account Resources:** your account only → create it, and copy it.
2. **Load the token without echoing it:**

   ```bash
   cd broker
   read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN   # paste, then Enter
   W="npx -y wrangler@4.163.0"
   ```

3. **Create the audit database:** run `$W d1 create agent-bot-audit` and copy the printed `database_id` into `wrangler.toml` (the template's own broker already has one; a new owner replaces it). Keep `preview_urls = false`: per-version preview URLs would let an old version answer after the kill switch. If wrangler offers to add the binding itself, answer no: `wrangler.toml` already has it as `AUDIT`. Then create the table with `$W d1 execute agent-bot-audit --remote --file schema.sql`. Because `schema.sql` already includes `0002_relay.sql` and `0003_agent.sql`, initialize `d1_migrations` and mark them applied so future `d1 migrations apply` runs don't retry them:

   ```bash
   $W d1 migrations list agent-bot-audit --remote
   $W d1 execute agent-bot-audit --remote --command "INSERT OR IGNORE INTO d1_migrations (name) VALUES ('0002_relay.sql'), ('0003_agent.sql')"
   ```
4. **Store the three App keys as Worker secrets.** WebCrypto needs PKCS#8, so convert each downloaded `.pem` on the way and delete the local file immediately:

   ```bash
   openssl pkcs8 -topk8 -nocrypt -in ~/claude.pem | $W secret put CLAUDE_KEY_PKCS8 && rm -f ~/claude.pem
   openssl pkcs8 -topk8 -nocrypt -in ~/agy.pem    | $W secret put AGY_KEY_PKCS8    && rm -f ~/agy.pem
   openssl pkcs8 -topk8 -nocrypt -in ~/ci.pem     | $W secret put CI_KEY_PKCS8     && rm -f ~/ci.pem
   ```

5. **Store the login App's client secret.** It's used only to check identities, and it can't be used to sign in as you. At <https://github.com/settings/apps/jomaries777-agent-login> → **Credentials** (or **General**) → **Client secrets** → **Generate a new client secret**, copy it, then run this and paste it at the prompt:

   ```bash
   $W secret put LOGIN_CLIENT_SECRET
   ```

6. **Fill in the App IDs and slugs** in `wrangler.toml` (`CLAUDE_APP_ID`, `AGY_APP_ID`, `CI_APP_ID`, and their slugs) and **deploy:** `npm ci --ignore-scripts && $W deploy` (wrangler bundles `tweetnacl` and `@noble/hashes`). It prints the URL, `https://agent-bot-broker.<your-subdomain>.workers.dev`. Check it with `curl -s <url>/healthz`, which should give `{"ok":true,"enabled":true}`. The subdomain comes from your Cloudflare account and can be changed under **Workers & Pages → Account details → Subdomain**; the URL is not kept in the repo, since each device saves it when it signs in.

## Migrate from one App to three (spec 0003, M3 order)

Run this in one sitting, serially, after the M1 device scripts are on `main`. This follows the `plan.md` M3 order rather than spec FR-11's order so that today's key (`APP_KEY_PKCS8`) stays usable until step 3 proves the new broker, keeping a clean rollback open. Dependabot auto-merge is down from step 5 until step 7, so run steps 5–7 back to back.

```bash
cd broker
read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN   # paste, then Enter
W="npx -y wrangler@4.163.0"
```

1. **Create the two agent Apps.** Create `jomaries777-claude` and `jomaries777-agy` from `scripts/app-manifest.sh`, generate a private key for each, and install both on `template-repo-ci`. Note their numeric App IDs.
2. **Load the three keys, apply migration `0003_agent.sql`, and deploy.** `CI_KEY_PKCS8` holds today's `jomaries777-agent-bot` key for now (so `APP_KEY_PKCS8` stays intact for rollback). Apply the migration **before** deploying so the schema check never fails closed:

   ```bash
   openssl pkcs8 -topk8 -nocrypt -in ~/claude.pem | $W secret put CLAUDE_KEY_PKCS8 && rm -f ~/claude.pem
   openssl pkcs8 -topk8 -nocrypt -in ~/agy.pem    | $W secret put AGY_KEY_PKCS8    && rm -f ~/agy.pem
   # Load today's jomaries777-agent-bot key into CI_KEY_PKCS8 for now (use the
   # command for your machine; convert first so an error never uploads an empty secret):
   # On macOS (Keychain):
   pem="$(security find-generic-password -s github-app-private-key -w | openssl pkcs8 -topk8 -nocrypt)" && test -n "$pem" && printf '%s\n' "$pem" | $W secret put CI_KEY_PKCS8; unset pem
   # Or in a Codespace (BOT_APP_KEY_B64):
   pem="$(test -n "$BOT_APP_KEY_B64" && printf %s "$BOT_APP_KEY_B64" | base64 -d | openssl pkcs8 -topk8 -nocrypt)" && test -n "$pem" && printf '%s\n' "$pem" | $W secret put CI_KEY_PKCS8; unset pem
   ```

   Check pending migrations first. On the existing database, `0002_relay.sql` was previously run with `d1 execute` (not `d1 migrations apply`), so if `d1 migrations list` shows `0002_relay.sql` as pending, mark it applied in `d1_migrations` before running `d1 migrations apply` so `0002_relay.sql` doesn't fail with `duplicate column name: branch`:

   ```bash
   $W d1 migrations list agent-bot-audit --remote
   # Only if 0002_relay.sql is listed as pending (its columns already exist):
   $W d1 execute agent-bot-audit --remote --command "INSERT OR IGNORE INTO d1_migrations (name) VALUES ('0002_relay.sql')"
   $W d1 migrations apply agent-bot-audit --remote
   # Verify migration 0003_agent.sql is listed as applied (no pending migrations):
   $W d1 migrations list agent-bot-audit --remote
   ```

   On a local branch, replace the `"0"` placeholder IDs in `broker/wrangler.toml` with the real `CLAUDE_APP_ID`, `AGY_APP_ID`, and `CI_APP_ID` (`5766032`), then deploy:

   ```bash
   npm ci --ignore-scripts && $W deploy
   ```

3. **Prove the new broker (checkpoint).** Open that local branch as a PR through the new broker (`GH_TOKEN="$(scripts/bot-token.sh --agent claude Jomaries777/template-repo-ci)" ...`). Confirm its author is `app/jomaries777-claude`.
   - **Rollback (if step 3 fails):** deploy the pre-0003 broker from `b065bb8`, which still has `APP_ID`/`APP_SLUG` and reads `APP_KEY_PKCS8`:

     ```bash
     git worktree add /tmp/broker-old b065bb8
     (cd /tmp/broker-old/broker && npm ci --ignore-scripts && $W deploy)
     git worktree remove /tmp/broker-old
     ```

4. **Rename the old App to `-ci` and cut its permissions.** In GitHub App settings, rename `jomaries777-agent-bot` to `jomaries777-ci` and reduce its repository permissions to `contents: write`, `pull_requests: write`, and `metadata: read`.
5. **Rotate the `-ci` key.** Generate a new private key on `jomaries777-ci`, load it into `CI_KEY_PKCS8`, and delete the old private key on GitHub:

   ```bash
   openssl pkcs8 -topk8 -nocrypt -in ~/ci-new.pem | $W secret put CI_KEY_PKCS8 && rm -f ~/ci-new.pem
   ```

6. **Push the repo secrets and variables.** Run `scripts/bot-secrets.sh Jomaries777/template-repo-ci` (writes Actions `CLAUDE_APP_PRIVATE_KEY` and Dependabot `CI_APP_PRIVATE_KEY`), and set the repo variables `CLAUDE_APP_ID`, `CLAUDE_APP_SLUG`, and `CI_APP_ID`.
7. **Merge the M2 workflows PR** so CI and Dependabot auto-merge switch to `CLAUDE_APP_*` and `CI_APP_*`.
8. **Apply the split rulesets:** run `scripts/gh-settings.sh` to apply `main` and `main-review`.
9. **Delete old copies and retire sandboxes.** Delete `BOT_APP_ID` and `BOT_APP_PRIVATE_KEY` on `template-repo-ci`, delete the Mac Keychain entry `github-app-private-key`, and delete the Codespaces secret `BOT_APP_KEY_B64`. On retired sandboxes, delete their `BOT_APP_*` secrets/variables and remove them from the `-ci` App installation.
10. **Verify:** run `make doctor` in `template-repo-ci` and confirm it passes.
11. **Delete the old Worker secret:** once step 5 has deleted the old key on GitHub, `APP_KEY_PKCS8` can no longer serve as a rollback, so remove it:

    ```bash
    $W secret delete APP_KEY_PKCS8
    ```

## Upgrade an existing broker

When a release adds audit columns, run its migration **before** deploying. If you deploy first, the broker answers every request with `503 audit_unavailable` until the migration has run, rather than answering without an audit row:

```bash
cd broker
$W d1 migrations apply agent-bot-audit --remote   # applies any pending migration, e.g. 0003_agent.sql
npm ci --ignore-scripts                           # sealing libraries
$W deploy
```

## Use it from any device

```bash
scripts/bot-login.sh --broker https://agent-bot-broker.<your-subdomain>.workers.dev
# open github.com/login/device, enter the code, approve jomaries777-agent-login
GH_TOKEN="$(scripts/bot-token.sh --agent claude Jomaries777/template-repo-ci)" gh pr create ...
```

## Use it from a cloud session (relay)

A cloud Claude Code session can't push directly, so it sends its changes to `POST /relay`, and the broker makes the commit and the draft PR as the Claude App (`jomaries777-claude`). The commit is Verified, and the App is the last pusher, so the owner can approve without the admin bypass.

1. **Give the environment the identity, once.** Add it as a network secret for the broker's host with the path prefix `/relay`, so sessions can reach only the relay, not `/token` or `/secrets`. (`bot-relay.sh` calls `/relay/`, which the prefix matches.) In the session, Claude asks for a credential for the broker's host. Paste the identity there: in a signed-in device, `cat ~/.config/agent-bot/identity` shows it (don't screenshot it). The environment's network proxy then adds `Authorization: Bearer <identity>` to every request to the broker; the session never sees the value. Saving it also allows the host.
2. **Set `BOT_BROKER_URL`** as an environment variable of the cloud environment.
3. **Relay a branch:** commit on a `feat/…` (or `fix/`, `docs/`, `chore/`, `test/`, `ci/`) branch, then run `scripts/bot-relay.sh --pr "title"`. The changes since `origin/<branch>` (or `origin/main` for a new branch) become one Claude App commit; the local branch is then reset onto it, so the next relay is a fast-forward.

Anyone who can start a session on that environment can act as the Claude App through it, so keep the environment personal. To cut it off, delete the credential in the environment's settings, or revoke the login App's authorization.

## Operate

- **Kill switch:** set `BROKER_ENABLED = "false"` in `wrangler.toml` and run `$W deploy`. Every request then gets `503 disabled`, and tokens already issued expire within an hour. Devices hold no local App keys (spec 0003 D6), so agents cannot mint tokens while the switch is on.
- **If someone floods it:** requests with junk tokens write nothing, but each one still costs a Worker request and a "Check a token" call to GitHub. Only devices you sign in know the URL; if it leaks and the request count in **Metrics** jumps, turn the kill switch on, then redeploy under a new Worker `name` to get a new URL.
- **Sign every device out:** <https://github.com/settings/apps/authorizations> → `jomaries777-agent-login` → **Revoke**. To sign out one device, run `scripts/bot-login.sh --logout` on it.
- **Audit log:**

  ```bash
  $W d1 execute agent-bot-audit --remote --command "select datetime(ts/1000,'unixepoch') t, caller_id, endpoint, agent, repo, outcome, reason from audit order by ts desc limit 20"
  ```

  Rows older than 90 days are deleted automatically.
- **CPU time (C7):** dashboard → **Workers & Pages** → `agent-bot-broker` → **Metrics** → CPU time. It must stay under the free plan's 10 ms per request.
- **Rotate an App key.** From a signed-in device (`scripts/bot-login.sh`) with the Cloudflare token loaded:
  1. In that App's settings → **Private keys** → **Generate a private key**. A `.pem` file downloads to your device as `~/new.pem`.
  2. Put it in the broker under its secret (`CLAUDE_KEY_PKCS8`, `AGY_KEY_PKCS8`, or `CI_KEY_PKCS8`), then delete the file: `openssl pkcs8 -topk8 -nocrypt -in ~/new.pem | $W secret put <SECRET_NAME> && rm -f ~/new.pem`.
  3. If rotating `claude` or `ci`, update every repo's secret through the broker: `scripts/bot-secrets.sh --key claude Jomaries777/template-repo-ci` or `scripts/bot-secrets.sh --key ci Jomaries777/template-repo-ci` (`agy` has no repo secret). In a Codespace, its own `GITHUB_TOKEN` can't manage secrets (`github_denied`): sign `gh` in as yourself just for this with `env -u GITHUB_TOKEN gh auth login -h github.com -p https -w`, run `env -u GITHUB_TOKEN scripts/bot-secrets.sh …`, then `env -u GITHUB_TOKEN gh auth logout -h github.com`.
  4. Check: for `claude` or `agy`, `scripts/bot-token.sh --agent <agent> Jomaries777/template-repo-ci >/dev/null && echo OK`; for `ci`, rerun a Dependabot automerge job.
  5. In the App settings, **delete the old private key**.

## Tests

`make test` runs `node --test tests/broker/*.test.mjs` offline: GitHub is a fake `fetch`, D1 is an in-memory stub, and the three App keys are generated at run time.
