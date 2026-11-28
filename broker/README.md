# Bot token broker

A Cloud Run service that gives a device a **1-hour agent App token for one repo** once the owner proves who they are. The three GitHub Apps' private keys live in Secret Manager in the broker's own GCP project (spec 0002 [`intent/0002-bot-identity-any-device/spec.md`](../intent/0002-bot-identity-any-device/spec.md), spec 0003 [`intent/0003-per-agent-identity/spec.md`](../intent/0003-per-agent-identity/spec.md), and spec 0004 in `intent/0004-*/`, which moved it to Cloud Run). This is the template's own infrastructure: one broker serves every project, so bootstrap leaves this folder out of new projects.

```text
device:  scripts/bot-login.sh (once)  → ~/.config/agent-bot/identity
device:  scripts/bot-token.sh --agent claude owner/repo
           → POST https://agent-bot-broker-<number>.us-west1.run.app/token
             {"repo": "owner/repo", "agent": "claude"}  (Authorization: Bearer <identity>)
Cloud Run (project agent-bot-broker-<suffix>, service account broker@)
  src/server.js  Node 22 HTTP server → Request → handle() → Response
  env:   config.yaml + BROKER_ENABLED + 4 secrets from Secret Manager (pinned versions)
  audit: Firestore (default) / audit, over REST, token from the metadata server
GitHub:  "Check a token" (login App) → App JWT → installation token for that agent App and repo only
         → {token, expires_at, login, id}; one audit document per identified call (never a token or key)
```

| Endpoint | Answer |
|---|---|
| `POST /token` | Requires `"agent": "claude"` or `"agy"` and `"repo": "owner/name"`. Returns `200 {token, expires_at, login, id}` where `login` is `<slug>[bot]` and `id` is the bot's numeric GitHub user ID (from `GET /users/<slug>%5Bbot%5D`). Refusals: `400 bad_agent` (`"ci"`, unknown or missing) / `bad_repo` / `wrong_owner` (only the owner's repos) / `bad_json`, `401 no_token` / `bad_token`, `403 not_owner`, `404 not_installed`, `413 too_large`, `429 rate_limited` (30 requests an hour for the owner across agents, 1 for anyone else), `500 missing_key` / `misconfigured`, `502 github_error`, `503 disabled` / `audit_unavailable` |
| `POST /relay` | Always acts as the `claude` App (`CLAUDE_APP_ID` / `CLAUDE_KEY_PKCS8`). Makes one bot commit on a `feat/ fix/ docs/ chore/ test/ ci/` branch, plus an optional draft PR: `200 {commit, branch, pr_url}`. Refusals: `400 bad_branch` / `bad_base` / `bad_parent` / `bad_message` / `bad_files` / `path_denied` (workflows, `.git`, `..`, absolute) / `bad_mode` / `bad_content` / `too_many_blobs` (10 binary files) / `bad_pr`, `409 stale_parent` (the branch or base moved) / `not_bot_branch` (its head isn't a Verified commit with `<CLAUDE_APP_SLUG>[bot]` as author and `<CLAUDE_APP_SLUG>[bot]` or GitHub's `web-flow` as committer; someone with write access could imitate that, which is accepted while the owner is the only writer), `413 too_large` (1 MB), `429 rate_limited` (20 an hour), `500 missing_key` / `misconfigured`, plus the `/token` identity errors. A PR is opened only if the branch has no **open** one; after a PR is closed or merged, the next relay with `--pr` opens a new one |
| `POST /secrets` | Takes `{repo, key}` where `key` is `"claude"` or `"ci"`, with the caller's GitHub token in `X-GitHub-Token` (the Apps have no secrets permission): `200 {key, app, secret}`. Each key has one fixed target that the caller cannot override: `"claude"` writes only the Actions secret `CLAUDE_APP_PRIVATE_KEY` (`CLAUDE_KEY_PKCS8`), and `"ci"` writes only the Dependabot secret `CI_APP_PRIVATE_KEY` (`CI_KEY_PKCS8`). Only `broker/src/secrets.js` reads `CI_KEY_PKCS8`. The GitHub token must be the owner's (`403 github_token_not_owner`); the broker reads the repo public key itself and seals the key there, so the key and token are never stored or returned. Refusals: `400 bad_key` / `bad_repo` / `wrong_owner` / `no_github_token`, `401 bad_github_token`, `403 github_denied`, `404 not_found`, `429 rate_limited` (10 an hour), `500 missing_key`, `502 github_error`, plus the identity errors. Not reachable from cloud sessions (their secret is limited to `/relay`). Use it with `scripts/bot-secrets.sh owner/repo` |
| `GET /healthz` | `{ok, enabled}` |

The identity comes from the login-only GitHub App `jomaries777-agent-login`, which has **no permissions**. Its token can only say who you are. The broker accepts only tokens that this App issued: it checks each one with GitHub's [Check a token](https://docs.github.com/en/rest/apps/oauth-applications#check-a-token) endpoint, so a `gh` CLI token, a PAT or another app's token of yours gets `401 bad_token`. Because the broker turns the identity into agent tokens, treat it like a bot credential: the file is mode `0600`, and every use is audited with its `agent` (`claude` or `agy` for `/token` and `/relay`; `claude` or `ci` for `/secrets`). Requests without a valid identity, and throttled requests, are refused without writing to the database, and another GitHub user who signs in to the login App gets one audited refusal an hour, so nobody can fill it. If Firestore can't be reached, or the audit index is missing, the broker refuses everything with `503 audit_unavailable` rather than issue tokens without a log or a rate limit. The App's **"Expire user authorization tokens" must stay off**; otherwise identities stop working after 8 hours.

The service is public (`allUsers` may invoke it), because callers prove who they are with the login App's token, not a Google one (spec 0004 C1). The caller IP in the audit is the **last** `X-Forwarded-For` entry, the one Google's front end adds; earlier entries are written by the client and ignored (spike S1, in `intent/0004-*/spikes/s1-s3-results.md`).

## Who runs what

Only the owner runs the three scripts below, with their own `gcloud` login, in their own terminal. They are never run from CI or by an agent: `scripts/hooks/no-secrets.sh` blocks Claude from running them, from `gcloud secrets versions access`, and from any `gcloud`, `gsutil` or `bq` command that names `agent-bot-broker`. An agent that needs a broker-project fact asks the owner to run the command and paste the output. Every script passes `--project` on every `gcloud` call, refuses a project without the label `purpose=agent-bot-broker`, and has a `DRY_RUN=1` mode that prints its commands without running them.

| Script | Does |
|---|---|
| `broker/setup.sh` | One-time, idempotent project setup (below). Refuses a project with a workload identity pool, user-managed service account keys or another Cloud Run service |
| `broker/put-secret.sh <secret> <file>` | Converts a key to PKCS#8, refuses empty or non-PEM input, adds a secret version on stdin, deletes the file, prints the version number. `--prune <secret>` destroys every version but the deployed one |
| `broker/deploy.sh` | Builds from `broker/` (the `Dockerfile`, `node:22-alpine`) as `builder@` and deploys, pinning the newest enabled version of each secret and keeping the live `BROKER_ENABLED`. `--disable` / `--enable` flip the kill switch without a rebuild. Ends by checking `/healthz` and that there are no traffic tags |

`BROKER_PROJECT` names the project, and `BROKER_REGION` overrides the default region `us-west1`. In the examples, `export BROKER_PROJECT=agent-bot-broker-<suffix>` first.

## Configuration

`broker/config.yaml` holds the non-secret values, passed to the service as environment variables:

- `OWNER_LOGIN`, `OWNER_ID`: the single GitHub owner the broker serves.
- `CLAUDE_APP_ID`, `CLAUDE_APP_SLUG`: the Claude App (`jomaries777-claude`). Used by `/token` (`agent: "claude"`) and `/relay`.
- `AGY_APP_ID`, `AGY_APP_SLUG`: the Antigravity App (`jomaries777-agy`). Used by `/token` (`agent: "agy"`).
- `CI_APP_ID`, `CI_APP_SLUG`: the CI App (`jomaries777-ci`), used for Dependabot auto-merge only.
- `LOGIN_CLIENT_ID`: the login-only App (`jomaries777-agent-login`).

`BROKER_ENABLED` (`"true"` or `"false"`, the kill switch) isn't in the file: it lives on the service, and `deploy.sh` keeps the live value.

Secrets, in Secret Manager, each readable only by `broker@`, and each reaching the service at a pinned version number (never `latest`):

| Secret | Variable | Holds |
|---|---|---|
| `claude-key` | `CLAUDE_KEY_PKCS8` | PKCS#8 PEM private key of `jomaries777-claude` (`/token`, `/relay`, `/secrets`) |
| `agy-key` | `AGY_KEY_PKCS8` | PKCS#8 PEM private key of `jomaries777-agy` (`/token` only) |
| `ci-key` | `CI_KEY_PKCS8` | PKCS#8 PEM private key of `jomaries777-ci` (read only by `broker/src/secrets.js`) |
| `login-client-secret` | `LOGIN_CLIENT_SECRET` | Client secret of `jomaries777-agent-login` |

## Set up a broker project

The broker needs a GCP billing account (spec 0004 C7). An idle broker costs $0: it scales to zero, and it stays inside the free tiers, which are per billing account, so other projects on the same account count too (plan Context). A $1 budget on the project alerts at 50%, 90% and 100%.

1. **Second step on the Google account.** It must be a passkey or an authenticator app, not email codes, with the backup codes kept offline (NFR-3).
2. **Check the billing account's free tiers.** List its projects with their active Secret Manager versions and Artifact Registry storage. With the broker added, the total must stay at most 6 active versions and well under 0.5 GiB.
3. **Create the project** with the label, and link billing. Never reuse a project that a deploy target uses (any repo's `GCP_PROJECT_ID`):

   ```bash
   gcloud projects create "$BROKER_PROJECT" --labels purpose=agent-bot-broker
   gcloud billing projects link "$BROKER_PROJECT" --billing-account <id> --project "$BROKER_PROJECT"
   ```

4. **Run setup**, first as a dry run to read what it will do:

   ```bash
   DRY_RUN=1 broker/setup.sh
   broker/setup.sh
   ```

   It enables the APIs; creates `broker@` (runtime) and `builder@` (builds, `roles/run.builder` only); removes Editor from the default compute account (C2); creates the four secrets empty and gives `broker@` `secretAccessor` on each, not on the project; gives `broker@` `roles/datastore.user`; creates the `(default)` Firestore database (Native, `us-west1`) and its index on `audit` (`caller_id`, `endpoint`, `ts`); creates the `cloud-run-source-deploy` repository with a policy that keeps the 2 newest images; turns on data-access logs for Secret Manager; and creates the budget. There's no TTL policy (TTL deletes have no free quota): the broker deletes expired audit documents itself. A database made with `gcloud` refuses unauthenticated clients by default, so there are no Firebase rules to set.

## Load the keys and deploy

1. **Keys.** On each App's settings page → **Private keys** → **Generate a private key**. Then load each one; the file is deleted once it's stored:

   ```bash
   broker/put-secret.sh claude-key ~/Downloads/jomaries777-claude.<date>.private-key.pem
   broker/put-secret.sh agy-key    ~/Downloads/jomaries777-agy.<date>.private-key.pem
   broker/put-secret.sh ci-key     ~/Downloads/jomaries777-ci.<date>.private-key.pem
   ```

2. **Login client secret.** At <https://github.com/settings/apps/jomaries777-agent-login> → **Client secrets** → **Generate a new client secret**. Save it to a file without echoing it, then load it:

   ```bash
   (umask 077; pbpaste | tr -d '[:space:]' > ~/login-secret.txt)
   broker/put-secret.sh login-client-secret ~/login-secret.txt
   ```

3. **Deploy**, and check it:

   ```bash
   broker/deploy.sh                      # prints the URL; /healthz must give {"ok":true,"enabled":true}
   curl -s https://agent-bot-broker-<number>.us-west1.run.app/healthz
   ```

   The first deploy takes a few minutes (Cloud Build). A first request after the service has been idle takes about 2 s (spike S1); the scripts' timeouts are 10 s or more.

## Cutover (0004 M2, with 0003 M3)

The move from the old broker follows plan 0004 M2 (`intent/0004-*/plan.md`), in one sitting, serially, and is recorded in `intent/0003-per-agent-identity/spikes/cutover.md`. In short: project and setup; new keys for `-claude` and `-agy` and a new login client secret (the step-1 keys are deleted on GitHub then); `ci-key` is today's bot key; deploy; a checkpoint PR through the new URL whose author must be `app/jomaries777-claude`; the kill-switch check; then every device signs in again (below) and 0003 M3's remaining steps run. Until the checkpoint passes, a device can unset `BOT_BROKER_URL` and keep using its old URL.

## Use it from any device

```bash
scripts/bot-login.sh --broker https://agent-bot-broker-<number>.us-west1.run.app
# open github.com/login/device, enter the code, approve jomaries777-agent-login
GH_TOKEN="$(scripts/bot-token.sh --agent claude Jomaries777/template-repo-ci)" gh pr create ...
```

`make doctor` warns if a device's broker URL is still on the old host.

## Use it from a cloud session (relay)

A cloud Claude Code session can't push directly, so it sends its changes to `POST /relay`, and the broker makes the commit and the draft PR as the Claude App (`jomaries777-claude`). The commit is Verified, and the App is the last pusher, so the owner can approve without the admin bypass.

1. **Give the environment the identity, once.** Add it as a network secret for the broker's host with the path prefix `/relay`, so sessions can reach only the relay, not `/token` or `/secrets`. (`bot-relay.sh` calls `/relay/`, which the prefix matches.) In the session, Claude asks for a credential for the broker's host. Paste the identity there: in a signed-in device, `cat ~/.config/agent-bot/identity` shows it (don't screenshot it). The environment's network proxy then adds `Authorization: Bearer <identity>` to every request to the broker; the session never sees the value. Saving it also allows the host.
2. **Set `BOT_BROKER_URL`** as an environment variable of the cloud environment.
3. **Relay a branch:** commit on a `feat/…` (or `fix/`, `docs/`, `chore/`, `test/`, `ci/`) branch, then run `scripts/bot-relay.sh --pr "title"`. The changes since `origin/<branch>` (or `origin/main` for a new branch) become one Claude App commit; the local branch is then reset onto it, so the next relay is a fast-forward.

Anyone who can start a session on that environment can act as the Claude App through it, so keep the environment personal. To cut it off, delete the credential in the environment's settings, or revoke the login App's authorization.

## Operate

- **Kill switch:** `broker/deploy.sh --disable`. It makes a new revision with `BROKER_ENABLED=false`, without a rebuild, and every request then gets `503 disabled`; tokens already issued expire within an hour. Devices hold no local App keys (spec 0003 D6), so agents cannot mint tokens while the switch is on. `broker/deploy.sh --enable` turns it off. A plain `deploy.sh` never turns a disabled broker back on.
- **Emergency stop:** remove `allUsers` from the service's invoker role, and Google refuses every request before it reaches the broker. Refused requests aren't billed:

  ```bash
  gcloud run services remove-iam-policy-binding agent-bot-broker --member allUsers --role roles/run.invoker \
    --region us-west1 --project "$BROKER_PROJECT"
  ```

- **If someone floods it:** requests with junk tokens write nothing, but each one costs a request and a "Check a token" call to GitHub. The service has at most 1 instance, which caps the cost; the budget alert warns. Turn the kill switch on, or use the emergency stop.
- **Sign every device out:** <https://github.com/settings/apps/authorizations> → `jomaries777-agent-login` → **Revoke**. To sign out one device, run `scripts/bot-login.sh --logout` on it.
- **Audit log:** in the console, **Firestore → Data → `audit`**, ordered by `ts` descending. Each document has `ts`, `caller_id`, `endpoint`, `agent`, `repo`, `outcome`, `reason`, `expires_at`, `ip`, `branch`, `files`, `paths` and `expire_at` (`ts` + 90 days). On about 1 write in 50, the broker deletes up to 50 documents whose `expire_at` has passed. From a terminal, a count of the last hour's calls:

  ```bash
  curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" -H 'Content-Type: application/json' \
    "https://firestore.googleapis.com/v1/projects/$BROKER_PROJECT/databases/(default)/documents:runQuery" \
    -d "{\"structuredQuery\":{\"from\":[{\"collectionId\":\"audit\"}],\"where\":{\"fieldFilter\":{\"field\":{\"fieldPath\":\"ts\"},\"op\":\"GREATER_THAN\",\"value\":{\"integerValue\":\"$((($(date +%s) - 3600) * 1000))\"}}},\"limit\":20}}"
  ```

- **Key reads:** every read of a secret is logged with who read it, and the only reader should be `broker@`:

  ```bash
  gcloud logging read 'protoPayload.methodName:"AccessSecretVersion"' --project "$BROKER_PROJECT" --limit 20
  ```

- **Rotate an App key.**
  1. In that App's settings → **Private keys** → **Generate a private key**.
  2. `broker/put-secret.sh <secret> <file>`, then `broker/deploy.sh`, which pins the new version. Until the next step, the previous version is the rollback: `gcloud secrets versions disable <new> --secret <secret> --project "$BROKER_PROJECT"`, then `broker/deploy.sh`.
  3. If rotating `claude` or `ci`, update every repo's secret through the broker: `scripts/bot-secrets.sh --key claude Jomaries777/template-repo-ci` or `scripts/bot-secrets.sh --key ci Jomaries777/template-repo-ci` (`agy` has no repo secret). In a Codespace, its own `GITHUB_TOKEN` can't manage secrets (`github_denied`): sign `gh` in as yourself just for this with `env -u GITHUB_TOKEN gh auth login -h github.com -p https -w`, run `env -u GITHUB_TOKEN scripts/bot-secrets.sh …`, then `env -u GITHUB_TOKEN gh auth logout -h github.com`.
  4. Check: for `claude` or `agy`, `scripts/bot-token.sh --agent <agent> Jomaries777/template-repo-ci >/dev/null && echo OK`; for `ci`, rerun a Dependabot automerge job.
  5. `broker/put-secret.sh --prune <secret>`, so one version stays active (free tier), and in the App settings **delete the old private key**.
- **Rotate the login client secret:** generate a new one, `broker/put-secret.sh login-client-secret <file>`, `broker/deploy.sh`, then delete the old secret on GitHub and prune.

## Tests

`make test` runs `node --test tests/broker/*.test.mjs` offline: GitHub, Firestore and the metadata server are fakes, and the three App keys are generated at run time. `tests/scripts/test_broker_setup.sh`, `test_broker_put_secret.sh` and `test_broker_deploy.sh` run the owner scripts with `DRY_RUN=1` against failing `gcloud` and `curl` stubs.
