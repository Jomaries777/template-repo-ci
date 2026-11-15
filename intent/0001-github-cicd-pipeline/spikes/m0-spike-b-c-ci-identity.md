# Spikes B and C: Claude Pro token in CI, and bot identity

**Date**: 2026-11-15 · **Throwaway PR**: Jomaries777/template-repo-ci#2 (closed without merging)

## Spike B: `claude-code-action` on the owner's Claude Pro token (Decision 4, C7)

| Attempt | Result | Cause |
|---|---|---|
| 1 | ❌ `is_error: true` after 1 turn and 2 s, no model usage. The public repo hides the full output by default. | Unknown until attempt 2 |
| 2 (`show_full_output: true`) | ❌ `401 OAuth access token is invalid` | **The secret held a truncated token.** `claude setup-token` wraps the token across two terminal lines, and the `gh secret set` prompt takes only the first line. |
| 3 (secret re-set with whitespace stripped) | ✅ 2 turns, comment posted by `github-actions[bot]`, `api_error_status: null` | — |

**Findings**
1. **The setup-token path works on Claude Pro.** The user-reported 401s may be this same truncation problem.
2. **Always store the token with whitespace stripped:**
   ```bash
   pbpaste | tr -d '[:space:]' | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <owner>/<repo>
   ```
   The README (FR-14) and `make doctor` (FR-15) must use this form. `doctor` should also run a 1-turn smoke check that turns a 401 into a "re-set the token" hint.
3. **On public repos, failures are opaque** without `show_full_output`. `claude-review` keeps it **off**, because tool output could expose data. On failure the job comments "Claude review failed (auth or quota); re-run with debug", and `ci-ok` is never blocked (C7).
4. Cost shown: `total_cost_usd: 0.03`. This is notional on a subscription; the run drew on the Pro limit, not on paid API usage.

## Spike C: bot App token, check runs and comments (Decision 2, Decision 5, C5)

| Step | Result |
|---|---|
| `scripts/bot-token.sh` (Keychain key → JWT → installation token) | ✅ a `ghs_…` token, valid 1 hour, that can see only `template-repo-ci` |
| `POST /check-runs` as the bot (`antigravity/boost`, `in_progress`) | ✅ created, `app.slug = jomaries777-agent-bot` |
| `PATCH` to `completed` / `success` | ✅ |
| `gh pr comment` as the bot | ✅ posted by `jomaries777-agent-bot[bot]` |

**Findings**
1. Everything §4.8 needs from the bot identity works: check-run lifecycle plus PR comments.
2. **The App has no `workflows` permission**, so the bot **cannot push changes under `.github/workflows/`**. This is kept as a guardrail: agents running as the bot can't change CI. Workflow changes come from the owner's own PRs (C4 bypass), or from Claude Code sessions running as the owner while the owner watches. This is enforced by GitHub, not by an advisory skill.
3. `scripts/bot-token.sh` is macOS-only by design (Keychain). In CI, `actions/create-github-app-token` with `BOT_APP_PRIVATE_KEY` does the same job (the Dependabot approve workflow, C1).
