# CLAUDE.md

GitHub template for AI-native projects. Keep this under one page; when Claude makes the same mistake twice, add it below.

## Commands

| Command | Healthy output |
|---|---|
| `make lint` / `make lint FILE=<path>` | Exit 0, no findings (shellcheck, actionlint, markdownlint, stack linters) |
| `make fmt` / `make fmt FILE=<path>` | Exit 0; rewrites files in place |
| `make test` | Every script test prints `ok - ...`; exit 0 |
| `make typecheck` | Exit 0 (no-op for stacks without types) |
| `make build` | Exit 0; artifacts only in ignored dirs |
| `make acceptance` | Acceptance suite passes (CI containers / dev only) |
| `make smoke URL=<url>` | `prod-safe` smoke tests pass against `<url>` |

## Conventions

- Artifact loop: `intent/<id>-<slug>/intent.md` -> `spec.md` -> `plan.md` -> PR. Each folder is committed; later artifacts are written only after the earlier one is accepted.
- Start every change in plan mode, reading the accepted `spec.md` and `plan.md`.
- Conventional commits (`feat:`, `fix:`, `docs:`, `chore:`, `test:`, `ci:`). Branches: `feat/*`, `fix/*`, `docs/*`.
- Push only as the bot: on a signed-in device `GH_TOKEN="$(scripts/bot-token.sh)" git push ...` / `gh pr create ...`; in a cloud session (environment "Template projects (bot relay)") `scripts/bot-relay.sh --pr "title"`. Bot secrets for a repo: `scripts/bot-secrets.sh owner/repo`.
- Never push to `main`. Agent output always arrives as a PR; only the owner approves.
- Never edit `.github/workflows/` as the bot (the App has no `workflows` permission).
- Must-hold rules are backed by the ruleset and CI; hooks are an early guard on Edit/Write (secrets also on Bash), not a sandbox; skills are advisory. Hooks need `jq` and block every edit without it. The `permissions.deny` list is a convenience; the ruleset is the real guard on `main`.

## Architecture

The repo is a template: each project made from it gets the same loop (intent, spec, plan, PR, `ci-ok` gate, advisory Claude review, deploy through pluggable targets). Deterministic work (lint, test, classify, deploy decisions) is done by scripts and CI, never by AI.

Key paths: `intent/` artifacts; `.github/workflows/` CI; `scripts/` bot token, Antigravity bridge (`agy-*.sh`), deploy dispatcher; `scripts/hooks/` Claude Code hooks; `.claude/` settings, agents, commands, skills; `REVIEW.md` review rubric; `AGENTS.md` Antigravity entry point.

## Verification

Run `make lint test` before saying anything is done, then run the `verifier` subagent, which checks the diff against `plan.md` "Proof". Evidence is command output and `git diff`, not claims.

## Things Claude gets wrong

- Trusting an agent's `SUCCESS` without a diff: Antigravity `/teamwork` reported `SUCCESS` and changed nothing. Check `git diff` and `make lint test`.
- Pasting wrapped tokens: `claude setup-token` wraps across lines. Store with `pbpaste | tr -d '[:space:]' | gh secret set ...`.
- Using `--mode auto` for `agy`: not available on this account; use `--sandbox` in a worktree.
- Making `claude-review` a required check or giving it an API-key fallback: it is advisory and Pro-quota only; only `ci-ok` is required.
- Editing tests on a `fix/*` branch to make them pass: write and commit the failing test first.
- Agreeing a design in chat instead of in plan mode (PD-14, twice): start every change in plan mode, from the accepted `spec.md` and `plan.md`, even when the owner approves the approach in chat.
