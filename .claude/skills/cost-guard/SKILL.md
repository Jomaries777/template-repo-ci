---
name: cost-guard
description: Use when adding any cloud resource, deploy target, workflow, scheduled job or paid API call. Checklist to keep an idle project at $0.
---

# cost-guard

Deterministic first: if a script can decide it, do not spend AI quota on it. Skills are advisory; the enforcement column says what actually catches a miss.

| Check | Enforced by |
|---|---|
| Every workflow job sets `timeout-minutes` | `REVIEW.md` cost pass (no script check yet) |
| Workflows are path-filtered or skipped for docs-only changes; no work on every push | `classify.sh` and the `ci-ok` gate; `REVIEW.md` cost pass |
| Cloud resources scale to zero (min instances 0) and have a max cap | `REVIEW.md` cost pass; adapter `bootstrap` sets caps |
| Budget alert configured wherever the target can bill | adapter `bootstrap`; `make doctor` |
| `target.yml` contains a "$0 when idle" statement | `REVIEW.md` cost pass |
| No loop, retry or poll without a bound | `REVIEW.md` cost pass |
| Claude review uses Pro quota only: max 3 auto reviews per PR, no API-key fallback | `claude-review` quota guards |
| Artifacts and images have retention or cleanup policies | `REVIEW.md` cost pass |

If a check cannot be met, write the reason in the PR body so the owner sees the cost trade-off.
