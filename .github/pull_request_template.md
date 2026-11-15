<!-- markdownlint-disable-file MD041 -- PR bodies start at h2; GitHub shows the title above. -->
## What and why

<!-- One or two sentences. The title must be a conventional commit, e.g. `feat(api): add /healthz`. -->

## Intent

<!-- Link the intent folder this change belongs to. Use "n/a" only for chores (dependency bumps, typo fixes). -->

- Intent: `intent/NNNN-<slug>/intent.md`
- Spec: `intent/NNNN-<slug>/spec.md`
- Plan: `intent/NNNN-<slug>/plan.md` (milestone / step: )

## Proof

- [ ] `make lint test` is green locally
- [ ] New or changed behaviour has tests
- [ ] `plan.md` is updated in this PR if the implementation diverged from it (Deviations table)
- [ ] No secrets, tokens or `.env` files in the diff

## Review

`ci-ok` is the only required check. The Claude review comment is **advisory**: it never approves or blocks. The owner reads it before approving. Comment `@claude review` to ask for another review after the automatic limit (3 per PR).
