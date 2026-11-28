# Intent: Leave Cloudflare

| Field | Value |
|---|---|
| Status | **Accepted** by the product owner on 2026-11-28 (#107), with decisions 1–9 (the draft's open questions 1–5 answered as decisions 5–9) |
| Product owner | Repo owner (sole human: product owner, engineer and release manager) |
| Created | 2026-11-28 |
| SDLC stage | Stage 1, Plan: "Capture as intent.md" |
| Framework | [The AI-native SDLC playbook](https://claude.com/resources/articles/the-ai-native-sdlc-playbook) |
| Next artifact | `spec.md` in this folder, written only after this file is accepted and committed |
| Source | The 0003 M3 cutover incident on 2026-11-28, recorded in `intent/0003-per-agent-identity/spikes/cutover.md` (lands with the 0003 cutover PR) |

## Problem

The template depends on Cloudflare accounts that the owner can't reliably sign in to.

- **The token broker** (`broker/`, specs [0002](../0002-bot-identity-any-device/spec.md) and [0003](../0003-per-agent-identity/spec.md)) runs as a Cloudflare Worker. It holds the private keys of the three agent Apps and the login App's client secret, and it writes every token it issues to a D1 audit log. On 2026-11-28, during the 0003 M3 cutover, Cloudflare's sign-in emails stopped arriving, and the broker's account was lost. The old Worker still serves tokens for the single App it had, but nobody can change it: it can't be redeployed, its keys can't be rotated, and its kill switch can't be flipped.
- **A replacement Cloudflare account can't be validated.** The verification email doesn't arrive for the new account either. So the plan's fix (plan Deviations, 2026-11-28: a fresh broker in a new account with authenticator 2FA) is blocked, and with it the rest of 0003 M3.
- **The `cloudflare-workers` deploy target** depends on the same kind of account (`x7k2-apps` for `sandbox-node-workers`). Any project on it can lose its production host the same way, and the template recommends it to new owners.

The risk is now a security one. A broker that holds App keys must be one the owner can always reach, to rotate a key or turn it off.

## Proposed outcome

- The broker runs somewhere the owner can always sign in to, still costs $0 when idle, and keeps every guarantee it has today. No device holds an App key. Every token is audited. The kill switch works. Only the owner's identity is accepted.
- The 0003 M3 cutover (one App to three) finishes on the new broker. Devices and cloud sessions sign in to it once (`scripts/bot-login.sh`). After that, `bot-token.sh`, `bot-relay.sh` and `bot-secrets.sh` work as before.
- The old Worker is no longer trusted: its App key is revoked in GitHub, so the lost account holds nothing that still works.
- The template has no Cloudflare dependency left. The `cloudflare-workers` target is gone from `deploy/targets/`, `bootstrap.sh`, the workflows, the docs and the tests. A new owner is never asked to create a Cloudflare account.
- `sandbox-node-workers` is archived. The `x7k2-apps` account is emptied or closed, if the owner can still sign in to it. The Workers proofs stay in the spike records, as history.

## Affected users and systems

- **Owner:** creates a new GCP project and billing link for the broker. Moves the secrets, signs devices in again, and revokes the old App key.
- **Devices and cloud sessions** (Mac, phone, the "bot relay" cloud environment): they sign in once to the new broker URL.
- **The broker** (`broker/`): a new host, secret store and audit store. The Worker-specific code (`wrangler.toml`, D1 migrations, the Workers entry point) goes away or changes.
- **Scripts:** `bot-login.sh`, `bot-token.sh`, `bot-relay.sh`, `bot-secrets.sh`, `doctor.sh`, `bootstrap.sh`, `agy-run.sh` and `sdlc-metrics.sh` (the `CLOUDFLARE_API_TOKEN` tracking).
- **Workflows:** `deploy.yml` and `maintain.yml` drop the Cloudflare variables and secrets. These are workflow edits, so they come through owner PRs.
- **Deploy targets and stacks:** `deploy/targets/cloudflare-workers/` is removed. So is `stacks/node/src/worker.ts`, and the Workers notes in the stack READMEs.
- **Docs:** `README.md` (quick-start step 2, the target table, prerequisites), `broker/README.md`, and specs 0001, 0002 and 0003. The specs are amended where they name Cloudflare, without rewriting their history.
- **Intent 0003:** M3 moves onto the new broker. Its plan records this as a deviation.

## Constraints

- **The host is decided** (owner, 2026-11-28): Cloud Run in a **new GCP project used only for the broker**. Never `pse-advisor-feat001`, and never a project a deploy target uses. Secret Manager holds the keys, and Firestore holds the audit log.
- **$0 when idle** (NFR-1, `cost-guard`). Scale to zero. The secrets have to stay inside Secret Manager's free tier: today's 4 secrets fit, but rotation must not pile up active versions. Firestore must stay inside its free quota. A budget alert goes on the project.
- **Security holds as today, or gets stronger** (`secure-change`). Keys never reach a device, a log, the repo or Claude. Only the owner runs steps that touch a key or a secret value. The broker's GCP identity can read only its own secrets. Deploy credentials for other projects can't reach it.
- **Sign-in must not depend on email codes.** The owner signs in to GCP with authenticator or passkey 2FA, and keeps backup codes.
- **The bot never edits `.github/workflows/`.** Workflow changes are owner PRs.
- **No downtime for agents.** The old Worker keeps serving until every device is on the new broker. Only then is the old key revoked.
- **Projects already made from the template** keep working. Any that use `cloudflare-workers` are switched or archived before the adapter is removed. Today that's only `sandbox-node-workers`.

## Decisions so far

1. Both the broker and the `cloudflare-workers` target leave Cloudflare (owner, 2026-11-28).
2. The broker moves to Cloud Run in its own GCP project, with Secret Manager and Firestore (owner, 2026-11-28).
3. The old broker still serves tokens today, so this is not an outage. 0003 M3 waits for the new broker (owner, 2026-11-28).
4. `sandbox-node-workers` is archived, and the `x7k2-apps` account is emptied or closed (owner, 2026-11-28).
5. The audit log doesn't carry over: D1 is unreadable. The new broker starts a fresh log, and the incident is recorded in the 0003 cutover notes (owner, 2026-11-28).
6. The broker moves first. The `cloudflare-workers` target is removed after it, as a later milestone (owner, 2026-11-28).
7. A cold start of about 1–2 s on the first token after idle is acceptable. No minimum instances (owner, 2026-11-28).
8. `doctor.sh` gets no check for the old Worker's key. Revoking the key in GitHub is enough (owner, 2026-11-28).
9. `github-pages` and `cloud-run` are enough targets for new projects. Any further target would be its own intent (owner, 2026-11-28).

## Open questions

None. Questions 1–5 of the draft were answered by the owner on 2026-11-28, as decisions 5–9.
