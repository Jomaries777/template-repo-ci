#!/usr/bin/env bash
# Mint a 1-hour installation token for the agent bot GitHub App (spec §4.5, C5).
#
# Usage:  GH_TOKEN="$(scripts/bot-token.sh [owner/repo])" gh pr create ...
#
# The token comes from the first source that applies (spec 0002):
#   1. The bot token broker, once this device has signed in with
#      scripts/bot-login.sh: a broker URL (BOT_BROKER_URL, or the file
#      ~/.config/agent-bot/broker_url) and ~/.config/agent-bot/identity.
#      No App key on this device. If the broker can't be reached or answers
#      5xx (down, or its kill switch is on), the sources below are tried; a
#      refusal (bad identity, wrong owner, not installed, rate limit) stops.
#   2. In a GitHub Codespace: the Codespaces user secret BOT_APP_KEY_B64.
#      Outside a Codespace that variable is ignored, so the key isn't
#      encouraged into ordinary env files.
#   3. On a Mac: the Keychain, service "github-app-private-key" (see
#      intent/0001-github-cicd-pipeline/spikes/m0-owner-setup.md).
# In GitHub Actions use actions/create-github-app-token with the
# BOT_APP_PRIVATE_KEY secret instead.
#
# The token is printed to stdout and nothing else. The key never touches disk
# except as a 0600 temp file that is removed on exit, and is never printed.
# The identity is sent to the broker in a header read from a pipe, so it
# never appears in a command line (curl -H @file needs curl 7.55 or later),
# and only over https.
set -euo pipefail

repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
service="${BOT_KEYCHAIN_SERVICE:-github-app-private-key}"
config_dir="${BOT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-bot}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
die() {
  echo "bot-token: $*" >&2
  exit 1
}

# --- 1. the broker
broker_url="${BOT_BROKER_URL:-$(cat "$config_dir/broker_url" 2>/dev/null || true)}"
if [[ -n "$broker_url" && -s "$config_dir/identity" ]]; then
  [[ "$broker_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] ||
    die "the broker URL must be https://host; not sending the identity to $broker_url"
  [[ "$repo" == */* ]] || die "give the repo as owner/name, not $repo"
  # The full owner/name goes to the broker, which refuses any other owner.
  code=""
  if reply="$(curl -sS --max-time 15 -X POST \
    -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$config_dir/identity")") \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg r "$repo" '{repo: $r}')" \
    -w '\n%{http_code}' \
    "${broker_url%/}/token")"; then
    code="${reply##*$'\n'}"
    body="${reply%$'\n'*}"
  fi
  if [[ "$code" == 200 ]]; then
    jq -r '.token' <<<"$body"
    exit 0
  fi
  if [[ -n "$code" && "$code" != 5* ]]; then
    die "the broker refused: $(jq -r '.error // "unknown"' <<<"$body" 2>/dev/null || echo unknown) (HTTP $code)"
  fi
  echo "bot-token: the broker at $broker_url is unavailable (${code:-no answer}); trying the local key" >&2
fi

# --- 2 and 3: sign locally with the App key
# The App ID: BOT_APP_ID, else the repo variable. A Codespace's own token
# can't read Actions variables (HTTP 403), so there it comes from a
# Codespaces secret named BOT_APP_ID (the ID isn't secret; a Codespaces
# secret is how it reaches the environment).
app_id="${BOT_APP_ID:-}"
if [[ -z "$app_id" ]]; then
  gh_err="$(mktemp)"
  if ! app_id="$(gh variable get BOT_APP_ID --repo "$repo" 2>"$gh_err")"; then
    msg="$(head -c 200 "$gh_err")"
    rm -f "$gh_err"
    die "can't read the bot App ID (repo variable BOT_APP_ID of $repo; gh said: $msg). Set BOT_APP_ID; in a Codespace add the Codespaces secret BOT_APP_ID (github.com/settings/codespaces) with access to $repo, then restart the Codespace"
  fi
  rm -f "$gh_err"
fi
[[ "$app_id" =~ ^[0-9]+$ ]] || die "the bot App ID must be a number, got: ${app_id:0:20}"

# key_b64: print the base64 App key from the first source that applies.
key_b64() {
  if [[ "${CODESPACES:-}" == "true" && -n "${BOT_APP_KEY_B64:-}" ]]; then
    printf '%s' "$BOT_APP_KEY_B64"
  elif command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$service" -w
  else
    echo "bot-token: no bot App key found. In a Codespace: add the Codespaces secret" \
      "BOT_APP_KEY_B64 (github.com/settings/codespaces) with access to $repo, then restart" \
      "the Codespace. On a Mac: store it in the Keychain (service $service)." >&2
    return 1
  fi
}

key="$(mktemp)"
trap 'rm -f "$key"' EXIT
chmod 600 "$key"
key_value="$(key_b64)" || exit 1
base64 -d <<<"$key_value" >"$key" 2>/dev/null || die "the bot App key isn't valid base64"
unset key_value
[[ "$(head -c 10 "$key")" == "-----BEGIN" ]] || die "the bot App key isn't a PEM private key"

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
