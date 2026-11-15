---
name: secure-change
description: Use when editing authentication, authorization, input handling, secrets, credentials, workflows, or infrastructure-as-code. Security checklist to run before committing.
---

# secure-change

Skills are advisory; the enforcement column says what actually blocks a bad change.

| Check | Enforced by |
|---|---|
| No secret, key or token in code, config, logs or tests; read from env or a secret manager | `no-secrets` hook (edit time); `secrets` job (gitleaks) in CI |
| Untrusted input is validated at the boundary and never concatenated into shell, SQL or templates | `codeql` job; `REVIEW.md` security pass |
| New or updated dependencies come from a package manager, not hand-edited lockfiles | `protect-paths` hook; `dependency-review` job |
| Authn and authz checked on every new entry point; default deny | `codeql` job; `REVIEW.md` security pass |
| Workflow `permissions:` minimal, actions pinned to a SHA, no untrusted input in `run:` | `actionlint` in `make lint`; `REVIEW.md` security pass |
| Cloud IAM least privilege; keyless auth (OIDC) where the target supports it | `REVIEW.md` security and cost passes |
| Errors do not leak internals or secrets to users | `REVIEW.md` correctness pass |

Before committing: run `make lint test`, then look at `git diff` once for anything that should not be there.
