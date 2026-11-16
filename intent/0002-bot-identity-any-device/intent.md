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
- **Possibly a GCP project** (Secret Manager and Cloud Run), if the chosen design needs one.

## Constraints

- **Cost:** about $0 idle. Ask the owner before creating anything billable. Use a new, dedicated GCP project, never `pse-advisor-feat001`. If GCP is needed, share the project with M2 step 6b so billing is set up once.
- **No widening of the bot's power:** the bot keeps its current permissions. It never gets `workflows`, never pushes to `main`, and never approves its own PRs.
- **Short-lived credentials:** devices receive only short-lived tokens, never the App private key, where the design allows it.
- **Claude:** no API-key fallback, as before.
- **Mac flow keeps working:** the Keychain path stays until the new path is proven.
- **Artifact loop:** this intent, then `spec.md`, then `plan.md`, then PRs.

## Open questions

1. What proves a device may get a bot token: the owner's Google sign-in (`gcloud`), a GitHub sign-in, or a separate per-device credential? **Owner**, with options and trade-offs in `spec.md`.
2. Is a free first step enough for phones and tablets for now (a GitHub Codespaces user secret read by `bot-token.sh`), with a hosted token broker later? **Owner.**
3. Should cloud Claude Code sessions act as the bot too, or keep opening PRs as the owner? Acting as the bot would remove the admin bypass for their PRs, but needs a credential stored on the cloud environment. **Owner.**
4. If a hosted broker is used, which repos and permissions may its tokens carry, and should every token it issues be logged? **Spec author**, for owner review.
5. Does this change the threat model enough to need a security review against `REVIEW.md` before build? **Owner.**
