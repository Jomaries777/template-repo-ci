#!/usr/bin/env bash
# Summarise an Antigravity (`agy --output-format stream-json`) NDJSON stream.
# Pure jq/bash, no AI. Reads NDJSON on stdin.
#
# Env:
#   AGY_ON_PROGRESS       executable called as `$AGY_ON_PROGRESS <summary.md>` (optional)
#   AGY_THROTTLE_SECONDS  min seconds between progress callbacks (default 30)
#   AGY_SUMMARY_JSON      file for the final JSON summary (default: stdout)
#   AGY_WORKSPACE         workspace root; defaults to the stream's init.cwd
#
# Only counts and file paths are reported; text_delta content is never copied.
# Unknown events/fields and malformed lines are ignored.
set -euo pipefail

throttle="${AGY_THROTTLE_SECONDS:-30}"
workspace="${AGY_WORKSPACE:-}"
out="${AGY_SUMMARY_JSON:-/dev/stdout}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/steps" # unique conv:step keys
: >"$tmp/tools" # unique "conv:step<US>tool" keys
: >"$tmp/files" # repo-relative paths written in the workspace
: >"$tmp/deleg" # unique conv:step keys of delegation calls
: >"$tmp/errors" # unique conv:step keys in state ERROR
status=""
seen_result=0
tokens=0
duration=""
last_cb=0
start_ts="$(date +%s)"
us=$'\037'

count_unique() { sort -u "$1" | grep -c . || true; }

summary_json() {
  local dur="$duration" tools_json files_json
  [[ -n "$dur" ]] || dur=$(($(date +%s) - start_ts))
  tools_json="$(sort -u "$tmp/tools" | awk -F"$us" '{c[$2]++} END {for (k in c) printf "%s\t%d\n", k, c[k]}' |
    jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries')"
  files_json="$(sort -u "$tmp/files" | jq -Rn '[inputs | select(length > 0)]')"
  jq -n \
    --arg status "${status:-NO_RESULT}" \
    --argjson steps "$(count_unique "$tmp/steps")" \
    --argjson tools "$tools_json" \
    --argjson files "$files_json" \
    --argjson deleg "$(count_unique "$tmp/deleg")" \
    --argjson errors "$(count_unique "$tmp/errors")" \
    --argjson tokens "$tokens" \
    --argjson dur "$dur" \
    '{status: $status, steps: $steps, tools: $tools, files_written: $files,
      delegations: $deleg, errors: $errors, total_tokens: $tokens,
      duration_seconds: $dur,
      delegated_without_changes_risk: ($deleg > 0 and ($files | length) == 0)}'
}

summary_md() {
  summary_json | jq -r '
    "**agy status:** \(.status)\n\n- steps: \(.steps)\n- files written: \(.files_written | length)\n- delegations: \(.delegations)\n- errors: \(.errors)\n- tokens: \(.total_tokens)\n- elapsed: \(.duration_seconds | floor)s\n- tools: \(.tools | to_entries | map("\(.key) x\(.value)") | join(", "))"
    + (if .delegated_without_changes_risk then "\n\nWarning: delegated work but no files written in this workspace" else "" end)'
}

progress() {
  [[ -n "${AGY_ON_PROGRESS:-}" ]] || return 0
  local force="${1:-0}" now
  now="$(date +%s)"
  if [[ "$force" != 1 ]] && ((now - last_cb < throttle)); then
    return 0
  fi
  last_cb="$now"
  summary_md >"$tmp/summary.md"
  "$AGY_ON_PROGRESS" "$tmp/summary.md" || true
}

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  rec="$(jq -r --arg us "$us" '
    [ (.event // ""),
      (.step_update.conversation_id // .conversation_id // ""),
      ((.step_update.step_index // "") | tostring),
      (.step_update.state // ""),
      (.step_update.tool_name // ""),
      ((.step_update.tool_info.parameters.Path // .step_update.tool_info.parameters.path // "") | tostring | gsub("[\n\r]"; " ")),
      (.init.cwd // ""),
      (.result.status // ""),
      ((.result.usage.total_tokens // 0) | tostring),
      ((.result.duration_seconds // "") | tostring)
    ] | join($us)' <<<"$line" 2>/dev/null)" || continue
  IFS="$us" read -r ev conv idx state tool path cwd rstatus rtok rdur <<<"$rec" || true
  case "$ev" in
    init)
      [[ -n "$workspace" ]] || workspace="$cwd"
      ;;
    step_update)
      key="$conv:$idx"
      echo "$key" >>"$tmp/steps"
      if [[ -n "$tool" ]]; then
        echo "$key$us$tool" >>"$tmp/tools"
        case "$tool" in
          invoke_subagent | send_message) echo "$key" >>"$tmp/deleg" ;;
        esac
        if [[ "$tool" == "write_file" && -n "$path" ]]; then
          rel=""
          if [[ "$path" != /* ]]; then
            rel="$path"
          elif [[ -n "$workspace" && "$path" == "${workspace%/}/"* ]]; then
            rel="${path#"${workspace%/}"/}"
          fi
          if [[ -n "$rel" ]]; then echo "$rel" >>"$tmp/files"; fi
        fi
      fi
      if [[ "$state" == ERROR ]]; then echo "$key" >>"$tmp/errors"; fi
      progress 0
      ;;
    result)
      seen_result=1
      status="$rstatus"
      tokens="${rtok:-0}"
      duration="$rdur"
      progress 1
      ;;
  esac
done

if [[ "$seen_result" != 1 ]]; then progress 1; fi
summary_json >"$out"
