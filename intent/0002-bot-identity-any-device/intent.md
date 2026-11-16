# Intent: Act as the agent bot from any device

| Field | Value |
|---|---|
| Status | Draft |
| Product owner | Repo owner (sole human: product owner, engineer and release manager) |
| Created | 2026-11-16 |
| SDLC stage | Stage 1, Plan: "Capture as intent.md" |
| Framework | [The AI-native SDLC playbook](https://claude.com/resources/articles/the-ai-native-sdlc-playbook) |
| Next artifact | `spec.md` in this folder, written only after this file is accepted and committed |

## Problem

Agents push and open PRs as the bot GitHub App (`jomaries777-agent-bot`), so that the owner, not the author, approves every agent PR. `scripts/bot-token.sh` mints the bot's 1-hour token from the App private key, and that key lives only in a macOS Keychain, one key per Mac.

This works on the owner's Mac and nowhere else:

- **Other PCs and devices.** Antigravity or Claude Code on a Windows or Linux PC can't act as the bot. Agent work there arrives as the owner, so the owner can't approve it and has to merge with the admin bypass. That weakens the "only the owner approves" rule.
- **Phone and tablet.** On 2026-11-16 the owner set up `sandbox-node-local` from an Android tablet through a Codespace. Bootstrap had to skip the bot key (`--skip-bot-key`), so the `BOT_APP_PRIVATE_KEY` secrets are missing until the owner is back on a Mac. Until then, Dependabot patch updates are not approved automatically, and `make doctor` reports 2 failures.
- **Cloud Claude Code sessions** like the one that built M2 open PRs as the owner, for the same reason. This is a recorded Deviation in `0001`'s `plan.md`.
- **A new Mac** needs the key copied by hand. Each copy is another place the key lives.

## Proposed outcome

- The owner can act as the bot from any device they use (Mac, other PCs, a Codespace on a phone or tablet, and cloud Claude Code sessions) without copying the App private key onto it.
- A new device is set up by signing in once, not by moving a key file.
- Access can be removed from one device, or from everyone, without rotating the App key for every other device.
- New projects made from the template can set the bot secrets without a Mac (`bootstrap.sh` and `make doctor` stop depending on the Keychain).
- The idle cost stays at about $0.

## Affected users and systems

- **The owner**, on every device.
- **Agents:** Antigravity (`scripts/agy-run.sh`) and Claude Code, local and cloud.
- **`scripts/bot-token.sh`**, plus the key-related steps of `scripts/bootstrap.sh` and the checks in `scripts/doctor.sh`.
- **Owner docs:** `intent/0001-github-cicd-pipeline/spikes/m0-owner-setup.md` and the step 6 owner setup.
- **GitHub Actions** keep using the `BOT_APP_PRIVATE_KEY` secret through `actions/create-github-app-token`. How that secret gets set may change.
- **A token broker**: a small hosted service that holds the App key, possibly in a GCP project (Secret Manager and Cloud Run) shared with M2 step 6b. Where it runs is decided in `spec.md`.
- **GitHub Codespaces user secrets**, for the first step.
- **The cloud environment's stored credentials**, for cloud sessions.

## Constraints

- **Cost:** about $0 idle. Ask the owner before creating anything billable. Use a new, dedicated GCP project, never `pse-advisor-feat001`. If GCP is needed, share the project with M2 step 6b so billing is set up once.
- **No widening of the bot's power:** the bot keeps its current permissions. It never gets `workflows`, never pushes to `main`, and never approves its own PRs.
- **Short-lived credentials:** devices receive only short-lived tokens, never the App private key, where the design allows it.
- **Claude:** no API-key fallback, as before.
- **Mac flow keeps working:** the Keychain path stays until the new path is proven.
- **Artifact loop:** this intent, then `spec.md`, then `plan.md`, then PRs.

## Decisions

Answered by the owner on 2026-11-16. Each was an open question in the first draft.

1. **What proves a device may get a bot token: the owner's GitHub sign-in.**
   - A device sends its existing `gh` login token. A token broker checks that the token belongs to the owner, then returns a short-lived bot token.
   - Any device where `gh auth login` works can act as the bot, with nothing new to sign in to.
   - This adds no new power: someone holding the owner's GitHub token can already do more than the bot.
   - Rejected: Google sign-in (every device would also need `gcloud`) and per-device credentials (a key to manage per device, close to today's problem).
2. **A free first step comes first: a GitHub Codespaces user secret.**
   - The App key is stored once as a Codespaces user secret, limited to the owner's repos, and `bot-token.sh` reads it when it runs inside a Codespace.
   - This works on any device that can open a Codespace, phone and tablet included, at no cost and without GCP.
   - The cost is that the key lives in a second place until the broker replaces this step.
3. **Cloud Claude Code sessions act as the bot from the broker's first release.**
   - A cloud session has no `gh` login, so it proves itself with one revocable credential stored on the cloud environment, through the environment's secure form.
   - The network proxy injects that credential; the session never sees it.
   - Their PRs then come from the bot, the owner approves them normally, and the admin-bypass Deviation in `0001`'s `plan.md` ends.
4. **Token scope: one repo per token, and every issue logged.**
   - Each broker token is limited to the single repo it was asked for, with the bot App's existing permissions and nothing more (never `workflows`).
   - Each issue is logged: who asked, which repo, when. Logs stay within free-tier storage.
5. **Security review on the spec, before build.**
   - The `secure-change` checklist and `REVIEW.md` are run against `spec.md` before any build PR.
   - The review covers at least token theft, abuse of the broker, revocation, and the Codespaces-secret step.

## Open questions

None for now. Design choices (where the broker runs, how the cloud-session credential is minted and revoked, how `bootstrap.sh` sets secrets without a Mac) belong in `spec.md`.
