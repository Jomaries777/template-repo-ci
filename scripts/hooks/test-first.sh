#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|MultiEdit): enforce test-first on fix/* branches.
# Rule: on a branch named fix/*, test-file edits are allowed until the branch
# has at least one commit beyond the merge-base with origin/main (or main).
# After that (the failing test is committed), test-file edits are blocked
# unless ALLOW_TEST_EDIT=1. Test files: anything under tests/, *_test.*,
# *.test.*, test_*.py.
# Test overrides: TEST_FIRST_BRANCH, TEST_FIRST_COMMITS_AHEAD.
# Exit 2 blocks and shows stderr to Claude.
set -euo pipefail
command -v jq >/dev/null || { echo "BLOCKED: Claude Code hooks need jq (brew install jq)." >&2; exit 2; }

path="$(jq -r '.tool_input.file_path // empty')"
[[ -n "$path" ]] || exit 0
[[ "${ALLOW_TEST_EDIT:-}" == "1" ]] && exit 0

branch="${TEST_FIRST_BRANCH:-$(git branch --show-current 2>/dev/null || true)}"
[[ "$branch" == fix/* ]] || exit 0

base="$(basename "$path")"
is_test=0
case "/$path" in */tests/*) is_test=1 ;; esac
case "$base" in
  *_test.* | *.test.* | test_*.py) is_test=1 ;;
esac
[[ "$is_test" == 1 ]] || exit 0

ahead="${TEST_FIRST_COMMITS_AHEAD:-}"
if [[ -z "$ahead" ]]; then
  ref=origin/main
  git rev-parse --verify -q "$ref" >/dev/null || ref=main
  if mb="$(git merge-base HEAD "$ref" 2>/dev/null)"; then
    ahead="$(git rev-list --count "$mb..HEAD" 2>/dev/null || echo 0)"
  else
    ahead=0
  fi
fi

if [[ "$ahead" -ge 1 ]]; then
  {
    echo "BLOCKED by test-first: $path is a test file and $branch already has $ahead commit(s)."
    echo "The failing test was committed first; fix the code instead."
    echo "The owner can rerun with ALLOW_TEST_EDIT=1."
  } >&2
  exit 2
fi
exit 0
