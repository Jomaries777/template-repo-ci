---
name: write-plan
description: Use when a spec.md has been accepted and implementation is about to start, or when asked to "write a plan", "break this down" or "plan the build". Produces plan.md; run in plan mode.
---

# write-plan

Turn an accepted spec into an ordered, verifiable build plan.

Enforced by: the `pr_template` checkbox and the `verifier` subagent, which checks the diff against this file. This skill is advisory.

## Checklist

- [ ] spec.md is Accepted. If not, stop.
- [ ] "Files that change" lists every file, marked new or modified. Anything outside it is a deviation.
- [ ] Each step in "Order of work" is marked `serial` or `independent`, with the files it owns. Independent steps may run as parallel worktree sessions (up to 3).
- [ ] Each "Proof" item is a command and expected result, mapped to a spec acceptance criterion.
- [ ] Risks name a mitigation.

## Template

```markdown
# Plan: <title>

| Field | Value |
|---|---|
| Status | Draft |
| Spec | [spec.md](spec.md) |

## Files that change

| File | New/Modified | Why |
|---|---|---|

## Order of work

1. <step> (serial)
2. <step> (independent; owns: <files>)

## Risks

| Risk | Mitigation |
|---|---|

## Proof

| Check | Command | Expected | Spec criterion |
|---|---|---|---|
| Lint and tests | `make lint test` | exit 0 | all |

## Deviations

<Added during build: what changed from this plan, why, who approved.>
```
