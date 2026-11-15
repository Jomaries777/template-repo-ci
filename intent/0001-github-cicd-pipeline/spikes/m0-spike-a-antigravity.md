# Spike A: headless Antigravity CLI (C8)

**Date**: 2026-11-15 · **agy**: 1.5.9 · **Time-box**: 1 h (used about 15 min of runs)
**Fixtures**: [`tests/fixtures/agy/`](../../../tests/fixtures/agy/), sanitized (local paths and the username are redacted)

## Runs

| Run | Command | Result | Duration | Tokens | Workspace changed? |
|---|---|---|---|---|---|
| plain | `agy -p "<task>" --output-format stream-json --sandbox` | `SUCCESS` | 14 s | 24k | ✅ yes |
| `/boost` | `agy -p "/boost <task>" …` | `SUCCESS`; chose its "Solo Routine" | 48 s | 26k | ✅ yes |
| `/teamwork` | `agy -p "/teamwork <task>" …` | `SUCCESS` | 395 s | 78k | ❌ **no** |
| `/swarm` | not run, to save quota ("Quota Heavy" per the changelog) | — | — | — | — |

## Event stream (NDJSON, one object per line)

| `event` | Payload key | Fields used by `agy-events.sh` |
|---|---|---|
| `init` | `init` | `cwd`, `permission_mode`, `tools[]` |
| `step_update` | `step_update` | `conversation_id`, `step_index`, `state` (`ACTIVE` / `DONE` / `ERROR`), `step_type` (`user_input`, `agent_response`, `tool`, `subagent`, `system_message`, `unknown`), `tool_name`, `tool_info.parameters`, `text_delta` (streamed text), `duration_seconds`, `usage` |
| `result` | `result` | `status` (`SUCCESS` / …), `response`, `duration_seconds`, `num_turns`, `usage` |

Events are emitted only for the **top-level conversation**. Delegated work (`invoke_subagent`, `send_message`) shows up as a single tool step, with no events from the child conversation.

## Findings

1. **Headless works and slash commands expand in `-p` mode.** The §4.8 primary design is valid for plain prompts and `/boost`.
2. **`--mode auto` isn't available on this account.** agy prints a warning and falls back to `request-review`, but file writes still went through in print mode. `agy-run.sh` uses `--sandbox` plus the default mode, inside an isolated worktree, and never `--dangerously-skip-permissions` outside the sandbox.
3. **`/teamwork` headless reports `SUCCESS` but doesn't land code in the workspace.**
   - It runs an interview: headless, it answers its own questions and approves its own task prompt. `[skip-interview]` skips this step.
   - It hands off to a coordinator conversation and exits once the prompt is prepared. The work runs, or doesn't, outside the workspace and outside the event stream.
   - It's also about 3× the tokens and about 8× the time of `/boost` for a trivial task.
4. **So `result.status` is never trusted on its own** (playbook: verification comes from tools). `agy-run.sh` decides success only if all three hold:
   - (a) `result.status == SUCCESS`
   - (b) `git diff --quiet` reports changes, or new commits exist on the branch
   - (c) `make lint test` passes in the worktree

   If any of them fails, the check run is marked `failure` with the reason, and Claude Code wakes up.

## Gate decision

| Mode | Path |
|---|---|
| `/boost` and plain prompts | **Primary (headless)**: `agy-run.sh boost …` → draft PR + live check run (§4.8 steps 1–7) |
| `/teamwork`, `/swarm` | **Fallback (interactive)**: the owner starts the mode in an interactive `agy` session in the branch's worktree, prefixing `[skip-interview]` when the plan is already accepted. `AGENTS.md` tells Antigravity to call `scripts/agy-report.sh <event>` at each milestone, which updates the same check run. Revisit headless once agy reports child-conversation events or blocks until delegated work finishes. |

## Cost guidance for `agy-run.sh` and `AGENTS.md`

- Default to `/boost`. Use `/teamwork` for multi-file features that benefit from an independent review, and `/swarm` only for wide, parallel work.
- `agy-run.sh` prints the expected cost class (`boost` low, `teamwork` medium, `swarm` high) before starting.
