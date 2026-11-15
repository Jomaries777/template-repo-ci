---
name: write-spec
description: Use when an intent.md has been accepted and a design is needed, or when asked to "write a spec" or "design this". Produces spec.md next to the intent with requirements, design, flagged conflicts and acceptance criteria.
---

# write-spec

Turn an accepted intent into a design the owner can accept.

Enforced by: owner review against `REVIEW.md`. A `hygiene` check for a spec before `src/` changes is planned, not built yet. This skill is advisory.

## Checklist

- [ ] intent.md Status is Accepted. If not, stop.
- [ ] Every requirement cites the intent section it serves.
- [ ] Every design choice that clashes with a repo policy is in the flagged-conflicts table, not silently resolved.
- [ ] Acceptance criteria are checkable by a command or a `gh` query, and become the "Proof" for `plan.md`.
- [ ] Cost: states what runs always-on (target: nothing) and quota used.

## Template

```markdown
# Spec: <title>

| Field | Value |
|---|---|
| Status | Draft |
| Intent | [intent.md](intent.md) |

## Requirements

### Functional

| ID | Requirement | Intent ref |
|---|---|---|
| FR-1 | ... | Problem 1 |

### Non-functional

| ID | Requirement | Intent ref |
|---|---|---|
| NFR-1 | ... | Constraints |

## Design

<Components, data flow, key files, decisions and why. Diagrams only if they clarify.>

## Flagged concerns and policy conflicts

| # | Concern | Conflict | Decision (owner fills in) |
|---|---|---|---|
| C1 | ... | ... | |

## Acceptance criteria

1. <Observable, command-checkable statement>
```
