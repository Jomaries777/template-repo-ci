# Bot token broker

A Cloudflare Worker that gives a device a **1-hour bot token for one repo** once the owner proves who they are. The bot App's private key lives only here, as a Worker secret. The design is in spec 0002 ([`intent/0002-bot-identity-any-device/spec.md`](../intent/0002-bot-identity-any-device/spec.md)). This is the template's own infrastructure: one broker serves every project, so bootstrap leaves this folder out of new projects.

```text
device: scripts/bot-login.sh (once)  → ~/.config/agent-bot/identity
device: scripts/bot-token.sh owner/repo
          → POST /token {"repo": "owner/repo"}  (Authorization: Bearer <identity>)
broker:   "Check a token" with the login App's client credentials:
          issued by that App, and its user == OWNER_ID?  → mint a token for that repo only
          → one audit row in D1 for identified callers (never a token)
```

| Endpoint | Answer |
|---|---|
| `POST /token` | `200 {token, expires_at}`, or `400 bad_repo` / `wrong_owner` (only the owner's repos) / `bad_json`, `401 no_token` / `bad_token`, `403 not_owner`, `404 not_installed`, `413 too_large`, `429 rate_limited` (30 requests an hour for the owner, 1 for anyone else), `502 github_error`, `503 disabled` / `audit_unavailable` |
| `POST /relay` | One bot commit on a `feat/ fix/ docs/ chore/ test/ ci/` branch, plus an optional draft PR: `200 {commit, branch, pr_url}`. Refusals: `400 bad_branch` / `bad_base` / `bad_parent` / `bad_message` / `bad_files` / `path_denied` (workflows, `.git`, `..`, absolute) / `bad_mode` / `bad_content` / `too_many_blobs` (10 binary files) / `bad_pr`, `409 stale_parent` (the branch or base moved) / `not_bot_branch` (its head isn't a Verified commit with the bot as author and the bot or GitHub's `web-flow` as committer; someone with write access could imitate that, which is accepted while the owner is the only writer), `413 too_large` (1 MB), `429 rate_limited` (20 an hour), plus the `/token` identity errors. A PR is opened only if the branch has no **open** one; after a PR is closed or merged, the next relay with `--pr` opens a new one |
| `POST /secrets` | Sets `BOT_APP_PRIVATE_KEY` for `{repo, apps: ["actions","dependabot"]}` with the caller's GitHub token in `X-GitHub-Token` (the bot has no secrets permission): `200 {set}`. The token must be the owner's (`403 github_token_not_owner`); the broker reads each repo public key itself and seals the key there, so the key and the token are never stored or returned. `400 bad_apps` / `no_github_token`, `401 bad_github_token`, `403 github_denied`, `429` (10 an hour), plus the identity errors. Not reachable from cloud sessions (their secret is limited to `/relay`). Use it with `scripts/bot-secrets.sh owner/repo` |
| `GET /healthz` | `{ok, enabled}` |

The identity comes from the login-only GitHub App `jomaries777-agent-login`, which has **no permissions**. Its token can only say who you are. The broker accepts only tokens that this App issued: it checks each one with GitHub's [Check a token](https://docs.github.com/en/rest/apps/oauth-applications#check-a-token) endpoint, so a `gh` CLI token, a PAT or another app's token of yours gets `401 bad_token`. Because the broker turns the identity into bot tokens, treat it like a bot credential: the file is mode `0600`, and every use is audited. Requests without a valid identity, and throttled requests, are refused without writing to the database, and another GitHub user who signs in to the login App gets one audited refusal an hour, so nobody can fill it. If the audit database is missing or can't be read, the broker refuses everything with `503 audit_unavailable` rather than issue tokens without a log or a rate limit. The App's **"Expire user authorization tokens" must stay off**; otherwise identities stop working after 8 hours.

## Deploy (by hand, spec 0002 C6)

Do this once from a **Codespace on `template-repo-ci`**, which already has the `BOT_APP_KEY_B64` Codespaces secret. It costs $0 on the Workers Free plan; no card is needed.

1. **Create a Cloudflare API token:** <https://dash.cloudflare.com/profile/api-tokens> → **Create Token** → template **Edit Cloudflare Workers** → add the permission **Account · D1 · Edit** → **Account Resources:** your account only → create it, and copy it.
2. **Load the token without echoing it:**

   ```bash
   cd broker
   read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN   # paste, then Enter
   W="npx -y wrangler@4.163.0"
   ```

3. **Create the audit database:** run `$W d1 create agent-bot-audit` and copy the printed `database_id` into `wrangler.toml` (the template's own broker already has one; a new owner replaces it). Keep `preview_urls = false`: per-version preview URLs would let an old version answer after the kill switch. If wrangler offers to add the binding itself, answer no: `wrangler.toml` already has it as `AUDIT`. Then create the table with `$W d1 execute agent-bot-audit --remote --file schema.sql`.
4. **Store the App key as a secret.** WebCrypto needs PKCS#8, so the key is converted on the way, and it is never written to disk:

   ```bash
   printf %s "$BOT_APP_KEY_B64" | base64 -d | openssl pkcs8 -topk8 -nocrypt | $W secret put APP_KEY_PKCS8
   ```

5. **Store the login App's client secret.** It's used only to check identities, and it can't be used to sign in as you. At <https://github.com/settings/apps/jomaries777-agent-login> → **Credentials** (or **General**) → **Client secrets** → **Generate a new client secret**, copy it, then run this and paste it at the prompt:

   ```bash
   $W secret put LOGIN_CLIENT_SECRET
   ```

6. **Deploy:** `npm ci --ignore-scripts && $W deploy` (wrangler bundles the two sealing libraries, `tweetnacl` and `@noble/hashes`). It prints the URL, `https://agent-bot-broker.<your-subdomain>.workers.dev`. Check it with `curl -s <url>/healthz`, which should give `{"ok":true,"enabled":true}`. The subdomain comes from your Cloudflare account and can be changed under **Workers & Pages → Account details → Subdomain**; the URL is not kept in the repo, since each device saves it when it signs in.

## Upgrade an existing broker

When a release adds audit columns, run its migration **before** deploying. If you deploy first, the broker answers every request with `503 audit_unavailable` until the migration has run, rather than answering without an audit row:

```bash
cd broker
$W d1 execute agent-bot-audit --remote --file migrations/0002_relay.sql   # step 7c: relay columns
npm ci --ignore-scripts                                                     # step 7d: sealing libraries
$W deploy
```

## Use it from any device

```bash
scripts/bot-login.sh --broker https://agent-bot-broker.<your-subdomain>.workers.dev
# open github.com/login/device, enter the code, approve jomaries777-agent-login
GH_TOKEN="$(scripts/bot-token.sh Jomaries777/sandbox-node-local)" gh pr create ...
```

## Use it from a cloud session (relay)

A cloud Claude Code session can't push as the bot, so it sends its changes to `POST /relay`, and the broker makes the commit and the draft PR as the bot. The commit is Verified, and the bot is the last pusher, so the owner can approve without the admin bypass.

1. **Give the environment the identity, once.** Add it as a network secret for the broker's host with the path prefix `/relay`, so sessions can reach only the relay, not `/token`. (`bot-relay.sh` calls `/relay/`, which the prefix matches.) In the session, Claude asks for a credential for the broker's host. Paste the identity there: in a signed-in Codespace, `cat ~/.config/agent-bot/identity` shows it (don't screenshot it). The environment's network proxy then adds `Authorization: Bearer <identity>` to every request to the broker; the session never sees the value. Saving it also allows the host.
2. **Set `BOT_BROKER_URL`** as an environment variable of the cloud environment.
3. **Relay a branch:** commit on a `feat/…` (or `fix/`, `docs/`, `chore/`, `test/`, `ci/`) branch, then run `scripts/bot-relay.sh --pr "title"`. The changes since `origin/<branch>` (or `origin/main` for a new branch) become one bot commit; the local branch is then reset onto it, so the next relay is a fast-forward.

Anyone who can start a session on that environment can act as the bot through it, so keep the environment personal. To cut it off, delete the credential in the environment's settings, or revoke the login App's authorization.

## Operate

- **Kill switch:** set `BROKER_ENABLED = "false"` in `wrangler.toml` and run `$W deploy`. Every request then gets `503 disabled`, and tokens already issued expire within an hour. The switch stops the broker only: `bot-token.sh` then falls back to a device's own key source (the Codespaces secret or the Mac Keychain), if it has one. To cut those off too, delete the Codespaces secret or rotate the App key.
- **If someone floods it:** requests with junk tokens write nothing, but each one still costs a Worker request and a "Check a token" call to GitHub. Only devices you sign in know the URL; if it leaks and the request count in **Metrics** jumps, turn the kill switch on (your devices fall back to their own keys), then redeploy under a new Worker `name` to get a new URL.
- **Sign every device out:** <https://github.com/settings/apps/authorizations> → `jomaries777-agent-login` → **Revoke**. To sign out one device, run `scripts/bot-login.sh --logout` on it.
- **Audit log:**

  ```bash
  $W d1 execute agent-bot-audit --remote --command "select datetime(ts/1000,'unixepoch') t, caller_id, repo, outcome, reason from audit order by ts desc limit 20"
  ```

  Rows older than 90 days are deleted automatically.
- **CPU time (C7):** dashboard → **Workers & Pages** → `agent-bot-broker` → **Metrics** → CPU time. It must stay under the free plan's 10 ms per request.
- **Rotate the App key** (and retire phase 1, spec 0002 C5). From a Codespace on this repo that is signed in (`scripts/bot-login.sh`), with the Cloudflare token loaded:
  1. In the bot App's settings → **Private keys** → **Generate a private key**. A `.pem` file downloads to your device; upload it to the Codespace (drag it into the file explorer) as `~/new.pem`.
  2. Put it in the broker, then delete the file: `openssl pkcs8 -topk8 -nocrypt -in ~/new.pem | $W secret put APP_KEY_PKCS8 && shred -u ~/new.pem` (or `rm`). Delete the download on your device too.
  3. Update every repo's secrets through the broker: `scripts/bot-secrets.sh Jomaries777/template-repo-ci Jomaries777/sandbox-node-local` (add each project repo). In a Codespace, its own `GITHUB_TOKEN` can't manage secrets (`github_denied`): sign `gh` in as yourself just for this with `env -u GITHUB_TOKEN gh auth login -h github.com -p https -w`, run `env -u GITHUB_TOKEN scripts/bot-secrets.sh …`, then `env -u GITHUB_TOKEN gh auth logout -h github.com`.
  4. Check: `scripts/bot-token.sh Jomaries777/sandbox-node-local >/dev/null && echo OK`, and rerun a bot workflow (for example a Dependabot PR's automerge job).
  5. In the App settings, **delete the old private key**. Delete the Codespaces secret `BOT_APP_KEY_B64` (github.com/settings/codespaces) and the Mac Keychain item if there is one; `make doctor` warns while the Codespaces secret is still there.

## Tests

`make test` runs `node --test tests/broker/*.test.mjs` offline: GitHub is a fake `fetch`, D1 is an in-memory stub, and the App key is generated at run time.
