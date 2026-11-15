---
name: write-intent
description: Use when brainstorming a new change, feature, project or fix, or when asked to "write an intent", "capture the idea" or start from an issue. Produces intent/<id>-<slug>/intent.md. Interactive only.
---

# write-intent

Capture why a change exists before any design. The owner decides; you interview and draft.

Enforced by: the PR template check (an `intent/` link is required). This skill is advisory.

## Steps

1. Interview first (one or two questions at a time). Do not draft until you know the problem and the desired outcome.
2. Choose the next free `<id>` (four digits) and a short kebab-case `<slug>`; create `intent/<id>-<slug>/intent.md`.
3. Write the template below. Keep it plain and short; no solution design (that belongs in `spec.md`).
4. Leave Status as Draft until the owner accepts.

## Template

```markdown
# Intent: <title>

| Field | Value |
|---|---|
| Status | Draft |
| Product owner | <name or role> |
| Created | <YYYY-MM-DD> |
| SDLC stage | Stage 1, Plan: "Capture as intent.md" |
| Framework | The AI-native SDLC playbook |
| Next artifact | `spec.md` in this folder, written only after this file is accepted and committed |

## Problem

<What hurts today, for whom, with evidence.>

## Proposed outcome

<What is true when this succeeds. Observable, not a design.>

## Affected users and systems

<Who and what changes.>

## Constraints

<Budget, quota, policy, deadlines, tools that must or must not be used.>

## Open questions

<Numbered; each with an owner for the answer.>
```
