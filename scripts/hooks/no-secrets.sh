#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|MultiEdit|Bash): block content containing secrets.
# Scans tool_input.content, new_string, edits[].new_string and (for Bash)
# tool_input.command. High-confidence patterns: private keys, GitHub tokens
# (ghs_/ghp_/gho_/github_pat_), Anthropic keys (sk-ant-), AWS access keys.
# Generic rule: password/secret/token/api_key assigned a QUOTED literal of
# 8+ chars. References (process.env.X, os.environ[..], ${..}, $(..),
# ${{ secrets.X }}, secrets.X, env.X) are not flagged.
# Trade-off: literals containing $ { } ( ) are not flagged, and a Bash command
# that merely mentions a token pattern (e.g. grep) is blocked.
# Exit 2 blocks and shows stderr to Claude. CI's gitleaks job is the backstop.
set -euo pipefail
command -v jq >/dev/null || { echo "BLOCKED: Claude Code hooks need jq (brew install jq)." >&2; exit 2; }

content="$(jq -r '[.tool_input.content, .tool_input.new_string, .tool_input.command, (.tool_input.edits[]?.new_string)] | map(select(. != null)) | join("\n")')"
[[ -n "$content" ]] || exit 0

patterns=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '(ghs|ghp|gho)_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'sk-ant-[A-Za-z0-9_-]{10,}'
  '(AKIA|ASIA)[0-9A-Z]{16}'
)
# Quoted literal of 8+ chars with no reference syntax inside.
generic='(password|passwd|secret|api_?key|token)[[:space:]]*[:=][[:space:]]*("[^"$`{}()]{8,}"|'\''[^'\''$`{}()]{8,}'\'')'

hit=""
for p in "${patterns[@]}" "$generic"; do
  if printf '%s' "$content" | grep -Eiq -- "$p"; then
    hit="$p"
    break
  fi
done

if [[ -n "$hit" ]]; then
  {
    echo "BLOCKED by no-secrets: the content looks like it contains a secret."
    echo "Matched pattern: $hit"
    echo "Use an environment variable or secret manager and reference it by name."
  } >&2
  exit 2
fi
exit 0
