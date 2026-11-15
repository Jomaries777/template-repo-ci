# AGENTS.md

Read [CLAUDE.md](CLAUDE.md). It is the single source of truth for commands, conventions and architecture. The rules below apply to Antigravity only.

## Antigravity rules

- Default to `/boost`. Use `/teamwork` for multi-file features that benefit from an independent review, and `/swarm` only for wide, parallel work (high quota cost).
- `/teamwork` and `/swarm` run interactively. When `plan.md` is accepted, start the prompt with `[skip-interview]`.
- In `/teamwork` and `/swarm`, report each milestone so the PR check run stays current:

  ```bash
  scripts/agy-report.sh <start|progress|blocked|done|failed> "<message>"
  ```

  Call `start` first, `progress` after each finished step, `blocked` when you need the owner, and `done` or `failed` last.
- Never change `.github/workflows/`.
- Never push to `main`. Work on a branch and let the run open a draft PR.
- Verification is `make lint test`. A run is not done until it passes and `git diff` shows the intended change. Do not report `done` otherwise.
