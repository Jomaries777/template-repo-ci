# M0 spikes S1–S4 and criterion 4 (early): results

| Field | Value |
|---|---|
| Date | 2026-11-28, local time (UTC+8); GitHub logs show 2026-11-27 UTC |
| Plan | [plan.md](../plan.md) M0, CC row |
| Sandbox | [`Jomaries777/sandbox-agent-apps`](https://github.com/Jomaries777/sandbox-agent-apps), from the template at `ba55802` |
| Throwaway Apps | `jomaries777-tclaude` (5955014), `jomaries777-tagy` (5955173), `jomaries777-tci` (5955211), each installed on the sandbox only |
| Gate | **Passed within the decided fallbacks**: S1 → C3 `workflow_run` merge, S2 → C6 manual step, S3 confirms the review token |

## Setup

The owner created the sandbox and the three Apps, and stored each key in the Keychain (`spike-tclaude`, `spike-tagy`, `spike-tci`). In the sandbox, the owner set `CLAUDE_APP_PRIVATE_KEY` as an Actions secret and `CI_APP_PRIVATE_KEY` as a Dependabot secret, plus `CLAUDE_APP_ID`, `CLAUDE_APP_SLUG` and `CI_APP_ID`. The `.pem` files were deleted. Claude never read a key.

- `tclaude` and `tagy` have contents, pull requests, issues and checks write, and actions read. `tci` has contents and pull requests write.
- CC minted spike tokens with the existing `scripts/bot-token.sh` Keychain fallback, skipping the broker with an empty config dir. Each token listed only the sandbox (`GET /installation/repositories`).

The owner then applied the spec's split rulesets by hand:

```text
main         deletion, non_fast_forward, required_linear_history, required_status_checks (ci-ok)
             bypass: RepositoryRole 5 (admin), pull_request only
main-review  pull_request (1 approval, require_code_owner_review: true)
             bypass: RepositoryRole 5, Integration 5955211 (tci), pull_request only
```

`.github/CODEOWNERS` is `* @Jomaries777`.

## Criterion 4 (early): another agent's approval doesn't count

`tagy` opened [#6](https://github.com/Jomaries777/sandbox-agent-apps/pull/6) (author `app/jomaries777-tagy`). With a `tclaude` token:

```text
POST /pulls/6/reviews event=APPROVE  -> jomaries777-tclaude[bot] APPROVED
gh pr view 6                         -> reviewDecision REVIEW_REQUIRED, mergeStateStatus BLOCKED
gh pr merge 6 --squash               -> refused: "the base branch policy prohibits the merge"
PUT /pulls/6/merge                   -> 405 "Required status check "ci-ok" is expected.
                                        Waiting on code owner review from Jomaries777."
```

Rule suite `5413701439`: actor `jomaries777-tclaude[bot]`, result `fail`.

**Result: pass.** GitHub accepts the App's approval, but it doesn't satisfy `main-review`, and the merge is refused (NFR-4). The full criterion 4 is still proven in M4, on the template.

## S1: does auto-merge by `-tci` wait for `ci-ok`?

**Auto-merge doesn't use the bypass.** On #6, `ci-ok` had passed ([run 46033033982](https://github.com/Jomaries777/sandbox-agent-apps/actions/runs/46033033982)). `GH_TOKEN=<tci> gh pr merge 6 --auto --squash` exited 0, with `autoMergeRequest.enabledBy` `app/jomaries777-tci`. After 20 s the PR was still `OPEN` and `BLOCKED` (`reviewDecision` `REVIEW_REQUIRED`, also when viewed as `tci`). No rule suite was recorded, so auto-merge never tried to merge. It waits for a code-owner review that a Dependabot patch PR never gets.

**A direct merge uses the bypass, and `ci-ok` still holds:**

| PR | `ci-ok` | `tci` call | Result | Rule suite |
|---|---|---|---|---|
| #6 | passed | `PUT /pulls/6/merge` | merged, `mergedBy` `app/jomaries777-tci`, commit `6898269` | `5413722357` **bypass** |
| [#8](https://github.com/Jomaries777/sandbox-agent-apps/pull/8) | pending | `PUT /pulls/8/merge` | 405 "Required status check "ci-ok" is expected." | `5413735887` fail |
| #8 | failed (`hygiene`; [run 46033337764](https://github.com/Jomaries777/sandbox-agent-apps/actions/runs/46033337764)) | `PUT /pulls/8/merge` | 405 "Required status check "ci-ok" is failing." | `5413741416` fail |

PR #8 was opened by `tagy` and then closed, with its branch deleted.

**Result: `--auto` fails S1; the C3 fallback applies.**

- It fails differently from C3's wording. C3 worried that auto-merge might merge before `ci-ok` passed. In fact auto-merge never merges at all, because it waits for the code-owner review.
- So the plan's "stays open when `ci-ok` fails" question wasn't tested with `--auto`, since `--auto` doesn't merge even when `ci-ok` passes. It was tested on the C3 path instead: direct merges by `tci`, shown in the table above.

- `dependabot-automerge.yml` merges directly (`gh pr merge --squash`, no `--auto`) from a `workflow_run` trigger on `pr` that checks `ci-ok` succeeded for the PR's head SHA.
- The gate doesn't depend on the trigger's timing. `-tci` isn't a bypass actor in `main`, and GitHub refused its merge both while `ci-ok` was pending and after it failed.

## S2: does the installation API accept the `gh` token?

The `tclaude` installation ID (`186548845`) came from `GET /repos/{repo}/installation` with the App JWT. CC used a scratch copy of `bot-token.sh` that prints the ID instead of minting a token. Then, with the owner's `gh` login (an OAuth token with scopes `repo`, `workflow`, `read:org`, `gist`, `project`, `delete_repo`):

```text
PUT /user/installations/186548845/repositories/<repo_id>
-> 403 "You do not have permission to modify this app on Jomaries777."
```

Earlier, `GET /user/installations` with the same login also returned 403.

**Result: fails; the C6 fallback applies.** README step 6 lists the three Apps to add each new repo to by hand, and `doctor.sh` checks that they were added.

CC aimed this call at `template-repo-ci` instead of a throwaway repo. GitHub refused it, and afterwards the `tclaude` token still listed only the sandbox.

## S3: inline comments with the `claude-review` token

The owner pushed [`spike-s3.yml`](https://github.com/Jomaries777/sandbox-agent-apps/blob/spike/s3-s4/.github/workflows/spike-s3.yml) on branch `spike/s3-s4` and opened [#9](https://github.com/Jomaries777/sandbox-agent-apps/pull/9).

- The workflow mints a `tclaude` token with `actions/create-github-app-token`: `permission-contents: read`, `permission-pull-requests: write` and `permission-issues: write`.
- It runs `claude-code-action` at the pinned `c84e279` (v1.0.284), with `github_token` set to that token and only `mcp__github_inline_comment__create_inline_comment` allowed.
- It sets `classify_inline_comments: "false"`. Otherwise the action holds back inline comments it judges to be tests or probes, and could drop this one.

[Run 46034181365](https://github.com/Jomaries777/sandbox-agent-apps/actions/runs/46034181365) succeeded:

```text
GET /pulls/9/comments  -> jomaries777-tclaude[bot] docs/spike-s3.md:3 "Spike S3: inline comment posted with the jomaries777-tclaude token."
GET /pulls/9/reviews   -> jomaries777-tclaude[bot] COMMENTED
```

**Result: pass.** The spec's `claude-review` token (contents read; pull requests and issues write) is enough for inline comments, and they show the App's own name.

For M2: `claude-review` keeps the default `classify_inline_comments` (true), so real review comments go through the action's filter.

## S4: can a run Dependabot didn't start read the Dependabot secret?

The owner's push of `spike/s3-s4` ran [`spike-s4.yml`](https://github.com/Jomaries777/sandbox-agent-apps/blob/spike/s3-s4/.github/workflows/spike-s4.yml) ([run 46034071648](https://github.com/Jomaries777/sandbox-agent-apps/actions/runs/46034071648), `event: push`, `triggering_actor: Jomaries777`):

```text
actor: Jomaries777
RESULT: CI_APP_PRIVATE_KEY is empty in this run
##[error]The 'private-key' input must be set to a non-empty string. ...
RESULT: mint step outcome: failure (expected: failure)
```

**Result: pass, as expected.** The `-ci` key reaches only Dependabot-started runs (C2). `doctor.sh` still has to fail if `CI_APP_PRIVATE_KEY` is ever set as an Actions secret (FR-10).

## Incidents

- **Wrong PR number in S1.** CC's first `tci` merge call on the failing PR used #7, a Dependabot TypeScript major bump, instead of #8. GitHub refused it because #7's `ci-ok` was failing (rule suite `5413731382`). #7 is unchanged.
- **S2 aimed at the template repo**, described in S2 above.

## Left in the sandbox

- **Still open:** #9 and branch `spike/s3-s4`, kept as evidence. The sandbox's Dependabot PRs are also still open.
- **Removed in M4:** the sandbox and the three throwaway Apps (plan M4).
