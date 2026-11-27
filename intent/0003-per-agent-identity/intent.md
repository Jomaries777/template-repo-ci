# Intent: Each AI agent acts as its own GitHub App

| Field | Value |
|---|---|
| Status | **Accepted** by the product owner on 2026-11-27 (#93), with decisions 1–5 and open questions 1–4 answered |
| Product owner | Repo owner (sole human: product owner, engineer and release manager) |
| Created | 2026-11-27 |
| SDLC stage | Stage 1, Plan: "Capture as intent.md" |
| Framework | [The AI-native SDLC playbook](https://claude.com/resources/articles/the-ai-native-sdlc-playbook) |
| Next artifact | `spec.md` in this folder, written only after this file is accepted and committed |
| Source | Issue [#86](https://github.com/Jomaries777/template-repo-ci/issues/86); PD-10 and PB-42 in [docs/playbook-deviations.md](../../docs/playbook-deviations.md) |

## Problem

The playbook says each agent run has its own identity in logs (PB-42). Today it is only partly met:

- **All agents share one identity.** Claude Code (local and cloud sessions) and Antigravity all act as `jomaries777-agent-bot[bot]`. It opened 35 of the last 40 closed PRs in this repo. From the PR list alone, the owner can't tell which agent did the work.
- **Claude in CI looks like any workflow.** `claude.yml`, `claude-review` and the deploy `report` job post with `GITHUB_TOKEN`, so their comments appear as `github-actions[bot]`, the same name every workflow uses. Only the linked run shows it was Claude.
- **Automation looks like an agent.** Dependabot patch PRs are approved by a script with no AI in it, but the approval is logged as `jomaries777-agent-bot`. That reads as if an AI agent approved a PR, which the rule "the agent can't approve its own work" forbids.

Today a repo setting (`can_approve_pull_request_reviews=false`) stops Claude in CI from approving, because it only has `GITHUB_TOKEN`. A GitHub App token is not covered by that setting. Any change that gives agents App tokens must keep approvals blocked by GitHub, not by a line in a prompt.

## Proposed outcome

- Every action an AI agent takes on GitHub (commits, PRs, comments, reviews) shows that agent's own name: `<owner's GitHub username>-<agent>[bot]`, for example `jomaries777-claude[bot]` and `jomaries777-antigravity[bot]`.
- This covers Claude in CI, Claude Code sessions (local and cloud) and Antigravity runs.
- Deterministic automation that has no AI in it, such as the Dependabot patch auto-merge, acts as `<owner>-ci[bot]` (here `jomaries777-ci[bot]`). It is the only identity whose approval can satisfy the `main` ruleset, apart from the owner.
- No AI agent can get a PR approved or merged, and GitHub enforces this, not a prompt. This holds across agents too: an approval from Claude on Antigravity's PR, or the other way round, doesn't count.
- A project made from the template follows the same pattern under its owner's username. An agent added later gets its own App the same way.
- The owner can still act as any agent from any device, as intent 0002 delivered, and the idle cost stays at about $0.

## Affected users and systems

- **The owner**: creates the Apps once per GitHub account and adds each new repo to them (README step 6).
- **Agents**: Claude in CI (`claude.yml`, `pr.yml` `claude-review`, `deploy.yml` `report`), Claude Code sessions (`scripts/bot-token.sh`, `scripts/bot-relay.sh`), Antigravity (`scripts/agy-run.sh`, `scripts/agy-report.sh`).
- **Automation**: `.github/workflows/dependabot-automerge.yml`.
- **The token broker** (`broker/`), which today holds one App's key and mints tokens for it.
- **Secrets and setup**: `BOT_APP_ID` and `BOT_APP_PRIVATE_KEY`, `scripts/bootstrap.sh`, `scripts/bot-secrets.sh`, `scripts/doctor.sh`, and the README.
- **Docs**: PD-10 and PB-42 in `docs/playbook-deviations.md`; intent 0002's spec, which assumes one bot App.
- **Workflow files** change, so the owner makes those PRs (the bot App has no `workflows` permission).

## Constraints

- **Approvals stay enforced.** Only the owner and the `-ci` automation identity may approve. No change may turn that into an instruction to a model.
- **The `-ci` key never reaches an agent.** It is the one App that can merge without the owner's review, so no device, session or broker route may issue a `-ci` token to an agent.
- **Least privilege.** Each token gets only what its job needs, for at most an hour, for one repo (PB-38). A job that only comments gets no `contents: write`.
- **No third-party write App.** The owner's own Apps are used, not Anthropic's Claude GitHub App (decided 2026-11-27: option C would put `pull_requests: write` on Claude's CI token with no way to remove it).
- **$0 when idle**, and Claude in CI keeps using the Pro `CLAUDE_CODE_OAUTH_TOKEN` quota. Pushes made with App tokens start CI, which `GITHUB_TOKEN` pushes don't; that must not run up the review quota.
- **No new manual steps beyond creating the Apps once** per account and adding each new repo to them.
- **Criterion 6 keeps working**: Dependabot patch updates still merge on their own once `ci-ok` passes.

## Decisions so far

Made by the owner on 2026-11-27, in chat, before this intent:

1. Option B from #86 (the owner's own Apps), not option C (Anthropic's Claude GitHub App) or leaving things as they are.
2. All agent actions move to per-agent Apps, not just Claude in CI.
3. Names follow `<GitHub username>-<agent>`: `jomaries777-claude`, `jomaries777-antigravity`.
4. Non-AI automation gets its own name, `jomaries777-ci`.
5. The pattern is part of the template: every owner creates their own Apps under their own username.

## Open questions

All four were answered by the owner on 2026-11-27.

1. **Cross-agent approval.** Opening a PR needs `pull_requests: write`, and so does approving one, so one agent's token could approve another agent's PR. **Answer:** only the owner's approval counts. The `main` ruleset turns on code-owner review, and `.github/CODEOWNERS` already lists only the owner. This closes PD-2. `jomaries777-ci` may bypass the review rule only, so Dependabot patch updates still merge on their own; `ci-ok` stays required for it. That exception is recorded as a Deliberate entry. Proven in a sandbox before the template changes.
2. **Rename or replace.** **Answer:** rename `jomaries777-agent-bot` to `jomaries777-ci`; `jomaries777-claude` and `jomaries777-antigravity` are new Apps. The owner accepts that the old App's past PRs will most likely show the new name. The renamed App keeps its key, which the broker and devices hold today, so the key is replaced after the rename (see Constraints).
3. **`claude-review`'s token.** **Answer:** `pull_requests` and `issues` write, `contents` read. Inline review comments keep working; it can't push, and its approval doesn't count.
4. **How this is tracked.** **Answer:** the normal loop in this folder, with its own `spec.md` and `plan.md`. The spec says which parts of the 0001 and 0002 specs it amends.
