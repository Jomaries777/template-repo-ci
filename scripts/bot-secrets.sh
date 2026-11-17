#!/usr/bin/env bash
# Set the BOT_APP_PRIVATE_KEY repo secrets (Actions and Dependabot) through the
# bot token broker, so the App key never touches this device (spec 0002 FR-8,
# C4). Used by bootstrap.sh and for key rotation (broker/README.md).
#
# Usage:  scripts/bot-secrets.sh [--apps actions,dependabot] [--dry-run] owner/repo...
#
# Needs a signed-in device (scripts/bot-login.sh: identity + broker URL) and a
# GitHub CLI login of the owner (`gh auth token`), which may set repo secrets.
# The broker checks that token belongs to the owner, reads each repo's public
# key itself, seals the key and sets the secrets. Both credentials go to the
# broker in headers read from pipes (never in a command line), https only.
set -euo pipefail

config_dir="${BOT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-bot}"
die() {
  echo "bot-secrets: $*" >&2
  exit 1
}
usage() {
  echo "usage: scripts/bot-secrets.sh [--apps actions,dependabot] [--dry-run] owner/repo..." >&2
  exit 64
}

apps="actions,dependabot" dry_run=0 repos=()
while (($#)); do
  case "$1" in
    --apps) [[ $# -ge 2 ]] || usage; apps="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) repos+=("$1"); shift ;;
  esac
done
((${#repos[@]})) || usage
[[ "$apps" =~ ^(actions|dependabot)(,(actions|dependabot))?$ ]] || die "--apps takes actions, dependabot or both"
for repo in "${repos[@]}"; do
  [[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "give repos as owner/name, not $repo"
done

broker_url="${BOT_BROKER_URL:-$(cat "$config_dir/broker_url" 2>/dev/null || true)}"
[[ -n "$broker_url" && -s "$config_dir/identity" ]] ||
  die "this device isn't signed in to the broker: run scripts/bot-login.sh --broker <url>"
[[ "$broker_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || die "the broker URL must be https://host, not $broker_url"

if ((dry_run)); then
  for repo in "${repos[@]}"; do echo "DRY-RUN: broker /secrets BOT_APP_PRIVATE_KEY for $repo (${apps//,/, })"; done
  exit 0
fi

gh_token="$(gh auth token 2>/dev/null)" || true
[[ -n "$gh_token" ]] || die "no GitHub CLI login: run gh auth login as the owner (an account that can set the repos' secrets)"

apps_json="$(jq -nc --arg a "$apps" '$a | split(",")')"
for repo in "${repos[@]}"; do
  code=""
  if reply="$(curl -sS --max-time 30 -X POST \
    -H @<(printf 'Authorization: Bearer %s\nX-GitHub-Token: %s\n' "$(cat "$config_dir/identity")" "$gh_token") \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg r "$repo" --argjson a "$apps_json" '{repo: $r, apps: $a}')" \
    -w '\n%{http_code}' "${broker_url%/}/secrets")"; then
    code="${reply##*$'\n'}"
    body="${reply%$'\n'*}"
  fi
  if [[ "$code" != 200 ]]; then
    error="$(jq -r '.error // "unknown"' <<<"${body:-}" 2>/dev/null || echo unknown)"
    case "$error" in
      github_token_not_owner) hint="gh is logged in as another account; log in as the owner" ;;
      github_denied) hint="the gh login can't set this repo's secrets (it needs admin or the secrets scope)" ;;
      no_token | bad_token) hint="sign in again with scripts/bot-login.sh" ;;
      *) hint="" ;;
    esac
    partial="$(jq -r '(.set // []) | join(", ")' <<<"${body:-}" 2>/dev/null || true)"
    [[ -z "$partial" ]] || echo "bot-secrets: $repo: BOT_APP_PRIVATE_KEY was already set for $partial before the error; rerun to finish" >&2
    die "the broker refused $repo: $error (HTTP ${code:-no answer})${hint:+; $hint}"
  fi
  echo "bot-secrets: $repo: BOT_APP_PRIVATE_KEY set for $(jq -r '.set | join(", ")' <<<"$body")"
done
unset gh_token
