# template-repo-ci

A GitHub template for AI-native projects. Every project made from it gets the same loop:

1. An idea becomes `intent.md`, then `spec.md`, then `plan.md`, then a PR.
2. The PR runs deterministic CI (lint, tests, security scans). `ci-ok` is the only required check.
3. Claude writes an advisory review.
4. You approve; agents never merge.
5. A merge deploys through a pluggable target, with a pre-traffic test, live checks and an automatic revert.

Agents work as a GitHub App bot, never as you. Idle projects cost $0.

How it is built and why: [`intent/0001-github-cicd-pipeline/`](intent/0001-github-cicd-pipeline/) (intent, spec, plan), and [`intent/0002-bot-identity-any-device/`](intent/0002-bot-identity-any-device/) for the bot identity. Rules for agents: [`CLAUDE.md`](CLAUDE.md) (Claude Code) and [`AGENTS.md`](AGENTS.md) (Antigravity).

## Start a new project

Follow these steps in order. Each one says what "done" looks like. The one-time steps (2 and 3) are skipped on later projects.

### 1. Prerequisites

- A GitHub account. A **public** repo is assumed: GitHub Pages, branch rulesets, secret scanning and CodeQL are free there.
- A Claude Pro or Max subscription, for the advisory review in CI.
- On the device you bootstrap from: `git`, `make`, `bash`, `jq` and the GitHub CLI `gh`. A Mac, a Linux machine or a GitHub Codespace (including one opened from a phone) all work.
- For the deploy target you pick (see [Choose a stack and a target](#choose-a-stack-and-a-target)): `gcloud` (logged in with `gcloud auth login`) for `cloud-run`, `node` and `npm` for `cloudflare-workers`, nothing extra for `github-pages` or `none`.

Done when `gh auth status` shows you logged in as the owner.

### 2. One-time owner setup

Do this once per GitHub account, not per project. The template's own owner has already done all of it.

1. **Bot App.** Create the GitHub App the agents act as, from [`scripts/bot-app-manifest.json`](scripts/bot-app-manifest.json). It has no `workflows` permission, so agents can never change CI. Save its App ID as the repo variable `BOT_APP_ID` on your copy of the template. Steps: [`spikes/m0-owner-setup.md`](intent/0001-github-cicd-pipeline/spikes/m0-owner-setup.md), section 2.
2. **Bot token broker.** Deploy the broker, a free Cloudflare Worker that holds the bot App's private key so no device has to. It also needs the login-only App that proves who you are. Steps: [`broker/README.md`](broker/README.md), "Deploy". After that, delete the downloaded key file. The key exists only in the broker.
3. **Claude token for CI.** Run `claude setup-token`. It prints a token that wraps across two lines. Store it in one piece, because bootstrap's hidden prompt reads only one line:
   - On a Mac, copy both lines, then store it in the Keychain, where bootstrap looks first:

     ```bash
     security add-generic-password -U -a "$USER" -s claude-code-oauth-token -w "$(pbpaste | tr -d '[:space:]')"
     pbcopy < /dev/null
     ```

     `-U` updates the item when you rotate the token. The token is passed with `-w`, not typed at `security`'s prompt, because that prompt also reads only one line. While `security` runs, the token is on its command line, where other users of the Mac could see it with `ps`; on a single-user Mac that is fine.
   - Elsewhere, join the two lines in a text editor before pasting the token at bootstrap's prompt.
4. **Deploy target accounts**, only for the targets you'll use:
   - `cloud-run`: a Google Cloud billing account.
   - `cloudflare-workers`: a Cloudflare account on the Workers Free plan with **no card on file**. Give it a neutral `workers.dev` subdomain, because the name appears in public CI logs.
   - `github-pages` and `none` need no account.

Done when `gh variable get BOT_APP_ID --repo <you>/template-repo-ci` prints the App ID and `curl -s https://<broker>/healthz` prints `{"ok":true,"enabled":true}`.

### 3. One-time machine setup

Do this once on each device you work from.

```bash
gh auth login                                   # as the owner
scripts/bot-login.sh --broker https://<broker>  # open github.com/login/device, enter the code, approve
```

`bot-login.sh` stores a sign-in that only proves who you are, in `~/.config/agent-bot/` (mode 0600). The broker turns it into 1-hour bot tokens for one repo at a time. In a Codespace, run `unset GITHUB_TOKEN GH_TOKEN` before `gh auth login`: the Codespace's own token can't change repo settings or secrets.

Done when `scripts/bot-token.sh <you>/template-repo-ci >/dev/null && echo ok` prints `ok`.

### 4. Create the project from the template

```bash
gh repo create my-app --template Jomaries777/template-repo-ci --public --clone
cd my-app
```

Or use **Use this template** on GitHub, then clone the new repo. Done when `git status` is clean: bootstrap refuses to start on uncommitted changes.

### 5. Bootstrap

Pick a stack and a target (next section), export the target's settings, then run bootstrap:

```bash
export BOT_APP_ID="$(gh variable get BOT_APP_ID --repo <you>/template-repo-ci)"   # set in step 2
make bootstrap STACK=node TARGET=github-pages
```

The target's settings, before `make bootstrap` (`github-pages` and `none` need none):

```bash
# cloud-run: a new GCP project, and the billing account to link it to
export GCP_PROJECT_ID=<new-project-id> BILLING_ACCOUNT=<XXXXXX-XXXXXX-XXXXXX>

# cloudflare-workers: the account ID (dashboard: Workers & Pages), and the API
# token read without echoing it, so it is not in your shell history
export CLOUDFLARE_ACCOUNT_ID=<32-hex-account-id>
read -rs -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN && echo && export CLOUDFLARE_API_TOKEN
```

Run bootstrap in the new repo's clone, never in the template's own checkout: it refuses to run against the template repo (by `--repo`, or by `origin` with `--local-only`).

Bootstrap is safe to rerun: it only fills in what is missing. To see every change and remote call first without making any, run `scripts/bootstrap.sh --stack node --target github-pages --dry-run`. It does this, in order:

1. Keeps `stacks/<stack>/`, writes `deploy.yml`, `CODEOWNERS` and a short project `README.md` in place of this one, removes the template's own files, and commits.
2. Creates the `dev` and `production` Environments. You are the required reviewer on `production`, which deploys from `main` only.
3. Sets the secrets. It reads `CLAUDE_CODE_OAUTH_TOKEN` from the Keychain or a hidden prompt. The broker sets `BOT_APP_PRIVATE_KEY`, so the key never reaches your device. It also sets the `BOT_APP_ID` variable.
4. Provisions the target (`make bootstrap-target`): its cloud resources, variables and Environment secrets.
5. Pushes. On a brand-new repo with no ruleset this goes straight to `main`, the one owner-only exception. That push starts the first deploy, which waits for your approval on `production`.
6. Applies the repo settings and the `main` ruleset.

If it stops half-way and then refuses to rerun because of uncommitted changes, run `git checkout -- . && git clean -fd`, then run it again.

### 6. Install the bot App on the new repo

Open <https://github.com/settings/installations>, then **Configure** your bot App and add the new repo under **Repository access**. To work on the repo from Claude Code cloud sessions, check that the **Claude** App can reach it too.

### 7. Check everything

```bash
make doctor
```

Done when it ends with `doctor: all checks passed`. Every `FAIL` line has a `fix:` hint. A `SKIP` is fine when it says why.

### 8. Your first change

Open Claude Code in the repo and run `/intent`. It interviews you and writes `intent/0001-<slug>/intent.md`. From there:

- `/spec` writes `spec.md` after you accept the intent.
- `/plan` writes `plan.md` after you accept the spec.
- The work arrives as a PR from the bot.
- CI runs, Claude reviews, you approve and merge, and the merge deploys.

Approve each artifact by merging it before asking for the next one.

## Choose a stack and a target

`STACK` is the language of the hello service you start from. Each stack has lint, type checks, unit tests, an acceptance suite, `prod-safe` smoke tests, a Dockerfile, Dependabot updates and `make build-static`.

| Stack | Service | Tooling |
|---|---|---|
| `node` | TypeScript, `node:http` | ESLint, Prettier, `tsc`, Vitest, Playwright |
| `python` | standard-library `http.server` | ruff, mypy, pytest (hash-pinned) |
| `go` | standard-library `net/http` | `gofmt`, `go vet`, staticcheck, `go test`; distroless image |

`TARGET` is where merges deploy. You can switch later: edit `target:` in `deploy.yml`, run `make bootstrap-target`, and merge. No workflow changes. Switching does not tear down the old target, which keeps serving its last version until you remove it yourself. `make doctor` checks only the active target.

| Target | Best for | Release | Needs at bootstrap | $0 when idle because |
|---|---|---|---|---|
| `github-pages` | Static sites, docs, any stack's GET routes | Local preview smoke test, then commit to `gh-pages`; revert commits the previous version | Nothing (public repo) | Pages is free for public repos |
| `cloud-run` | Containers, full backends | Dark revision with a tag URL, then a traffic switch; revert to the previous revision | `GCP_PROJECT_ID`, `BILLING_ACCOUNT` (a new GCP project). Keyless deploys (OIDC). A $10 budget alert is created | Request-based billing, scaled to zero |
| `cloudflare-workers` | Edge APIs, light backends; **node only** | Version with a preview URL, then a deploy at 100%; revert with `rollback` | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN` (Workers Scripts Edit on that one account). The token is stored on the `dev` and `production` Environments only | Workers Free plan, no card on file |
| `none` | Libraries, CLIs, docs | No deploy | Nothing | Nothing is provisioned |

On `github-pages`, `GET /health` answers `301` to `/health/`: the static export writes each route as `<route>/index.html`, and Pages redirects the bare path. The smoke suites follow the redirect. Point an uptime check at `/health/`, or have it follow redirects.

`cloudflare-workers` was proven end to end on a live account on 2026-11-23, with a bootstrap, a gated production release and an automatic revert: see [`spikes/m3-step6-workers-results.md`](intent/0001-github-cicd-pipeline/spikes/m3-step6-workers-results.md).

## Continue on another computer

- **Your own device:** clone the repo, then do [step 3](#3-one-time-machine-setup) once (`gh auth login`, `scripts/bot-login.sh`). Push as the bot with `GH_TOKEN="$(scripts/bot-token.sh <owner>/<repo>)" git push …` and open PRs the same way with `gh pr create`.
- **A phone:** open a Codespace on the repo, run step 3 in its terminal, and work there. Approve production deploys with one tap in the GitHub app.
- **Claude Code cloud sessions:** use a personal cloud environment whose network secret for the broker's host is limited to `/relay`, with `BOT_BROKER_URL` set. Sessions there commit and open PRs as the bot with `scripts/bot-relay.sh --pr "title"`. Setup: [`broker/README.md`](broker/README.md), "Use it from a cloud session".

Nothing a project needs lives only on one machine. The bot key is in the broker. The Claude token and target credentials are repo or Environment secrets.

## Commands

| Command | What it does |
|---|---|
| `make lint` / `make fmt` | shellcheck, actionlint, markdownlint and the stack's linters / formatters |
| `make test` | Script tests, broker tests and the stack's unit tests |
| `make typecheck` / `make build` | Type-check / build the deploy artifact (after bootstrap) |
| `make acceptance` | Acceptance suite against a local container |
| `make smoke URL=<url>` | `prod-safe` smoke tests against a URL |
| `make bootstrap STACK=… TARGET=…` | Turn a fresh copy into a configured project |
| `make bootstrap-target` | Provision the target named in `deploy.yml` (switch targets) |
| `make doctor` | Read-only check of repo settings, secrets, the bot App and the target |
