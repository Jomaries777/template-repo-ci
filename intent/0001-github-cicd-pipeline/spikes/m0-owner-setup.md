# M0 owner setup (one time)

These steps can only be done by the owner. Claude never handles the private key or tokens.

## 1. Install the missing tools

```bash
brew install actionlint shellcheck node go
```

## 2. Create the bot GitHub App (C5, spec §4.5)

1. Open <https://github.com/settings/apps/new>.
2. Fill it in from [`scripts/bot-app-manifest.json`](../../../scripts/bot-app-manifest.json):
   - **Name**: `jomaries777-agent-bot`
   - **Homepage URL**: the repo URL
   - **Webhook**: untick **Active**
   - **Repository permissions**: Contents **Read & write**, Pull requests **Read & write**, Checks **Read & write**, Issues **Read & write** (Metadata is read-only automatically)
   - **Where can this app be installed**: *Only on this account*
3. Click **Create GitHub App**. Note the **App ID**.
4. **Generate a private key**. A `.pem` file downloads.
5. **Install App** → *Only select repositories* → `template-repo-ci`.
6. Import the key into the macOS Keychain (base64-encoded so the multi-line PEM survives intact), then delete the downloaded file:

   ```bash
   security add-generic-password -a jomaries777-agent-bot -s github-app-private-key -w "$(base64 -i ~/Downloads/jomaries777-agent-bot.*.private-key.pem | tr -d '\n')"
   ```

   ```bash
   rm ~/Downloads/jomaries777-agent-bot.*.private-key.pem
   ```

7. Save the App ID as a repo variable:

   ```bash
   gh variable set BOT_APP_ID --repo Jomaries777/template-repo-ci --body "<APP_ID>"
   ```

## 2b. Bot identity without the key on any device (spec 0002)

Since M2 step 7, the bot App key lives only in the bot token broker (`broker/README.md`), not in the Keychain or a Codespaces secret:

1. Deploy the broker once (`broker/README.md`, "Deploy").
2. On each device, sign in once: `scripts/bot-login.sh --broker https://<broker>`. Then `scripts/bot-token.sh owner/repo` gives a 1-hour bot token for that repo.
3. For cloud Claude Code sessions, create a cloud environment with a network secret for the broker host: header `Authorization`, prefix `Bearer`, path prefix `/relay`, the value from `~/.config/agent-bot/identity`. Sessions there run `scripts/bot-relay.sh --pr "title"`.
4. `make bootstrap` sets a new repo's `BOT_APP_PRIVATE_KEY` through the broker (`scripts/bot-secrets.sh`).

Steps 6 and 7 above (Keychain) are only needed on a Mac without the broker.

## 3. Claude Pro token for CI review (Decision 4, C7)

```bash
claude setup-token
```

The token wraps across **two lines** in the terminal. Select both lines and copy them with ⌘C. Then store the token with all whitespace stripped; pasting it into an interactive prompt keeps only the first line, which gives a `401 OAuth access token is invalid` (Spike B):

```bash
pbpaste | tr -d '[:space:]' | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo Jomaries777/template-repo-ci
```

Then clear the clipboard:

```bash
pbcopy < /dev/null
```

Done when `gh variable list` shows `BOT_APP_ID`, `gh secret list` shows `CLAUDE_CODE_OAUTH_TOKEN`, and `security find-generic-password -s github-app-private-key` finds the key.
