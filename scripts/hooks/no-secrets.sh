#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|MultiEdit): block content containing secrets.
# Scans tool_input.content, new_string and edits[].new_string with regexes:
# private keys, GitHub tokens (ghs_/ghp_/gho_/github_pat_), Anthropic keys
# (sk-ant-), AWS access keys, and password=/secret=/token=/api_key=
# assignments with a literal value.
# Exit 2 blocks and shows stderr to Claude. CI's gitleaks job is the backstop.
set -euo pipefail

content="$(jq -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits[]?.new_string)] | map(select(. != null)) | join("\n")')"
[[ -n "$content" ]] || exit 0

patterns=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '(ghs|ghp|gho)_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'sk-ant-[A-Za-z0-9_-]{10,}'
  '(AKIA|ASIA)[0-9A-Z]{16}'
  '(password|passwd|secret|api_?key|token)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9/+_.-]{8,}'
)

for p in "${patterns[@]}"; do
  if printf '%s' "$content" | grep -Eiq -- "$p"; then
    {
      echo "BLOCKED by no-secrets: the new content looks like it contains a secret."
      echo "Matched pattern: $p"
      echo "Use an environment variable or secret manager and reference it by name."
    } >&2
    exit 2
  fi
done
exit 0
