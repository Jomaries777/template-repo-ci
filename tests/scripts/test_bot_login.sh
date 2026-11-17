#!/usr/bin/env bash
# Tests for scripts/bot-login.sh (spec 0002, C2): GitHub's device flow with a
# fake curl. Run from the repo root.
set -euo pipefail

src="$PWD"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}

command -v jq >/dev/null 2>&1 || {
  echo "ok - skipped (needs jq)"
  exit 0
}

# A fake identity, built so no literal looks like a real token.
cred="$(printf '%s-%s' login identity)"
mkdir -p "$tmp/bin"
# The fake curl answers the device-code request, then replays the polling
# replies listed in $FAKE_REPLIES, one per call.
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/curl.args"
case "${*: -1}" in
  */login/device/code)
    echo '{"device_code":"dev-123","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","interval":1,"expires_in":60}' ;;
  */login/oauth/access_token)
    n=$(($(cat "$FAKE_DIR/n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_DIR/n"
    sed -n "${n}p" "$FAKE_REPLIES" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$tmp/bin/curl"

# run <replies file> [args...]: sets out, err, rc; config in $tmp/cfg.
run() {
  local replies="$1"
  shift
  rm -rf "$tmp/cfg" "$tmp/n" "$tmp/curl.args"
  rc=0
  out="$(PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp" FAKE_REPLIES="$replies" BOT_CONFIG_DIR="$tmp/cfg" \
    BOT_LOGIN_POLL_SCALE=0 "$src/scripts/bot-login.sh" "$@" 2>"$tmp/err")" || rc=$?
  err="$(cat "$tmp/err")"
}

printf '%s\n' '{"error":"authorization_pending"}' '{"error":"slow_down"}' \
  "{\"access_token\":\"$cred\",\"token_type\":\"bearer\"}" >"$tmp/ok.replies"
run "$tmp/ok.replies" --broker https://agent-bot-broker.example.workers.dev/
if [[ $rc == 0 ]]; then pass "device flow: signs in after pending and slow_down"; else fail "device flow: signs in (rc $rc, err: $err)"; fi
if [[ "$(cat "$tmp/cfg/identity" 2>/dev/null)" == "$cred" ]]; then pass "identity saved"; else fail "identity saved"; fi
mode="$(stat -c %a "$tmp/cfg/identity" 2>/dev/null || stat -f %Lp "$tmp/cfg/identity")"
if [[ "$mode" == 600 ]]; then pass "identity file is mode 600"; else fail "identity file is mode 600 (got $mode)"; fi
if [[ -z "$out" ]] && ! grep -qF "$cred" <<<"$err"; then pass "identity never printed"; else fail "identity never printed"; fi
if grep -q "ABCD-1234" <<<"$err" && grep -q "github.com/login/device" <<<"$err"; then pass "shows the code and the URL"; else fail "shows the code and the URL ($err)"; fi
if [[ "$(cat "$tmp/cfg/broker_url" 2>/dev/null)" == "https://agent-bot-broker.example.workers.dev" ]]; then
  pass "broker URL saved without a trailing slash"
else
  fail "broker URL saved without a trailing slash"
fi
if grep -q "client_id=Iv23liFOZk5YaGC6CJc9" "$tmp/curl.args"; then pass "uses the login App's client ID"; else fail "uses the login App's client ID"; fi

printf '%s\n' '{"error":"authorization_pending"}' '{"error":"access_denied"}' >"$tmp/denied.replies"
run "$tmp/denied.replies" --broker https://agent-bot-broker.example.workers.dev
if [[ $rc != 0 && ! -e "$tmp/cfg/identity" && ! -e "$tmp/cfg/broker_url" ]] && grep -q "cancelled" <<<"$err"; then
  pass "denied: fails and saves nothing, not even the broker URL"
else
  fail "denied: fails and saves nothing (rc $rc, err: $err)"
fi

run "$tmp/ok.replies" --broker http://insecure.example
if [[ $rc != 0 ]] && grep -q "https" <<<"$err"; then pass "rejects a non-https broker URL"; else fail "rejects a non-https broker URL"; fi

run "$tmp/ok.replies" --broker
if [[ $rc == 64 ]] && grep -q "needs a URL" <<<"$err"; then pass "--broker without a URL is a usage error"; else fail "--broker without a URL is a usage error (rc $rc)"; fi

run "$tmp/ok.replies"
run "$tmp/ok.replies" --logout
if [[ $rc == 0 && ! -e "$tmp/cfg/identity" ]]; then pass "logout deletes the identity"; else fail "logout deletes the identity"; fi

exit $((failures > 0))
