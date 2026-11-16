# Bot token broker

A Cloudflare Worker that gives a device a **1-hour bot token for one repo** once the owner proves who they are. The bot App's private key lives only here, as a Worker secret. The design is in spec 0002 ([`intent/0002-bot-identity-any-device/spec.md`](../intent/0002-bot-identity-any-device/spec.md)). This is the template's own infrastructure: one broker serves every project, so bootstrap leaves this folder out of new projects.

```text
device: scripts/bot-login.sh (once)  → ~/.config/agent-bot/identity
device: scripts/bot-token.sh owner/repo
          → POST /token {"repo": "repo"}  (Authorization: Bearer <identity>)
broker:   GET api.github.com/user == OWNER_ID?  → mint a token for that repo only
          → one audit row in D1 (never a token)
```

| Endpoint | Answer |
|---|---|
| `POST /token` | `200 {token, expires_at}`, or `400 bad_repo` / `bad_json`, `401 no_token` / `bad_token`, `403 not_owner`, `404 not_installed`, `413 too_large`, `429 rate_limited` (30 an hour), `502 github_error`, `503 disabled` |
| `GET /healthz` | `{ok, enabled}` |

The identity comes from the login-only GitHub App `jomaries777-agent-login`, which has **no permissions**. Its token can only say who you are. Because the broker turns it into bot tokens, treat it like a bot credential: the file is mode `0600`, and every use is audited.

## Deploy (by hand, spec 0002 C6)

Do this once from a **Codespace on `template-repo-ci`**, which already has the `BOT_APP_KEY_B64` Codespaces secret. It costs $0 on the Workers Free plan; no card is needed.

1. **Create a Cloudflare API token:** <https://dash.cloudflare.com/profile/api-tokens> → **Create Token** → template **Edit Cloudflare Workers** → add the permission **Account · D1 · Edit** → **Account Resources:** your account only → create it, and copy it.
2. **Load the token without echoing it:**

   ```bash
   cd broker
   read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN   # paste, then Enter
   W="npx -y wrangler@4.163.0"
   ```

3. **Create the audit database:** run `$W d1 create agent-bot-audit` and copy the printed `database_id` into `wrangler.toml`, replacing `SET_AT_SETUP`. Then create the table with `$W d1 execute agent-bot-audit --remote --file schema.sql`.
4. **Store the App key as a secret.** WebCrypto needs PKCS#8, so the key is converted on the way, and it is never written to disk:

   ```bash
   printf %s "$BOT_APP_KEY_B64" | base64 -d | openssl pkcs8 -topk8 -nocrypt | $W secret put APP_KEY_PKCS8
   ```

5. **Deploy:** `$W deploy`. It prints the URL, `https://agent-bot-broker.<your-subdomain>.workers.dev`. Check it with `curl -s <url>/healthz`, which should give `{"ok":true,"enabled":true}`.

## Use it from any device

```bash
scripts/bot-login.sh --broker https://agent-bot-broker.<your-subdomain>.workers.dev
# open github.com/login/device, enter the code, approve jomaries777-agent-login
GH_TOKEN="$(scripts/bot-token.sh Jomaries777/sandbox-node-local)" gh pr create ...
```

## Operate

- **Kill switch:** set `BROKER_ENABLED = "false"` in `wrangler.toml` and run `$W deploy`. Every request then gets `503 disabled`, and tokens already issued expire within an hour.
- **Sign every device out:** <https://github.com/settings/apps/authorizations> → `jomaries777-agent-login` → **Revoke**. To sign out one device, run `scripts/bot-login.sh --logout` on it.
- **Audit log:**

  ```bash
  $W d1 execute agent-bot-audit --remote --command "select datetime(ts/1000,'unixepoch') t, caller_id, repo, outcome, reason from audit order by ts desc limit 20"
  ```

  Rows older than 90 days are deleted automatically.
- **CPU time (C7):** dashboard → **Workers & Pages** → `agent-bot-broker` → **Metrics** → CPU time. It must stay under the free plan's 10 ms per request.
- **Rotate the App key:**
  1. Generate a new key in the bot App's **Credentials**.
  2. Put it in the broker with `base64 -d < new.pem.b64 | openssl pkcs8 -topk8 -nocrypt | $W secret put APP_KEY_PKCS8`.
  3. Update the repos' `BOT_APP_PRIVATE_KEY` secrets and the Codespaces secret.
  4. Delete the old key in the App.

## Tests

`make test` runs `node --test tests/broker/*.test.mjs` offline: GitHub is a fake `fetch`, D1 is an in-memory stub, and the App key is generated at run time.
