#!/usr/bin/env bash
# Set one App key's repo secret through the bot token broker, so the key never
# touches this device (spec 0002 FR-8; spec 0003 FR-4, C2). Used by
# bootstrap.sh and for key rotation (broker/README.md).
#
# Usage:  scripts/bot-secrets.sh --key <claude|ci> [--dry-run] owner/repo...
#
# Each key has one fixed target, chosen by the broker, never by the caller:
#   --key claude  -> Actions secret CLAUDE_APP_PRIVATE_KEY (Claude in CI)
#   --key ci      -> Dependabot secret CI_APP_PRIVATE_KEY (dependabot-automerge)
# Run it once per key. There is no key for agy: its key lives only in the broker.
#
# Needs a signed-in device (scripts/bot-login.sh: identity + broker URL) and a
# GitHub CLI login of the owner (`gh auth token`), which may set repo secrets.
# The broker checks that token belongs to the owner, reads each repo's public
# key itself, seals the key and sets the secret. Both credentials go to the
# broker in headers read from pipes (never in a command line), https only.
set -euo pipefail

config_dir="${BOT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-bot}"
die() {
  echo "bot-secrets: $*" >&2
  exit 1
}
usage() {
  echo "usage: scripts/bot-secrets.sh --key <claude|ci> [--dry-run] owner/repo..." >&2
  exit 64
}

key="" dry_run=0 repos=()
while (($#)); do
  case "$1" in
    --key) [[ $# -ge 2 ]] || usage; key="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) repos+=("$1"); shift ;;
  esac
done
case "$key" in
  claude) target="CLAUDE_APP_PRIVATE_KEY (actions)" ;;
  ci) target="CI_APP_PRIVATE_KEY (dependabot)" ;;
  *) usage ;;
esac
((${#repos[@]})) || usage
for repo in "${repos[@]}"; do
  [[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "give repos as owner/name, not $repo"
done

broker_url="${BOT_BROKER_URL:-$(cat "$config_dir/broker_url" 2>/dev/null || true)}"
[[ -n "$broker_url" && -s "$config_dir/identity" ]] ||
  die "this device isn't signed in to the broker: run scripts/bot-login.sh --broker <url>"
[[ "$broker_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || die "the broker URL must be https://host, not $broker_url"

if ((dry_run)); then
  for repo in "${repos[@]}"; do echo "DRY-RUN: broker /secrets --key $key: $target for $repo"; done
  exit 0
fi

gh_token="$(gh auth token 2>/dev/null)" || true
[[ -n "$gh_token" ]] || die "no GitHub CLI login: run gh auth login as the owner (an account that can set the repos' secrets)"

for repo in "${repos[@]}"; do
  code="" body=""
  if reply="$(curl -sS --max-time 30 -X POST \
    -H @<(printf 'Authorization: Bearer %s\nX-GitHub-Token: %s\n' "$(cat "$config_dir/identity")" "$gh_token") \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg r "$repo" --arg k "$key" '{repo: $r, key: $k}')" \
    -w '\n%{http_code}' "${broker_url%/}/secrets")"; then
    code="${reply##*$'\n'}"
    body="${reply%$'\n'*}"
  fi
  if [[ "$code" != 200 ]]; then
    error="$(jq -r '.error // "unknown"' <<<"$body" 2>/dev/null || echo unknown)"
    case "$error" in
      github_token_not_owner) hint="gh is logged in as another account; log in as the owner" ;;
      github_denied) hint="the gh login can't set this repo's secrets (it needs admin or the secrets scope)" ;;
      no_token | bad_token) hint="sign in again with scripts/bot-login.sh" ;;
      bad_apps) hint="this broker predates --key; it is updated at the intent 0003 cutover (broker/README.md)" ;;
      bad_key) hint="the broker doesn't know the key $key" ;;
      not_found) hint="the repo doesn't exist, or the gh login can't see it" ;;
      missing_key) hint="the broker has no $key App key loaded (broker/README.md)" ;;
      *) hint="" ;;
    esac
    die "the broker refused $repo: $error (HTTP ${code:-no answer})${hint:+; $hint}"
  fi
  done_msg="$(jq -er '"\(.secret | strings) set (\(.app | strings))"' <<<"$body" 2>/dev/null)" ||
    die "the broker answered 200 for $repo without naming the secret it set"
  echo "bot-secrets: $repo: $done_msg"
done
unset gh_token
