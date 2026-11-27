# M4: criterion 8, a real `agy-run.sh` run (2026-11-26)

Spec §8 criterion 8: "`agy-run.sh` produces a draft PR with a live-updating `antigravity/<mode>` check run, and Claude Code is woken by its completion." Until now it was proven only with fixtures (M1 Track C). The M2 runs were killed by the 2026-11-15 shutdown, and their work was finished by Claude Code.

The run was on the owner's Mac, with `agy` 1.5.9 (the Spike A version), from the template's `main` at `9a34b03`. Claude Code started it, under the bot sign-in on this Mac.

```bash
scripts/agy-run.sh boost intent/0001-github-cicd-pipeline/plan.md --task "<task>" --dry-run   # exit 0, no change
scripts/agy-run.sh boost intent/0001-github-cicd-pipeline/plan.md --task "<task>"
```

The task was small and real, in a path that isn't protected. It addresses finding 7 of the [Workers results](m3-step6-workers-results.md): "Only edit README.md… add at most two sentences: a switch does not tear down the old target, which keeps serving its last version until you remove it yourself; `make doctor` checks only the active target. Change no other file or line."

## Result

| Part of criterion 8 | Evidence | Result |
|---|---|---|
| Draft PR | [#76](https://github.com/Jomaries777/template-repo-ci/pull/76), opened as a draft by `app/jomaries777-agent-bot` from branch `agy/0001-github-cicd-pipeline-3` | ✅ |
| `antigravity/boost` check run, live-updating | Check run 139918798343 on `1b6fb46`, created `in_progress` by the bot App. Its output changed four times while agy ran (see Timeline). | ✅ |
| Completion | The gate passed. A new check run, 139923920139, on the final commit `fb37ad9` is `success`. The first one was set to `neutral` ("superseded"), and the PR was marked ready | ✅ |
| Claude Code woken by the completion | A background monitor that runs no AI read the check run on the PR head every 20 s and exited when it completed (12:55:36). Its exit re-invoked this Claude Code session, which then checked the diff. This is the spec §4.7 route: "`gh pr checks --watch` under a non-AI monitor". | ✅ |
| The change is real | Checked by hand, because an agent's SUCCESS can be empty (`CLAUDE.md`): `git diff origin/main...HEAD` is one line of `README.md`, 1 insertion and 1 deletion, the two sentences appended to the switch sentence. `make lint` exits 0 and `make test` gives 20 passed, 0 failed in the worktree | ✅ |

The app's own PR monitor (Auto-fix) can't be used for this. The app turns it on only for PRs opened by the account `gh` is signed in with, and agy's PRs come from the bot.

## Timeline (UTC, from the check runs' API timestamps and the monitor log)

| Time | Event |
|---|---|
| 12:45:44 | `agy-run.sh` started: worktree from `origin/main`, start commit `1b6fb46` pushed by the bot |
| 12:45:56 | Check run `antigravity/boost` created, `in_progress`, on `1b6fb46` |
| 12:46:14 | Draft PR #76 seen by the monitor |
| 12:46:15 | Output: "agy boost: running", 1 step, 10 s |
| 12:50:13 | Output: 13 steps, 246 s, tools `edit_file` ×1, `run_command` ×2, … |
| 12:52:44 | Output: 31 steps, 395 s |
| 12:53:05 | Output: agy status SUCCESS, 38 steps, 138,000 tokens, 419 s |
| ~12:53 → 12:55:25 | The verification gate: a tool-checked diff, then `make lint test` with `Makefile` and `tests/scripts/` restored from `main` |
| 12:55:25 | Commit `fb37ad9` pushed. Check run 139923920139 `success`, "Verification gate passed" |
| 12:55:26 | Check run 139918798343 set to `neutral` ("superseded by fb37ad9…"); PR marked ready |
| 12:55:36 | The monitor saw the completed check run and exited, which woke Claude Code |

## Findings

1. **agy PRs fail the template's own title check.**
   - **What happened:** `agy-run.sh` titles its PRs `agy(<mode>): <id>-<slug>`. That isn't a conventional-commit type, so `hygiene` failed and `ci-ok` failed with it (run [45824194943](https://github.com/Jomaries777/template-repo-ci/actions/runs/45824194943)).
   - **The workaround:** Claude Code retitled #76 as the bot ("docs: note that switching targets leaves the old target serving"), then closed and reopened it. `pr.yml` doesn't run on `edited`, and a re-run reuses the old event's title. On the reopened run, [45824751234](https://github.com/Jomaries777/template-repo-ci/actions/runs/45824751234), `hygiene` and `ci-ok` pass. The agent's diff was not touched.
   - **To fix:** `agy-run.sh` should open the PR with a conventional title, in a `fix/*` PR whose failing test (`tests/scripts/test_agy_run.sh`) comes first.
   - **Fixed** in #78. Titles are now `feat(<id>-<slug>): agy <mode> run`, and `tests/scripts/test_agy_run.sh` checks them against `pr.yml`'s regex.
2. **The check run under-reports edits.**
   - **What happened:** the summary says "files written: 0", although the agent changed `README.md`. `agy-events.sh` counts only `write_file` events, and agy 1.5.9 edited the existing file with `edit_file`. The Spike A fixtures have only `write_file`.
   - **Why the run still passed:** the gate uses `git diff`, not this count. But the "delegated work but no files written" warning could fire on a run that did change files.
   - **To fix:** count `edit_file` too, from a real `edit_file` event. A passed run deletes its `events.ndjson`, so the event shape has to come from the next run's stream, or from a run kept with the work directory.
   - **Fixed** in #88. `agy-events.sh` counts `edit_file` too (same `Path` parameter), tested against `tests/fixtures/agy/edit.ndjson` from a real agy 1.5.18 run.
3. **The whole `plan.md` goes into the prompt.**
   - **What happened:** the prompt was about 67,000 characters, nearly all of it `intent/0001-github-cicd-pipeline/plan.md`. A one-line README change used 138,000 tokens and 419 s. Spike A's trivial `/boost` used 26k tokens and 48 s.
   - **What it means:** this is by design (spec §4.8 sends the accepted plan). A long-lived plan makes every run cost more, though. Recorded, with no change proposed.
