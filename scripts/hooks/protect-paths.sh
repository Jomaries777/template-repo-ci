#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|MultiEdit): block edits to protected paths.
# Blocked: .github/rulesets/**, lockfiles (change them via the package
# manager), and generated dirs dist/ build/ coverage/.
# Input: hook JSON on stdin. Exit 2 blocks and shows stderr to Claude.
set -euo pipefail
command -v jq >/dev/null || { echo "BLOCKED: Claude Code hooks need jq (brew install jq)." >&2; exit 2; }

path="$(jq -r '.tool_input.file_path // empty')"
[[ -n "$path" ]] || exit 0

block() {
  printf 'BLOCKED by protect-paths: %s\n%s\n' "$path" "$1" >&2
  exit 2
}

case "/$path" in
  */.github/rulesets/*)
    block "Rulesets are owner-managed config. Open an owner PR instead." ;;
esac

case "/$path" in
  */.github/workflows/*)
    # The bot App cannot push workflows anyway; fail early. The owner can
    # set ALLOW_WORKFLOW_EDIT=1 in an interactive session they are watching.
    [[ "${ALLOW_WORKFLOW_EDIT:-}" == "1" ]] ||
      block "Workflow changes come from owner PRs (set ALLOW_WORKFLOW_EDIT=1 to override)." ;;
esac

case "$(basename "$path")" in
  package-lock.json | pnpm-lock.yaml | yarn.lock | poetry.lock | uv.lock | go.sum)
    block "Lockfiles change only through the package manager (npm/pnpm/yarn/poetry/uv/go)." ;;
esac

case "/$path" in
  */dist/* | */build/* | */coverage/*)
    block "Generated directory. Edit the source and regenerate." ;;
esac
exit 0
