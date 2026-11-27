# Spec: Each AI agent acts as its own GitHub App

| Field | Value |
|---|---|
| Status | **Accepted** by the product owner on 2026-11-27 (#94). The owner's C1–C12 decisions, also made on 2026-11-27, missed that merge and land with `plan.md`'s PR |
| Intent | [intent.md](intent.md), accepted by the owner on 2026-11-27 (#93) |
| Created | 2026-11-27 |
| Owner decisions | Intent decisions 1–5 and open questions 1–4 (2026-11-27). Two more, taken while this spec was planned on 2026-11-27: agents get tokens from the broker only (D6), and bootstrap adds each new repo to the Apps (D7). C1–C12 decided on 2026-11-27. C9 changes intent decision 3: the Antigravity App is `<login>-agy` (`jomaries777-agy`), not `jomaries777-antigravity` |
| Amends | [0001 spec](../0001-github-cicd-pipeline/spec.md) §4.4, §4.5, §4.6, §4.7 and §4.8; [0002 spec](../0002-bot-identity-any-device/spec.md) FR-1, FR-2, FR-5, FR-6, FR-8 and FR-9. Each amended section gets an "amended by 0003" note in the build |
| Next artifact | `plan.md` in this folder, written in plan mode once this spec is accepted. The acceptance criteria below become its Proof |

## Requirements

### Functional

| ID | Requirement | Intent ref |
|---|---|---|
| FR-1 | Each owner has three GitHub Apps, made from one manifest template: `<login>-claude` and `<login>-agy` (new) and `<login>-ci` (the renamed `jomaries777-agent-bot`). The agent Apps get `contents`, `pull_requests`, `issues` and `checks` write, and `actions` and `metadata` read. `-ci` gets `contents` and `pull_requests` write and `metadata` read. None of them gets `workflows`, `administration` or `secrets`. | Outcome 1, 3, 5; Decisions 3–5; Open question 2 |
| FR-2 | Broker `POST /token` requires `"agent": "claude"` or `"agent": "agy"` and mints a token of that App only. `"ci"`, any other value or no value → `400 bad_agent`. The answer also gives the bot's `login` and user `id`, so scripts can write git author lines without hard-coding a name. | Outcome 1, 2; Constraint "the `-ci` key never reaches an agent" |
| FR-3 | Broker `POST /relay` (cloud Claude Code sessions) acts as the Claude App. Its rule that an existing branch's head must be the bot's uses the Claude App's slug. | Outcome 2 |
| FR-4 | Broker `POST /secrets` takes `"key": "claude"` or `"key": "ci"`, each with one fixed target: `claude` → the Actions secret `CLAUDE_APP_PRIVATE_KEY`; `ci` → the Dependabot secret `CI_APP_PRIVATE_KEY`. The caller can't choose a different target. This is the only route that uses the `-ci` key. | Constraint "the `-ci` key never reaches an agent"; Outcome 3 |
| FR-5 | `scripts/bot-token.sh --agent <claude\|agy> [owner/repo]` gets a token from the broker only. The `--agent` flag is required. The Codespaces (`BOT_APP_KEY_B64`) and Mac Keychain paths are removed (D6). `scripts/agy-run.sh` asks for `agy` and takes its git author from the broker's answer. The push commands in `CLAUDE.md` use `--agent claude`. | Outcome 1, 2; Constraint "the `-ci` key never reaches an agent" |
| FR-6 | The Claude jobs in CI (`claude.yml`; `claude-review` in `pr.yml`; the triage step in `deploy.yml` `report`) mint a token with `actions/create-github-app-token`, from the `CLAUDE_APP_ID` variable and the `CLAUDE_APP_PRIVATE_KEY` secret, with the permissions in the [token table](#token-permissions), and pass it as `github_token`. Steps with no AI in them keep `GITHUB_TOKEN`. The 3-review cap in `claude-review` counts only comments from `<CLAUDE_APP_SLUG>[bot]`. | Problem 2; Outcome 2; Open question 3 |
| FR-7 | The `main` branch rules are split into two rulesets. `main` has deletion, non-fast-forward, linear history and the `ci-ok` check, with the admin PRs-only bypass as today. `main-review` has the `pull_request` rule with `require_code_owner_review: true`, and a PRs-only bypass for the admin and for the `-ci` App. `scripts/gh-settings.sh` takes the `-ci` App's ID from the `CI_APP_ID` variable. | Outcome 4; Open question 1 |
| FR-8 | `dependabot-automerge.yml` mints its token from `CI_APP_ID` and `CI_APP_PRIVATE_KEY`. Patch updates still merge on their own, and still only after `ci-ok` passes. | Outcome 3; Constraint "criterion 6 keeps working" |
| FR-9 | `scripts/bootstrap.sh` adds the new repo to each App's installation through the GitHub API (`PUT /user/installations/{installation_id}/repositories/{repository_id}`, with the owner's `gh` login), sets the `CLAUDE_APP_ID`, `CLAUDE_APP_SLUG` and `CI_APP_ID` variables, and sets both secrets through `/secrets` (D7). If the API refuses, README step 6 names the three Apps to add by hand. | Outcome 5; Constraint "no new manual steps" |
| FR-10 | `make doctor` checks that the repo is in all three installations, that the variables and secrets exist, and that the broker issues a token for each agent. It warns if any of the old copies still exist: the `BOT_APP_ID` / `BOT_APP_PRIVATE_KEY` secrets or variables, the Keychain entry `github-app-private-key`, or a `BOT_APP_KEY_B64` Codespaces secret. It fails if `CI_APP_PRIVATE_KEY` is an Actions secret or `CLAUDE_APP_PRIVATE_KEY` is a Dependabot secret. | Outcome 6; Constraint "the `-ci` key never reaches an agent" |
| FR-11 | An owner runbook (in `broker/README.md`) moves existing repos over in this order: rename the App to `-ci`; create a new `-ci` key and delete the old one; create the `-claude` and `-agy` Apps; load the three keys into the broker; run `scripts/bot-secrets.sh` for each existing repo; delete the old secrets, the Keychain entry and the Codespaces secret. | Open question 2; Constraint "the `-ci` key never reaches an agent" |
| FR-12 | The docs follow the change. In `docs/playbook-deviations.md`: PD-2 becomes `fixed`; PD-10 and PB-42 are updated; a new Deliberate entry records the `-ci` bypass (C2). Also README, `CLAUDE.md`, and the "amended by 0003" notes in specs 0001 and 0002. | Problem; Open question 1 |

### Non-functional

| ID | Requirement | Intent ref |
|---|---|---|
| NFR-1 | **$0 when idle.** No new always-on resource: the same broker Worker and the same D1 database. GitHub Apps cost nothing. | Constraint "$0 when idle" |
| NFR-2 | **Review quota stays bounded.** Pushes made with the Claude App token start `pr.yml`, which pushes made with `GITHUB_TOKEN` don't, so `claude-review` can now run after Claude's own fixes. The existing cap of 3 automatic reviews per PR bounds that. | Constraint "$0 when idle … must not run up the review quota" |
| NFR-3 | **Least privilege.** Every token has only the permissions in the [token table](#token-permissions), lasts at most 1 hour, and is limited to one repo. A job that only comments gets no `contents: write`. | Constraint "least privilege" |
| NFR-4 | **Approvals are enforced by GitHub.** Only the owner, as the only code owner, can satisfy `main-review`; `-ci` passes it only through its bypass. Prompts that say "never approve" stay, but nothing depends on them. | Outcome 4; Constraint "approvals stay enforced" |
| NFR-5 | **Audit.** Each broker audit row also records which agent's token or which key was used (a new `agent` column, added by a D1 migration). Tokens and keys are still never logged. | Outcome 1 |
| NFR-6 | **Only the owner changes CI.** Workflow and ruleset changes arrive as owner PRs. None of the Apps has the `workflows` permission. | Affected systems "workflow files change" |

## Design

### The three Apps

| App | Who uses it | Where its key lives | Can its approval satisfy `main`? |
|---|---|---|---|
| `<login>-claude` | Claude Code sessions (local, through `/token`; cloud, through `/relay`) and Claude in CI | The broker, and the repo's Actions secret `CLAUDE_APP_PRIVATE_KEY` | No: it isn't a code owner |
| `<login>-agy` | `scripts/agy-run.sh` and `scripts/agy-report.sh` | The broker only | No: it isn't a code owner |
| `<login>-ci` | `dependabot-automerge.yml` | The broker (used only by `/secrets`), and the repo's Dependabot secret `CI_APP_PRIVATE_KEY`. Never an Actions secret (C2) | It doesn't need to: it bypasses `main-review` only |

All three come from one manifest template: `scripts/bot-app-manifest.json` becomes a template with `<login>`, `<agent>` and permission placeholders. The login-only App from intent 0002 (`jomaries777-agent-login`) doesn't change.

**Names.** `<login>-<agent>`, in lower case, with short agent names: `claude`, `agy` and `ci` (C9). GitHub limits App names to 34 characters. If `<login>-claude` would be longer (logins over 27 characters), the login is cut so that each name fits, and the agent name stays whole. Bootstrap and the manifest template apply the same rule.

### Token permissions

| Used by | `contents` | `pull_requests` | `issues` | `checks` | `actions` | Why |
|---|---|---|---|---|---|---|
| `claude.yml` (`@claude`) | write | write | write | – | read | Pushes fixes, opens PRs and replies; reads CI logs |
| `claude-review` | read | write | write | – | – | Inline review comments and the summary comment; can't push (open question 3) |
| `deploy.yml` triage | read | – | write | – | read | Comments on the deploy-failure issue; reads the failed job logs |
| Broker `/token`, `claude` or `agy` | write | write | write | write | read | Sessions and `agy-run.sh` push, open PRs, comment and post check runs |
| `dependabot-automerge.yml` (`-ci`) | write | write | – | – | – | Approves (a record, not needed to merge) and enables auto-merge |

`metadata: read` is implied everywhere. A job's `permissions:` block limits only `GITHUB_TOKEN`, so each Claude job also passes `permission-*` inputs to `actions/create-github-app-token`, and those are what limit the App token.

### Broker changes (`broker/`)

- **Configuration.** `wrangler.toml` lists the Apps (ID and slug for `claude`, `agy` and `ci`) in place of the single `APP_ID` / `APP_SLUG`. The keys are Worker secrets: `CLAUDE_KEY_PKCS8`, `AGY_KEY_PKCS8` and `CI_KEY_PKCS8`, replacing `APP_KEY_PKCS8`.
- **`/token`.** `mintToken` takes the agent. `/token` accepts only `claude` and `agy`. The `-ci` key isn't reachable from `/token` or `/relay` at all: only `secrets.js` reads `CI_KEY_PKCS8`.
- **`/relay`** always mints with `claude`.
- **`/secrets`.** `{"repo", "key": "claude"|"ci"}`. The target is fixed per key (FR-4), so the old `apps` field goes away.
- **Audit.** Migration `0003_agent.sql` adds the `agent` column.
- **Unchanged.** The kill switch, the rate limits, the login App check, and the rule that only the owner is served.

### Device scripts

- `bot-token.sh --agent <name>` calls `/token` and prints the token. It has no other source of keys (D6). If the broker is down, it fails and says so (C5).
- `agy-run.sh` and `agy-report.sh` call it with `--agent agy`. The git author comes from the broker's `login` and `id`, replacing the hard-coded `jomaries777-agent-bot[bot]` at `scripts/agy-run.sh:163`.
- `bot-relay.sh` doesn't change: the broker decides that `/relay` acts as Claude.
- `bot-secrets.sh [--key claude|ci] owner/repo...` sets one or both keys; the default is both.

### CI

- **`claude.yml`, `claude-review`, deploy triage.** A step before the action runs `actions/create-github-app-token` (pinned by SHA, as `dependabot-automerge.yml` already does) with `app-id: ${{ vars.CLAUDE_APP_ID }}`, `private-key: ${{ secrets.CLAUDE_APP_PRIVATE_KEY }}` and the `permission-*` inputs from the table. Its output is passed as `github_token`. `GH_TOKEN` for `gh` calls that Claude makes uses the same App token.
- **Review cap.** The count in `claude-review` selects `user.login == "${{ vars.CLAUDE_APP_SLUG }}[bot]"`, so only Claude's own comments count and nobody else's comment can use up the cap.
- **`allowed_bots`** in `claude-review` already uses `github.actor`, so PRs pushed by `-claude` or `-agy` are still reviewed. Dependabot is still excluded.
- **Loops.** A Claude comment starts `claude.yml`, but that job runs only for comments from the `OWNER`, so it skips. A Claude push starts `pr.yml`, bounded by the review cap (NFR-2).

### Rulesets

```text
main         deletion, non_fast_forward, required_linear_history,
             required_status_checks [ci-ok]
             bypass: admin (pull_request)
main-review  pull_request: 1 approval, require_code_owner_review: true,
             require_last_push_approval, dismiss_stale_reviews_on_push,
             required_review_thread_resolution, squash only
             bypass: admin (pull_request), <login>-ci (pull_request)
```

Because `ci-ok` is in a ruleset that `-ci` can't bypass, a Dependabot patch PR still waits for CI. Spike S1 proves that (C3). `.github/CODEOWNERS` already names only the owner, and bootstrap already puts the new owner's handle there.

### Bootstrap and doctor

- **Bootstrap**, after the repo exists and before it pushes:
  1. Look up each App's installation (`GET /user/installations`).
  2. Add the repo to each installation (`PUT /user/installations/{id}/repositories/{repo_id}`).
  3. Set the variables.
  4. Call `bot-secrets.sh` for both keys.

  `--skip-bot-key` still skips step 4. Spike S2 checks that the `gh` login is enough for step 2 (C6).
- **Doctor** checks FR-10. Its old Keychain and Codespaces checks become warnings that a copy is left over.

### Spikes before the build

| Spike | Question | Where |
|---|---|---|
| S1 | With `main-review` bypassed by `-ci` and `ci-ok` pending in `main`, does `gh pr merge --auto` from `-ci` wait for `ci-ok`, and merge once it passes? If `ci-ok` fails, does it stay unmerged? | A new sandbox repo with test Apps |
| S2 | Does `PUT /user/installations/{id}/repositories/{repo_id}` accept the `gh` CLI's OAuth token? | The same sandbox |
| S3 | Does `claude-code-action` post inline review comments with the `claude-review` token from the table? | The same sandbox, after S1 |
| S4 | Can a workflow run that Dependabot didn't start read `CI_APP_PRIVATE_KEY` (a Dependabot secret) and mint a `-ci` token? Expected: no, the secret is empty. | The same sandbox |

The spikes use throwaway Apps and a throwaway repo, so the real Apps and repos aren't touched until they pass. Results go in `intent/0003-per-agent-identity/spikes/`.

### Files that change

| Area | Files |
|---|---|
| Broker | `broker/src/handler.js`, `relay.js`, `secrets.js`, `broker/wrangler.toml`, `broker/migrations/0003_agent.sql`, `broker/README.md`, `tests/broker/*` |
| Device scripts | `scripts/bot-token.sh`, `bot-secrets.sh`, `agy-run.sh`, `agy-report.sh`, `bot-app-manifest.json`, `tests/scripts/test_bot_token.sh`, `test_bot_secrets.sh`, `test_agy_gate.sh` |
| Setup | `scripts/bootstrap.sh`, `doctor.sh`, `gh-settings.sh`, `.github/rulesets/main.json` and a new `.github/rulesets/main-review.json`, `tests/scripts/test_bootstrap.sh`, `test_doctor.sh` |
| Workflows (owner PR) | `.github/workflows/claude.yml`, `pr.yml`, `deploy.yml`, `dependabot-automerge.yml`, and a workflow test for the token table |
| Docs | `README.md`, `CLAUDE.md`, `docs/playbook-deviations.md`, the amended sections of specs 0001 and 0002 |

## Flagged concerns and policy conflicts

| # | Concern | Conflict | Decision (owner, 2026-11-27) |
|---|---|---|---|
| C1 | The broker knows the caller is the owner, but not which agent is calling: the script names the agent. A session could ask for the other agent's token. | PB-42 asks for each agent's identity in the logs. Here the name is what the script declares, not something the broker proves. | **Accepted.** Agent names are attribution, not isolation. Harmless while no App's approval counts. Revisit if agents ever get different permissions |
| C2 | `-ci` can merge any PR without the owner's review, as long as `ci-ok` passes. | "Only the owner approves". Today the bot's approval already has the same effect. A ruleset bypass can't be limited to PRs from one author. | **Limited by where the key lives.** The `-ci` key is only in the broker (used only by `/secrets`) and in the Dependabot secret `CI_APP_PRIVATE_KEY`, which GitHub gives only to runs Dependabot started. It is never an Actions secret: `/secrets` can't write one (criterion 6), doctor fails if one exists (criterion 10), and S4 proves another run can't mint a `-ci` token. `dependabot-automerge.yml` also checks that the PR's author is Dependabot. Recorded as a new Deliberate entry with this limit |
| C3 | Not proven yet: whether auto-merge by a bypass actor waits for `ci-ok` in the other ruleset (S1). If it doesn't, Dependabot patch PRs could merge before CI passes. | 0001 criterion 6 and the `ci-ok` gate. No template change until S1 passes. | **If S1 fails:** the workflow merges only after `ci-ok` succeeds, from a `workflow_run` trigger, so the gate holds |
| C4 | After the rename, past agent PRs will most likely show `jomaries777-ci`. | Past logs would credit agent work to automation. | Accepted by the owner, 2026-11-27 (intent open question 2) |
| C5 | With no key on devices, agents can't push while the broker is down or its kill switch is on. | Availability, against fewer copies of the keys. It also reverses intent 0002's constraint "Mac flow keeps working": the Keychain path goes away. | Accepted by the owner, 2026-11-27 (D6) |
| C6 | Not proven yet: whether the installation API accepts the `gh` CLI token (S2). | Constraint "no new manual steps". | **If S2 fails:** README step 6 lists the three Apps to add by hand, and doctor checks they were added |
| C7 | Pushes made with an App token start workflows, unlike `GITHUB_TOKEN` pushes. CI now runs on Claude's own fixes in `claude.yml`. | Review quota (NFR-2). | **Accepted.** Bounded by the 3-review cap |
| C8 | Workflow steps with no AI in them, such as the step that opens the deploy-failure issue, stay `github-actions[bot]`. `-ci` is used only where automation needs an App. | Intent outcome 3 says automation "acts as `<owner>-ci[bot]`". This spec limits that to the Dependabot auto-merge. | **Accepted.** `github-actions[bot]` already means "a workflow did this", and the `-ci` key stays out of Actions secrets (C2) |
| C9 | App names are limited to 34 characters. `<login>-antigravity` doesn't fit for logins over 22 characters. | Template portability (intent decision 5). | **Short agent names:** `claude`, `agy`, `ci`. Your Apps are `jomaries777-claude`, `jomaries777-agy` and `jomaries777-ci`. For logins over 27 characters, the login is cut and the agent name stays whole. This changes intent decision 3 |
| C10 | `CLAUDE_APP_*` and `CI_APP_*` replace `BOT_APP_*`. The names are clearer, but every script, test and doc that uses `BOT_APP_*` changes. | Size of the change. | **Rename.** With three Apps, "BOT" no longer says which one. Doctor warns on leftovers (criterion 10) |
| C11 | The repo setting `can_approve_pull_request_reviews=false` (`scripts/gh-settings.sh:65`) only covers `GITHUB_TOKEN`. Once Claude in CI uses an App token, that setting no longer stops it from approving. | "The agent can't approve its own work". `main-review`'s code-owner rule takes over that job (NFR-4). Criterion 4 proves it. | **Keep the setting on.** It still stops any workflow that uses `GITHUB_TOKEN` from approving, and costs nothing |
| C12 | `CLAUDE_APP_PRIVATE_KEY` is an Actions secret, so any workflow in the repo that names it can read the Claude key. Agents can't add such a workflow, because no App has `workflows`. Runs on forks get no secrets. | "Least privilege", and intent 0002's "the key lives only in the broker". | **Accepted as an Actions secret.** Simple, and CI doesn't depend on the broker. Doctor checks it is only an Actions secret, never a Dependabot one |

## Acceptance criteria

Each is checked by a `gh` query, a test, or a sandbox run recorded in `intent/0003-per-agent-identity/spikes/`. Together they become `plan.md`'s Proof.

1. **Session and Antigravity PRs.** A PR opened from a Claude Code session has `gh pr view <n> --json author -q .author.login` = `app/jomaries777-claude`. One opened by `agy-run.sh` gives `app/jomaries777-agy`.
2. **CI comments.** Comments from `claude-review`, an `@claude` reply and deploy triage have `.user.login` = `jomaries777-claude[bot]` (`gh api repos/<repo>/issues/<n>/comments`). In the sandbox, `claude-review` posts at least one inline comment with its token from the table (S3).
3. **Review cap.** A workflow test shows the cap step counts only comments from `<CLAUDE_APP_SLUG>[bot]` that carry the `<!-- claude-review -->` marker. A marker in a comment from anyone else doesn't count.
4. **Cross-agent approval doesn't count.** In the sandbox, an approval by `-claude` (made with a broker `/token` token, `gh pr review --approve`) on an `-agy` PR leaves `reviewDecision` = `REVIEW_REQUIRED`, and `gh pr merge` with a `-claude` token is refused.
5. **Dependabot patches.** In the sandbox, a Dependabot patch PR merges on its own after `ci-ok` passes, with `mergedBy` = `jomaries777-ci` (or the sandbox's `-ci` App). With `ci-ok` failing, it stays open (S1). A workflow run started by a push from the owner can't mint a `-ci` token, because `CI_APP_PRIVATE_KEY` is empty there (S4).
6. **Broker.** Broker tests show:
   - `/token` with `agent` `ci`, an unknown agent or no agent returns `400 bad_agent`.
   - A `/token` answer includes the bot's `login` and `id`.
   - `/relay` mints with `claude`, and refuses to move a branch whose head isn't the Claude App's.
   - `/secrets` with `key: ci` writes only the Dependabot secret `CI_APP_PRIVATE_KEY`.
   - Nothing outside `secrets.js` reads `CI_KEY_PKCS8`.
   - Every audited row has `agent` set, and migration `0003_agent.sql` applies to the live D1 database (`wrangler d1 migrations list` shows it applied).
7. **Device script.** Script tests show `bot-token.sh` without `--agent` exits with a usage error and, with the broker unreachable, fails without trying any other source. `grep -E 'Keychain|BOT_APP_KEY_B64|security find-generic-password' scripts/bot-token.sh` finds nothing.
8. **Token table.** A workflow test checks each Claude job's `permission-*` inputs against the token table. `claude-review` has no `contents: write`.
9. **Bootstrap.** A fresh sandbox made from the template: bootstrap adds it to all three Apps with no web step (`gh api /user/installations/<id>/repositories` lists it), and `make doctor` passes.
10. **Doctor checks.** Doctor tests show:
    - A warning for each leftover copy: `BOT_APP_*` secrets or variables, the Keychain entry, and `BOT_APP_KEY_B64`.
    - A failure if `CI_APP_PRIVATE_KEY` exists as an Actions secret, or `CLAUDE_APP_PRIVATE_KEY` as a Dependabot secret (C2, C12).
11. **Rulesets.** `gh api repos/<repo>/rulesets` shows `main` and `main-review`. `main-review` has `require_code_owner_review: true` and the `-ci` App in its bypass list; `main` doesn't list `-ci`.
12. **Docs and checks.** `make lint test` is green. In `docs/playbook-deviations.md`, PD-2 is `fixed`, PB-42 is `Met`, and the new Deliberate entry for C2 exists.
13. **Cost.** `broker/wrangler.toml` still has one Worker and one D1 database. No new Cloudflare or GCP resource.
