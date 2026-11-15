#!/usr/bin/env bash
# PostToolUse hook (Edit|Write|MultiEdit): format then lint the edited file.
# Input: hook JSON on stdin (tool_input.file_path, absolute or relative to
# $CLAUDE_PROJECT_DIR).
# Exit 0 = fine. Exit 2 = lint errors; output goes to stderr so Claude sees
# and fixes them. Scoped to the one changed file to stay fast.
set -euo pipefail
command -v jq >/dev/null || { echo "BLOCKED: Claude Code hooks need jq (brew install jq)." >&2; exit 2; }

path="$(jq -r '.tool_input.file_path // empty')"
[[ -n "$path" ]] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$PWD}"
[[ -f "$path" ]] || exit 0

make fmt FILE="$path" >&2 || true

if ! out="$(make lint FILE="$path" 2>&1)"; then
  printf 'make lint FILE=%s failed:\n%s\n' "$path" "$out" >&2
  exit 2
fi
exit 0
