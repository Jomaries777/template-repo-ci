#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|MultiEdit): enforce test-first on fix/* branches.
# Rule: on a branch named fix/*, edits to test files are blocked, so the
# failing test is written and committed first (by the owner, or by rerunning
# with ALLOW_TEST_EDIT=1 for that step). Test files: anything under tests/,
# *_test.*, *.test.*, test_*.py.
# Exit 2 blocks and shows stderr to Claude.
set -euo pipefail

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

if [[ "$is_test" == 1 ]]; then
  {
    echo "BLOCKED by test-first: $path is a test file and the branch is $branch."
    echo "On fix/* branches the failing test is written and committed first."
    echo "Fix the code instead, or ask the owner to rerun with ALLOW_TEST_EDIT=1."
  } >&2
  exit 2
fi
exit 0
