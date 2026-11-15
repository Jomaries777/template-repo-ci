---
description: Turn an accepted intent.md into spec.md
argument-hint: "[intent folder, e.g. intent/0002-foo]"
---

Write the spec using the `write-spec` skill. Target: $ARGUMENTS (default: the newest folder under `intent/`).

1. Read `intent.md` in that folder. If its Status is not Accepted, stop and tell the owner.
2. Draft `spec.md` beside it: requirements tables (FR/NFR, each citing the intent section), design, flagged-conflicts table, acceptance criteria.
3. Check the design against the repo's policies (CLAUDE.md, REVIEW.md, branch rules, hooks). Every clash goes in the flagged-conflicts table with columns: Concern, Conflict, Proposed decision. Do not resolve them yourself.
4. Present the conflicts table to the owner and wait for decisions. Record the decisions in the table, then ask the owner to accept the spec.
