#!/usr/bin/env bash
# Get a 1-hour installation token for one agent's GitHub App from the bot
# token broker (spec 0002; spec 0003 FR-5, D6, C5).
#
# Usage:  GH_TOKEN="$(scripts/bot-token.sh --agent claude [owner/repo])" gh pr create ...
#         scripts/bot-token.sh --agent agy --json [owner/repo]
#
# --agent    required: claude (Claude Code sessions) or agy (Antigravity, via
#            scripts/agy-run.sh). The -ci App has no device tokens.
# --json     print the broker's answer, {token, expires_at, login, id}, instead
#            of the bare token; login and id give the git author. A broker from
#            before the intent 0003 cutover leaves them null.
#
# The broker is the only source: this device holds no App key. It needs a
# signed-in device (scripts/bot-login.sh): a broker URL (BOT_BROKER_URL, or
# the file ~/.config/agent-bot/broker_url) and ~/.config/agent-bot/identity.
# If the broker is down, its kill switch is on, or it refuses, this fails and
# says so; nothing else is tried (C5). In GitHub Actions use
# actions/create-github-app-token instead.
#
# The token is printed to stdout and nothing else. The identity is sent in a
# header read from a pipe, so it never appears in a command line (curl -H
# @file needs curl 7.55 or later), and only over https.
set -euo pipefail

config_dir="${BOT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-bot}"
die() {
  echo "bot-token: $*" >&2
  exit 1
}
usage() {
  echo "usage: scripts/bot-token.sh --agent <claude|agy> [--json] [owner/repo]" >&2
  exit 64
}

agent="" json=0 repo=""
while (($#)); do
  case "$1" in
    --agent) [[ $# -ge 2 ]] || usage; agent="$2"; shift 2 ;;
    --json) json=1; shift ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) [[ -z "$repo" ]] || usage; repo="$1"; shift ;;
  esac
done
case "$agent" in claude | agy) ;; *) usage ;; esac

broker_url="${BOT_BROKER_URL:-$(cat "$config_dir/broker_url" 2>/dev/null || true)}"
[[ -n "$broker_url" && -s "$config_dir/identity" ]] ||
  die "this device isn't signed in to the broker: run scripts/bot-login.sh --broker <url>"
[[ "$broker_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] ||
  die "the broker URL must be https://host; not sending the identity to $broker_url"
[[ -n "$repo" ]] || repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
# The full owner/name goes to the broker, which refuses any other owner.
[[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "give the repo as owner/name, not $repo"

code="" body=""
if reply="$(curl -sS --max-time 15 -X POST \
  -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$config_dir/identity")") \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg r "$repo" --arg a "$agent" '{repo: $r, agent: $a}')" \
  -w '\n%{http_code}' \
  "${broker_url%/}/token")"; then
  code="${reply##*$'\n'}"
  body="${reply%$'\n'*}"
fi
if [[ "$code" == 200 ]]; then
  jq -e '.token | type == "string" and length > 0' >/dev/null 2>&1 <<<"$body" ||
    die "the broker answered 200 without a token"
  if ((json)); then
    jq -c '{token, expires_at, login, id}' <<<"$body"
  else
    jq -r '.token' <<<"$body"
  fi
  exit 0
fi
if [[ -n "$code" && "$code" != 5* ]]; then
  die "the broker refused: $(jq -r '.error // "unknown"' <<<"$body" 2>/dev/null || echo unknown) (HTTP $code)"
fi
die "the broker at $broker_url is unavailable (${code:-no answer}), and there is no other token source. Check ${broker_url%/}/healthz; the kill switch is BROKER_ENABLED (broker/README.md)"
