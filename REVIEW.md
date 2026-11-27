# REVIEW.md

Review rubric for the automated Claude review. Findings are advisory.

## Review passes

1. **Correctness**: bugs, wrong logic, unhandled errors, edge cases, race conditions.
2. **Security**: secrets in code or logs, injection (shell, SQL, template), unsafe deserialization, missing authn/authz, workflow permissions broader than needed, untrusted input in `run:` steps. Cover the OWASP basics.
3. **Conformance**: does the diff match `spec.md` and the "Files that change" list in `plan.md`? Flag files changed outside the plan and planned files left untouched. A new project has no `intent/NNNN-*/` folder until its first intent (bootstrap removes the template's). When the repo has none, skip this pass and don't flag the missing folder.
4. **Test adequacy**: new behavior has a test that would fail without the change; tests assert outcomes, not implementation.
5. **Cost**: new always-on resources, jobs without `timeout-minutes`, unbounded loops or retries, workflows that run on every push without path filters, missing "$0 when idle" for deploy targets.

## Severity

- **Important**: likely bug, security issue, spec or plan violation, missing test for new behavior, cost risk. Must be read before merge.
- **Nit**: style or minor improvement. At most 5 nits; drop the rest.

## Skip

Generated files, lockfiles, and anything lint or CI already enforces (formatting, shellcheck, actionlint, markdownlint, type errors).

## Claude-built PRs (C6)

The agent that wrote the code cannot approve it. When the PR was built by Claude or the bot, check the `spec.md` / `plan.md` match harder: compare the diff to "Files that change" and "Proof" line by line, and look for claims in the PR body that the diff does not support.

## Output format

Post a single comment. Its first line is the hidden marker `<!-- claude-review -->`. Then findings grouped by severity (Important first, then Nit), each with `file:line` and a one-line fix suggestion. If there are no findings, say so in one sentence.

End with: "These findings are advisory. This review never approves or requests changes; only the owner approves."
