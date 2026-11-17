#!/usr/bin/env bash
# Sign this device in once for the bot token broker (spec 0002, phase 2, C2).
#
# Usage: scripts/bot-login.sh [--broker https://…workers.dev] [--logout]
#
# Runs GitHub's device flow for the login-only GitHub App (no permissions):
# open github.com/login/device, enter the code shown here, and approve. The
# resulting token only says who you are; the broker turns it into short-lived
# bot tokens (scripts/bot-token.sh). It is stored in
# ~/.config/agent-bot/identity (mode 0600) and never printed. --broker saves
# the broker URL next to it. --logout deletes the identity file; to sign every
# device out, revoke the App at github.com/settings/apps/authorizations.
set -euo pipefail

client_id="${BOT_LOGIN_CLIENT_ID:-Iv23liFOZk5YaGC6CJc9}"
dir="${BOT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-bot}"
# Tests shrink the polling interval; real runs use GitHub's.
poll_scale="${BOT_LOGIN_POLL_SCALE:-1}"

die() {
  echo "bot-login: $*" >&2
  exit 1
}

broker=""
logout=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --broker)
      [[ $# -ge 2 && -n "$2" ]] || {
        echo "bot-login: --broker needs a URL" >&2
        exit 64
      }
      broker="$2"
      shift 2
      ;;
    --logout)
      logout=1
      shift
      ;;
    -h | --help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      echo "bot-login: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

if ((logout)); then
  rm -f "$dir/identity"
  echo "bot-login: signed out on this device" >&2
  exit 0
fi

mkdir -p "$dir"
chmod 700 "$dir"
if [[ -n "$broker" ]]; then
  [[ "$broker" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || die "the broker URL must be https://host"
fi

post() { curl -fsS --max-time 15 -X POST -H 'Accept: application/json' "$@"; }

start="$(post -d "client_id=$client_id" https://github.com/login/device/code)" ||
  die "could not reach GitHub to start the sign-in"
device_code="$(jq -r '.device_code // empty' <<<"$start")"
user_code="$(jq -r '.user_code // empty' <<<"$start")"
uri="$(jq -r '.verification_uri // "https://github.com/login/device"' <<<"$start")"
interval="$(jq -r '.interval // 5' <<<"$start")"
expires_in="$(jq -r '.expires_in // 900' <<<"$start")"
[[ -n "$device_code" && -n "$user_code" ]] || die "GitHub did not start the sign-in (is device flow enabled on the login App?)"

echo "bot-login: open $uri and enter the code $user_code" >&2
deadline=$(($(date +%s) + expires_in))
while :; do
  sleep $((interval * poll_scale))
  reply="$(post -d "client_id=$client_id" -d "device_code=$device_code" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
    https://github.com/login/oauth/access_token)" || die "could not reach GitHub while waiting"
  identity="$(jq -r '.access_token // empty' <<<"$reply")"
  if [[ -n "$identity" ]]; then
    (umask 077 && printf '%s' "$identity" >"$dir/identity.new")
    mv -f "$dir/identity.new" "$dir/identity"
    unset identity
    # Saved only after a successful sign-in.
    [[ -z "$broker" ]] || (umask 077 && printf '%s\n' "${broker%/}" >"$dir/broker_url")
    echo "bot-login: signed in; bot-token.sh can now ask the broker" >&2
    exit 0
  fi
  case "$(jq -r '.error // empty' <<<"$reply")" in
    authorization_pending) ;;
    slow_down) interval=$((interval + 5)) ;;
    expired_token) die "the code expired; run bot-login.sh again" ;;
    access_denied) die "the sign-in was cancelled" ;;
    *) die "the sign-in failed: $(jq -r '.error // "unknown error"' <<<"$reply")" ;;
  esac
  (($(date +%s) < deadline)) || die "the code expired; run bot-login.sh again"
done
