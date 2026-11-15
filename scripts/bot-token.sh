#!/usr/bin/env bash
# Mint a 1-hour installation token for the agent bot GitHub App (spec §4.5, C5).
#
# Usage:  GH_TOKEN="$(scripts/bot-token.sh [owner/repo])" gh pr create ...
#
# Local (macOS) only: reads the App private key from the Keychain, stored
# base64-encoded under service "github-app-private-key" (see
# intent/0001-github-cicd-pipeline/spikes/m0-owner-setup.md). In GitHub Actions use
# actions/create-github-app-token with the BOT_APP_PRIVATE_KEY secret instead.
#
# The token is printed to stdout and nothing else. The key never touches disk
# except as a 0600 temp file that is removed on exit.
set -euo pipefail

repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
app_id="${BOT_APP_ID:-$(gh variable get BOT_APP_ID --repo "$repo")}"
service="${BOT_KEYCHAIN_SERVICE:-github-app-private-key}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

key="$(mktemp)"
trap 'rm -f "$key"' EXIT
chmod 600 "$key"
security find-generic-password -s "$service" -w | base64 -d >"$key"

now="$(date +%s)"
header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app_id" | b64url)"
signature="$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" | b64url)"
jwt="$header.$payload.$signature"

api() {
  curl -fsS \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

installation_id="$(api "https://api.github.com/repos/$repo/installation" | jq -r .id)"
api -X POST "https://api.github.com/app/installations/$installation_id/access_tokens" | jq -r .token
