#!/usr/bin/env bash
# Render one GitHub App manifest from scripts/bot-app-manifest.json (spec 0003
# FR-1, C9), or print only the App's name.
#
# Usage:  scripts/app-manifest.sh [--name] <login> <claude|agy|ci>
#
# The name is <login>-<agent> in lower case, which is also the App's slug.
# GitHub limits App names to 34 characters, so a login over 27 characters is
# cut to 27 for all three Apps (they keep one shared prefix, and "-claude"
# still fits), and hyphens left at the end of the cut are dropped. The agent
# name is never cut. bootstrap.sh calls --name instead of copying this rule.
#
# claude and agy get the agent permissions; ci gets the narrower ci set. None
# of them gets workflows, administration or secrets.
set -euo pipefail

usage() {
  echo "usage: scripts/app-manifest.sh [--name] <login> <claude|agy|ci>" >&2
  exit 64
}

name_only=0
if [[ "${1:-}" == --name ]]; then
  name_only=1
  shift
fi
[[ $# -eq 2 ]] || usage
login="$1" agent="$2"
[[ "$login" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || usage # a GitHub login
case "$agent" in claude | agy | ci) ;; *) usage ;; esac

prefix="$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')"
prefix="${prefix:0:27}"
while [[ "$prefix" == *- ]]; do prefix="${prefix%-}"; done
[[ -n "$prefix" ]] || usage
name="$prefix-$agent"

if ((name_only)); then
  printf '%s\n' "$name"
  exit 0
fi

role=agent
[[ "$agent" == ci ]] && role=ci
template="$(dirname "${BASH_SOURCE[0]}")/bot-app-manifest.json"
jq --arg name "$name" --arg agent "$agent" --arg role "$role" '
  .labels[$agent] as $label
  | .permissions[$role] as $perms
  | .manifest
  | .name = $name
  | .description |= sub("<agent-label>"; $label)
  | .default_permissions = $perms
' "$template"
