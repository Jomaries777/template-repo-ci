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
#
# Broker guard (spec 0004 C10, amended at planning): on Bash only, a command
# word in command position (line start, or after ; & | ( ` with optional
# VAR=x, env, exec, command, bash or sh before it) is blocked when it runs
#   gcloud secrets versions access,
#   broker/setup.sh, broker/put-secret.sh or broker/deploy.sh, or
#   gcloud, gsutil or bq while the command names agent-bot-broker.
# Claude's Bash may share the owner's gcloud login, so the owner runs every
# broker-project command. Mentions (make lint FILE=broker/setup.sh, git add,
# curl to the service URL) pass. A guard on what Claude types, not a sandbox:
# a script that runs gcloud on its own isn't seen.
set -euo pipefail
command -v jq >/dev/null || { echo "BLOCKED: Claude Code hooks need jq (brew install jq)." >&2; exit 2; }

input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
if [[ -n "$cmd" ]]; then
  pre='(^|[;&|(`])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((env|exec|command|bash|sh)[[:space:]]+)*'
  why=""
  if grep -Eq -- "${pre}gcloud[[:space:]]+secrets[[:space:]]+versions[[:space:]]+access" <<<"$cmd"; then
    why="it reads a secret value (gcloud secrets versions access)"
  elif grep -Eq -- "${pre}([^[:space:];&|()\`]*/)?broker/(setup|put-secret|deploy)\.sh" <<<"$cmd"; then
    why="it runs a broker owner script"
  elif grep -q -- 'agent-bot-broker' <<<"$cmd" && grep -Eq -- "${pre}(gcloud|gsutil|bq)([[:space:]]|\$)" <<<"$cmd"; then
    why="it runs gcloud, gsutil or bq against the broker project"
  fi
  if [[ -n "$why" ]]; then
    {
      echo "BLOCKED by no-secrets: $why."
      echo "The owner runs broker-project commands in their own terminal and pastes the output (broker/README.md)."
    } >&2
    exit 2
  fi
fi

content="$(jq -r '[.tool_input.content, .tool_input.new_string, .tool_input.command, (.tool_input.edits[]?.new_string)] | map(select(. != null)) | join("\n")' <<<"$input")"
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
