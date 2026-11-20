#!/usr/bin/env bash
# Tests for scripts/bot-secrets.sh (spec 0002 FR-8). A fake curl records what
# would reach the broker; a fake gh supplies the owner's token. Run from the
# repo root.
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
if ! command -v jq >/dev/null 2>&1; then
  echo "ok - skipped (needs jq)"
  exit 0
fi

gh_tok="$(printf 'ghtok-%s' "$RANDOM$RANDOM")"
ident="$(printf 'ident-%s' "$RANDOM$RANDOM")"
mkdir -p "$tmp/bin" "$tmp/cfg"
printf '%s\n' "$ident" >"$tmp/cfg/identity"
printf 'https://broker.test\n' >"$tmp/cfg/broker_url"
printf '#!/usr/bin/env bash\n[[ "$*" == "auth token" ]] && echo %q\n' "$gh_tok" >"$tmp/bin/gh"
cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_ARGS"
prev=""
for a in "$@"; do
  if [[ "$prev" == -H && "$a" == @* ]]; then cat "${a#@}" >>"$CURL_HDRS"; fi
  if [[ "$prev" == --data ]]; then printf '%s\n' "$a" >>"$CURL_BODY"; fi
  prev="$a"
done
if [[ -n "${FAKE_CODE:-}" ]]; then
  printf '%s\n%s' "$FAKE_BODY" "$FAKE_CODE"
  exit 0
fi
apps="$(tail -n 1 "$CURL_BODY" | jq -c .apps)"
printf '{"set":%s}\n200' "$apps"
CURL
chmod +x "$tmp/bin/gh" "$tmp/bin/curl"

# run [args...]: run bot-secrets.sh; sets out, err and rc. The broker URL
# comes from the config file unless TEST_BROKER_URL is set: an inherited
# BOT_BROKER_URL (cloud sessions export one) is cleared, so the result is the
# same in CI and in any session.
run() {
  rm -f "$tmp/args" "$tmp/hdrs" "$tmp/body"
  rc=0
  # No array: "${a[@]}" of an empty array is an unbound-variable error under
  # set -u on bash before 4.4 (macOS /bin/bash is 3.2).
  out="$(env -u BOT_BROKER_URL ${TEST_BROKER_URL:+"BOT_BROKER_URL=$TEST_BROKER_URL"} PATH="$tmp/bin:$PATH" CURL_ARGS="$tmp/args" CURL_HDRS="$tmp/hdrs" \
    CURL_BODY="$tmp/body" BOT_CONFIG_DIR="$tmp/cfg" bash "$src/scripts/bot-secrets.sh" "$@" 2>"$tmp/err")" || rc=$?
  err="$(cat "$tmp/err")"
}
check() { # check <name> <condition...>
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name (rc $rc, out [$out], err [$err])"; fi
}

run acme-x/one Jomaries777/two
check "sets both apps for each repo" grep -q "acme-x/one: BOT_APP_PRIVATE_KEY set for actions, dependabot" <<<"$out"
check "second repo too" grep -q "Jomaries777/two: BOT_APP_PRIVATE_KEY set" <<<"$out"
check "identity sent as a header" grep -qx "Authorization: Bearer $ident" "$tmp/hdrs"
check "gh token sent as a header" grep -qx "X-GitHub-Token: $gh_tok" "$tmp/hdrs"
# shellcheck disable=SC2329 # called through check
absent() { ! grep -qF -e "$ident" -e "$gh_tok" "$@"; }
check "credentials never in args" absent "$tmp/args"
check "credentials never in output" absent <<<"$out$err"
check "posts to /secrets" grep -q "https://broker.test/secrets$" "$tmp/args"
check "body is {repo, apps}" test "$(head -n 1 "$tmp/body")" == '{"repo":"acme-x/one","apps":["actions","dependabot"]}'

run --apps dependabot Jomaries777/two
check "--apps limits the apps" grep -q '"apps":\["dependabot"\]' "$tmp/body"

# BOT_BROKER_URL wins over the saved broker_url, as in bot-relay.sh.
TEST_BROKER_URL=https://env-broker.test run Jomaries777/two
check "BOT_BROKER_URL overrides the saved broker URL" grep -q "https://env-broker.test/secrets$" "$tmp/args"

FAKE_CODE=403 FAKE_BODY='{"error":"github_token_not_owner"}' run Jomaries777/two
check "refusal fails" test "$rc" != 0
check "refusal names the code and a hint" grep -q "github_token_not_owner (HTTP 403); gh is logged in as another account" <<<"$err"
FAKE_CODE=403 FAKE_BODY='{"error":"github_denied","set":["actions"]}' run Jomaries777/two
check "partial failure says what was already set" grep -q "already set for actions before the error" <<<"$err"

run --apps codespaces Jomaries777/two
check "bad --apps refused before sending" test "$rc" != 0 -a ! -s "$tmp/args"
run "not a repo"
check "bad repo refused before sending" test "$rc" != 0 -a ! -s "$tmp/args"
run --dry-run Jomaries777/two
check "dry run sends nothing" test "$rc" == 0 -a ! -s "$tmp/args"
check "dry run says what it would do" grep -q "DRY-RUN: broker /secrets BOT_APP_PRIVATE_KEY for Jomaries777/two" <<<"$out"
rm "$tmp/cfg/identity"
run Jomaries777/two
check "not signed in: clear error" grep -q "isn't signed in" <<<"$err"

exit $((failures > 0))
