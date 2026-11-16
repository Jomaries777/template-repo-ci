# M2 step 6: owner setup on the Mac (one time)

Step 6 is split (plan.md Deviations):

- **6a, now (no cloud account):** the sandbox E2E runs with the test-only `local` target. Each version runs as a Docker container on the GitHub Actions runner. This proves the real `deploy.yml` and `release.sh`, the automatic revert, the failure issue, docs-only PRs and Dependabot auto-merge, at $0. Use the short checklist right below.
- **6b, later:** the deploy and revert parts again on Cloud Run, the default target. This proves the parts only Google Cloud can show: keyless sign-in, IAM, the image registry and its cleanup, the budget and cold starts. Use the full checklist from section 0 on.

## Step 6a: the short route (about 5 minutes, no Google)

1. **Tools:** `gh`, `jq` and `git`, logged in to `gh`. The bot key must be in the Keychain; check it as in [section 0](#0-before-you-start). Keep the Claude token from `claude setup-token` ready for the hidden prompt.
2. **Sandbox repo:**

   ```bash
   gh repo create sandbox-node-local --template Jomaries777/template-repo-ci --public --clone
   cd sandbox-node-local
   ```

3. **Bootstrap** with the `local` target. No GCP variables are needed:

   ```bash
   export BOT_APP_ID="$(gh variable get BOT_APP_ID --repo Jomaries777/template-repo-ci)"
   make bootstrap STACK=node TARGET=local
   ```

4. **Install the bot App** on `sandbox-node-local`, as in [section 4](#4-install-the-bot-app-on-the-sandbox-repo).
5. **Run `make doctor`** until it ends with `doctor: all checks passed`.
6. **Hand over:** start a cloud session with `Jomaries777/sandbox-node-local` attached and say "run step 6a". From there, Claude:
   - deploys a code change through dev to production. You approve production with one tap in the GitHub app.
   - merges a version that degrades a few seconds after launch, and checks that the live checks revert it automatically, and that the revert is confirmed, in under 2 minutes
   - checks a docs-only PR skips the review and the deploy
   - checks a Dependabot patch PR auto-merges and a minor one waits

**Expect one approval right after bootstrap.** Bootstrap's push to `main` starts a deploy that passes dev, then waits for you to approve production. Approve it (or reject it). Deploys run one at a time, so while it waits, every later deploy queues behind it.

Nothing to tear down: no cloud resources are created. Delete the sandbox repo when done.

### Step 6a from a phone (Android or iPhone, no Mac)

The bot key lives in your Mac Keychain. **Once, from a Mac**, also store it as a GitHub Codespaces secret (M2 step 7a). From then on, any Codespace you open, phone included, can set a repo's bot secrets and act as the bot.

0. **Once, on a Mac: add the Codespaces secret.**
   1. Copy the key: `security find-generic-password -s github-app-private-key -w | pbcopy`.
   2. Go to <https://github.com/settings/codespaces> → **Codespaces secrets** → **New secret**. Name it `BOT_APP_KEY_B64`, paste the value, and give it access to `template-repo-ci`.
   3. Each new sandbox repo must be added to the secret's repository access, which is step 2 below.

   Without the secret, use `--skip-bot-key` in step 5 and add the key later from a Mac (step 9).
1. **Create the repo:** in the GitHub app or browser, on the template's page, tap **Use this template** → **Create a new repository**. Name it `sandbox-node-local` and make it **Public**.
2. **Give the secret access to it:** <https://github.com/settings/codespaces> → `BOT_APP_KEY_B64` → **Update** → add `sandbox-node-local`. Do this before opening the Codespace, because secrets load when it starts; an open Codespace needs a restart.
3. **Open a Codespace:** on the new repo, tap **Code** → **Codespaces** → **Create codespace on main**, using the browser's desktop-site mode if the button is hidden. It gives a Linux terminal with `git`, `make` and `jq`.
4. **Log in as yourself.** The Codespace's built-in token can't change repo settings:

   ```bash
   unset GITHUB_TOKEN GH_TOKEN
   gh auth login        # GitHub.com → HTTPS → "Login with a web browser"; open the code link on the phone
   ```

5. **Bootstrap.** Paste the Claude token (from `claude setup-token`) at the hidden prompt. Bootstrap reads the bot key from `BOT_APP_KEY_B64` and sets both bot secrets:

   ```bash
   export BOT_APP_ID="$(gh variable get BOT_APP_ID --repo Jomaries777/template-repo-ci)"
   scripts/bootstrap.sh --stack node --target local
   ```

   Without the Codespaces secret, add `--skip-bot-key`.
6. **Install the bot App** on the repo: <https://github.com/settings/installations> → **jomaries777-agent-bot** → **Configure**. On the same page, check that the **Claude** App can reach the repo too (**All repositories**, or add it), so a cloud session can attach it.
7. **Run `make doctor`.** Everything should pass, including "bot App installed", which mints a bot token from the Codespaces secret. With `--skip-bot-key`, expect two FAILs for the missing `BOT_APP_PRIVATE_KEY`, each showing the command that fixes it. Then stop the Codespace: **Codespaces** → **⋯** → **Stop**.
8. **Hand over** as in step 6 above: Claude runs the whole of step 6a, including the Dependabot test once the bot secrets are set.
9. **Only if you used `--skip-bot-key`:** set the two secrets later with the commands from the doctor hints. On a Mac they read the Keychain; in a Codespace with `BOT_APP_KEY_B64`, they read the secret. Then tell Claude to run the Dependabot test.

**A repo bootstrapped earlier with `--skip-bot-key`** (such as `sandbox-node-local`): do steps 0 and 2, open a Codespace on it, and run `unset GITHUB_TOKEN GH_TOKEN` and `gh auth login` as in step 4. Then run:

```bash
for app in actions dependabot; do
  printf %s "$BOT_APP_KEY_B64" | base64 -d | gh secret set BOT_APP_PRIVATE_KEY --repo Jomaries777/sandbox-node-local --app "$app"
done
make doctor
```

---

The rest of this page is the **6b** checklist for Cloud Run.

Step 6b is the end-to-end test of the Node + Cloud Run slice on a real sandbox repo and a real GCP project. Only the owner can do this setup, because it needs your GitHub login, your Keychain (bot key, Claude token) and your Google login. After it, the rest of step 6 runs from a Claude Code cloud session: deploys run in GitHub Actions with keyless OIDC, so the session needs no credentials.

Claude never handles the bot key, the Claude token or your Google credentials. Expect about 15 minutes. Idle cost is $0: Cloud Run scales to zero, and bootstrap creates a $10 budget alert.

## 0. Before you start

- Tools: `gh`, `gcloud`, `jq` and `git`. Check with `gh auth status` and `gcloud auth list`. Docker isn't needed locally, because images are built in CI.
- The Keychain already holds the bot App key (service `github-app-private-key`) from the [M0 setup](m0-owner-setup.md). Check it with:

  ```bash
  security find-generic-password -s github-app-private-key >/dev/null && echo "bot key: ok"
  ```

- Keep the Claude token from `claude setup-token` ready. Bootstrap asks for it in a hidden prompt, unless it's already in the Keychain under service `claude-code-oauth-token`.

## 1. Create a dedicated GCP project

Use a **new** project. Never use `pse-advisor-feat001` or any other existing one. The scripts always pass `--project` explicitly, so you don't need to change your active gcloud project.

```bash
gcloud auth login                              # if `gcloud auth list` shows no active account
gcloud billing accounts list                   # note the ACCOUNT_ID, e.g. 0A1B2C-3D4E5F-6A7B8C
export GCP_PROJECT_ID="sandbox-node-cr-$(date +%m%d)"   # 6-30 chars: lowercase letters, digits, hyphens
export BILLING_ACCOUNT="<ACCOUNT_ID>"
gcloud projects create "$GCP_PROJECT_ID"
gcloud billing projects link "$GCP_PROJECT_ID" --billing-account "$BILLING_ACCOUNT"
```

Done when `gcloud billing projects describe "$GCP_PROJECT_ID"` shows `billingEnabled: true`.

Creating the budget needs the Billing Account Administrator or Billing Account Costs Manager role on that billing account. You have it if you own the account.

## 2. Create the sandbox repo from the template

```bash
cd ~/src   # or wherever you keep clones
gh repo create sandbox-node-cloudrun --template Jomaries777/template-repo-ci --public --clone
cd sandbox-node-cloudrun
```

Done when `git status` is clean. Bootstrap refuses to start on a tree with uncommitted changes.

## 3. Run bootstrap

```bash
export BOT_APP_ID="$(gh variable get BOT_APP_ID --repo Jomaries777/template-repo-ci)"
make bootstrap STACK=node TARGET=cloud-run
```

`GCP_PROJECT_ID` and `BILLING_ACCOUNT` come from step 1. Optional: `GCP_REGION` (default `us-central1`) and `APP_NAME` (default: the repo name). Bootstrap then does the following, and it's safe to rerun if anything fails half-way:

1. Keeps `stacks/node` and the `cloud-run` adapter, writes `deploy.yml` (`target: cloud-run`, `stack: node`), and commits.
2. Pushes to `main`. This is the one owner-only exception to "never push to `main`": the new repo has no ruleset yet.
3. Applies the repo settings and the `main` ruleset, and creates the `dev` and `production` Environments. You are the required reviewer on `production`.
4. Sets the secrets `CLAUDE_CODE_OAUTH_TOKEN`, `BOT_APP_PRIVATE_KEY` (also as a Dependabot secret) and the variable `BOT_APP_ID`. Values are piped to `gh`, never written to disk.
5. Sets up GCP:
   - enables the APIs
   - creates the Artifact Registry repo and its cleanup policy
   - creates the Workload Identity pool for `main` of this repo only
   - creates the deploy and runtime service accounts
   - creates `<app>-dev` and `<app>-prod`, serving Google's sample page until the first deploy
   - creates the $10 budget
   - sets the `GCP_*` and `APP_NAME` repo variables

To see every command first without running anything, add `--dry-run`: `scripts/bootstrap.sh --stack node --target cloud-run --dry-run`.

If bootstrap stops half-way and refuses to rerun because of uncommitted changes, reset with `git checkout -- . && git clean -fd`, then run it again.

## 4. Install the bot App on the sandbox repo

Open <https://github.com/settings/installations>, go to **jomaries777-agent-bot** → **Configure**, and add `sandbox-node-cloudrun` under **Repository access**.

## 5. Check everything with doctor

```bash
make doctor
```

Done when it ends with `doctor: all checks passed`. Every FAIL line comes with a `fix:` hint. A SKIP is fine when it says why.

## 6. Hand over to the cloud session

Start a Claude Code cloud session with `Jomaries777/sandbox-node-cloudrun` attached, or ask the existing session to add it. Then say "run step 6". From there, Claude:

- opens and merges a code PR and watches classify → build → dev → production. **You approve production**: one tap on the deployment in the GitHub app.
- merges a deliberately broken smoke test and checks that dev reverts automatically in under 2 minutes
- opens a docs-only PR and checks that the review and the deploy are skipped
- pins an old dependency so that a Dependabot patch PR auto-merges, and checks that a minor one waits for you
- records what step 6 must prove (plan.md Deviations): the image-cleanup policy and tags, the secrets and prompts, and the PR path on a protected repo. It then fixes whatever breaks, as PRs to `template-repo-ci`.

## 7. Afterwards: tear down

When step 6 is done and recorded, delete the project to stop all charges:

```bash
gcloud projects delete "$GCP_PROJECT_ID"
```

The sandbox repo can stay or be deleted with `gh repo delete Jomaries777/sandbox-node-cloudrun`.
