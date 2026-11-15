---
description: Turn an accepted spec.md into plan.md (run in plan mode)
argument-hint: "[intent folder, e.g. intent/0002-foo]"
---

Write the plan using the `write-plan` skill. Target: $ARGUMENTS (default: the newest folder under `intent/`).

1. Read `spec.md` in that folder. If it is not accepted, stop and tell the owner.
2. Draft `plan.md` with exactly these headings: Files that change, Order of work, Risks, Proof (add Deviations once work starts).
3. In Order of work, number the steps and mark each as `serial` or `independent`. Independent steps can run as parallel worktree sessions (up to 3 at once); say which files each one owns so they do not overlap.
4. Every Proof item must be checkable by a command (`make ...`, a script, a `gh` query), and map back to a spec acceptance criterion.
5. Show the plan to the owner for acceptance before any code is written.
