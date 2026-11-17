#!/usr/bin/env bash
# Tests for scripts/bot-token.sh key sources (spec 0002 phase 1, FR-2):
# BOT_APP_KEY_B64 inside a Codespace, else the macOS Keychain. Keys are
# generated at test time; a fake curl stands in for GitHub and records the
# JWT, which is verified against the expected public key. Run from the repo
# root.
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

if ! command -v openssl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "ok - skipped (needs openssl and jq)"
  exit 0
fi

# Two throwaway keys: A for the Codespaces secret, B for the Keychain.
for k in a b; do
  openssl genrsa -out "$tmp/$k.pem" 2048 2>/dev/null
  openssl rsa -in "$tmp/$k.pem" -pubout -out "$tmp/$k.pub" 2>/dev/null
done
b64() { base64 <"$1" | tr -d '\n'; }
key_a="$(b64 "$tmp/a.pem")"
key_b="$(b64 "$tmp/b.pem")"

# A PATH with only the tools bot-token.sh needs, so a real `security` (on a
# Mac) or `gh` is never reached. Each case adds its own fakes on top.
mkdir -p "$tmp/base"
for t in bash env openssl jq date mktemp chmod rm base64 tr cat head; do
  ln -s "$(command -v "$t")" "$tmp/base/$t"
done
mkdir -p "$tmp/fake"
cat >"$tmp/fake/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_ARGS"
prev=""
for a in "$@"; do
  case "$a" in
    "Authorization: Bearer "*) printf '%s' "${a#Authorization: Bearer }" >"$CURL_JWT" ;;
  esac
  # A header read from a file (-H @file): keep what the broker would see.
  if [[ "$prev" == -H && "$a" == @* ]]; then cat "${a#@}" >>"$CURL_HDRS"; fi
  prev="$a"
done
case "${*: -1}" in
  https://broker.test/token)
    printf '%s\n%s' "${FAKE_BROKER_BODY:-{\"token\":\"from-broker\",\"expires_at\":\"x\"}}" "${FAKE_BROKER_CODE:-200}"
    exit 0 ;;
  */installation) echo '{"id":42}' ;;
  */access_tokens) echo '{"token":"ghs_test"}' ;;
  *) exit 22 ;;
esac
EOF
cat >"$tmp/fake/security" <<EOF
#!/usr/bin/env bash
echo "security \$*" >>"$tmp/security.calls"
printf '%s\n' "$key_b"
EOF
chmod +x "$tmp/fake/curl" "$tmp/fake/security"
mkdir -p "$tmp/nosec"
ln -s "$tmp/fake/curl" "$tmp/nosec/curl"

# run <path> [env...]: run bot-token.sh; sets out, err and rc.
run() {
  local path="$1"
  shift
  rm -f "$tmp/jwt" "$tmp/security.calls" "$tmp/curl.args" "$tmp/curl.hdrs"
  rc=0
  out="$(env -i PATH="$path" HOME="$tmp" CURL_JWT="$tmp/jwt" CURL_ARGS="$tmp/curl.args" CURL_HDRS="$tmp/curl.hdrs" BOT_APP_ID=4242 "$@" \
    bash "$src/scripts/bot-token.sh" acme/hello 2>"$tmp/err")" || rc=$?
  err="$(cat "$tmp/err")"
}
# jwt_signed_by <pubkey>: the recorded JWT verifies with this public key.
jwt_signed_by() {
  [[ -s "$tmp/jwt" ]] || return 1
  local h p s
  IFS=. read -r h p s <"$tmp/jwt"
  printf '%s.%s' "$h" "$p" >"$tmp/signed"
  s="$(tr '_-' '/+' <<<"$s")"
  while ((${#s} % 4)); do s="$s="; done
  base64 -d <<<"$s" >"$tmp/sig"
  openssl dgst -sha256 -verify "$1" -signature "$tmp/sig" "$tmp/signed" >/dev/null 2>&1
}
jwt_iss() {
  local p
  IFS=. read -r _ p _ <"$tmp/jwt"
  p="$(tr '_-' '/+' <<<"$p")"
  while ((${#p} % 4)); do p="$p="; done
  base64 -d <<<"$p" | jq -r .iss
}

with_sec="$tmp/fake:$tmp/base"
no_sec="$tmp/nosec:$tmp/base"

# 1. Codespace with the secret: signs with it, never asks the Keychain.
run "$with_sec" CODESPACES=true BOT_APP_KEY_B64="$key_a"
if [[ $rc == 0 && "$out" == "ghs_test" ]]; then pass "codespace: prints the token"; else fail "codespace: prints the token (rc $rc, out [$out], err: $err)"; fi
if jwt_signed_by "$tmp/a.pub"; then pass "codespace: JWT signed with the Codespaces secret"; else fail "codespace: JWT signed with the Codespaces secret"; fi
if [[ ! -s "$tmp/security.calls" ]]; then pass "codespace: Keychain not used"; else fail "codespace: Keychain not used ($(cat "$tmp/security.calls"))"; fi
if [[ "$(jwt_iss)" == "4242" ]]; then pass "JWT iss is BOT_APP_ID"; else fail "JWT iss is BOT_APP_ID (got $(jwt_iss))"; fi

# 2. Outside a Codespace the variable is ignored: the Keychain key signs.
run "$with_sec" BOT_APP_KEY_B64="$key_a"
if [[ $rc == 0 ]] && jwt_signed_by "$tmp/b.pub"; then
  pass "outside a Codespace: BOT_APP_KEY_B64 ignored, Keychain used"
else
  fail "outside a Codespace: BOT_APP_KEY_B64 ignored, Keychain used (rc $rc, err: $err)"
fi

# 3. Codespace without the secret and no Keychain: a clear error, no output.
run "$no_sec" CODESPACES=true
if [[ $rc != 0 && -z "$out" ]] && grep -q "BOT_APP_KEY_B64" <<<"$err"; then
  pass "no key source: fails with the Codespaces hint"
else
  fail "no key source: fails with the Codespaces hint (rc $rc, out [$out], err: $err)"
fi

# 4. A value that isn't a PEM key fails without echoing it.
junk="$(printf 'not-a-key-%s' "$RANDOM$RANDOM" | base64 | tr -d '\n')"
run "$with_sec" CODESPACES=true BOT_APP_KEY_B64="$junk"
if [[ $rc != 0 && -z "$out" ]] && ! grep -qF "$junk" <<<"$err" && ! grep -q "not-a-key" <<<"$err"; then
  pass "bad key: fails without printing it"
else
  fail "bad key: fails without printing it (rc $rc, err: $err)"
fi

# 5. The broker comes first once this device has signed in (bot-login.sh).
ident="$(printf '%s-%s' device identity)"
mkdir -p "$tmp/.config/agent-bot"
printf '%s' "$ident" >"$tmp/.config/agent-bot/identity"
printf '%s\n' "https://broker.test" >"$tmp/.config/agent-bot/broker_url"
run "$with_sec" CODESPACES=true BOT_APP_KEY_B64="$key_a"
if [[ $rc == 0 && "$out" == "from-broker" ]]; then pass "broker: used before the Codespaces secret"; else fail "broker: used before the Codespaces secret (rc $rc, out [$out], err: $err)"; fi
if [[ ! -s "$tmp/jwt" ]]; then pass "broker: no local signing"; else fail "broker: no local signing"; fi
if grep -q '"repo":"acme/hello"' "$tmp/curl.args"; then pass "broker: sends owner/name"; else fail "broker: sends owner/name ($(cat "$tmp/curl.args"))"; fi
if grep -qF "Authorization: Bearer $ident" "$tmp/curl.hdrs" 2>/dev/null; then pass "broker: sends the identity as a bearer header"; else fail "broker: sends the identity as a bearer header"; fi
if ! grep -qF "$ident" "$tmp/curl.args"; then pass "broker: identity never on the command line"; else fail "broker: identity never on the command line"; fi

# 6. A refusal names the broker's error and never prints the identity.
run "$with_sec" FAKE_BROKER_BODY='{"error":"not_owner"}' FAKE_BROKER_CODE=403
if [[ $rc != 0 && -z "$out" ]] && grep -q "not_owner" <<<"$err" && ! grep -qF "$ident" <<<"$err"; then
  pass "broker: a refusal shows its error code"
else
  fail "broker: a refusal shows its error code (rc $rc, err: $err)"
fi

# A broker that is down or switched off (5xx, or no answer) falls back to the
# local key; a refusal (4xx) does not.
run "$with_sec" CODESPACES=true BOT_APP_KEY_B64="$key_a" FAKE_BROKER_BODY='{"error":"disabled"}' FAKE_BROKER_CODE=503
if [[ $rc == 0 && "$out" == "ghs_test" ]] && jwt_signed_by "$tmp/a.pub" && grep -q "unavailable (503)" <<<"$err"; then
  pass "broker: a 503 falls back to the Codespaces secret"
else
  fail "broker: a 503 falls back to the Codespaces secret (rc $rc, out [$out], err: $err)"
fi
run "$with_sec" CODESPACES=true BOT_APP_KEY_B64="$key_a" FAKE_BROKER_BODY='{"error":"wrong_owner"}' FAKE_BROKER_CODE=400
if [[ $rc != 0 && -z "$out" ]] && grep -q "wrong_owner" <<<"$err"; then
  pass "broker: a 4xx refusal does not fall back"
else
  fail "broker: a 4xx refusal does not fall back (rc $rc, out [$out])"
fi

# A non-https broker URL never gets the identity.
run "$with_sec" BOT_BROKER_URL=http://broker.test
if [[ $rc != 0 && ! -s "$tmp/curl.hdrs" ]] && grep -q "https" <<<"$err"; then
  pass "broker: refuses a non-https URL before sending anything"
else
  fail "broker: refuses a non-https URL before sending anything (rc $rc, err: $err)"
fi

# 7. BOT_BROKER_URL overrides the saved URL; without an identity the broker is skipped.
run "$with_sec" BOT_BROKER_URL=https://broker.test FAKE_BROKER_BODY='{"token":"via-env"}'
if [[ "$out" == "via-env" ]]; then pass "broker: BOT_BROKER_URL works"; else fail "broker: BOT_BROKER_URL works (out [$out])"; fi
rm -f "$tmp/.config/agent-bot/identity"
run "$with_sec" CODESPACES=true BOT_APP_KEY_B64="$key_a"
if [[ $rc == 0 && "$out" == "ghs_test" ]] && jwt_signed_by "$tmp/a.pub"; then
  pass "no identity: falls back to the Codespaces secret"
else
  fail "no identity: falls back to the Codespaces secret (rc $rc, out [$out])"
fi

# 8. No BOT_APP_ID and the repo variable can't be read (a Codespace's own
# token gets HTTP 403 on Actions variables): a clear hint, no token.
mkdir -p "$tmp/gh403"
cat >"$tmp/gh403/gh" <<'EOF'
#!/usr/bin/env bash
echo "failed to get variable BOT_APP_ID: HTTP 403: Resource not accessible by integration" >&2
exit 1
EOF
chmod +x "$tmp/gh403/gh"
run "$tmp/gh403:$with_sec" CODESPACES=true BOT_APP_KEY_B64="$key_a" BOT_APP_ID=
if [[ $rc != 0 && -z "$out" ]] && grep -q "Codespaces secret BOT_APP_ID" <<<"$err" && grep -q "HTTP 403" <<<"$err"; then
  pass "app ID unreadable: fails with the BOT_APP_ID hint"
else
  fail "app ID unreadable: fails with the BOT_APP_ID hint (rc $rc, out [$out], err: $err)"
fi
# The repo variable is still used when gh can read it.
cat >"$tmp/gh403/gh" <<'EOF'
#!/usr/bin/env bash
echo "A new release of gh is available" >&2
echo 4343
EOF
run "$tmp/gh403:$with_sec" CODESPACES=true BOT_APP_KEY_B64="$key_a" BOT_APP_ID=
if [[ $rc == 0 && "$(jwt_iss)" == "4343" ]]; then pass "app ID from the repo variable, gh warnings ignored"; else fail "app ID from the repo variable, gh warnings ignored (rc $rc, err: $err)"; fi
# BOT_APP_ID wins over the repo variable, and gh isn't needed when it's set.
cat >"$tmp/gh403/gh" <<'EOF2'
#!/usr/bin/env bash
exit 1
EOF2
run "$tmp/gh403:$with_sec" CODESPACES=true BOT_APP_KEY_B64="$key_a" BOT_APP_ID=1234
if [[ $rc == 0 && "$(jwt_iss)" == "1234" ]]; then pass "app ID from BOT_APP_ID first"; else fail "app ID from BOT_APP_ID first (rc $rc, err: $err)"; fi
# A non-numeric ID is refused before anything is signed.
run "$tmp/gh403:$with_sec" CODESPACES=true BOT_APP_KEY_B64="$key_a" BOT_APP_ID=abc
if [[ $rc != 0 && -z "$out" && ! -s "$tmp/jwt" ]] && grep -q "must be a number" <<<"$err"; then pass "non-numeric app ID refused"; else fail "non-numeric app ID refused (rc $rc, err: $err)"; fi

exit $((failures > 0))
