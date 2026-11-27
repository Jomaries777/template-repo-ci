#!/usr/bin/env bash
# Tests for scripts/bot-secrets.sh (spec 0002 FR-8; spec 0003 FR-4). A fake curl records what
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
key="$(tail -n 1 "$CURL_BODY" | jq -r .key)"
case "$key" in
  claude) printf '{"key":"claude","app":"actions","secret":"CLAUDE_APP_PRIVATE_KEY"}\n200' ;;
  ci) printf '{"key":"ci","app":"dependabot","secret":"CI_APP_PRIVATE_KEY"}\n200' ;;
  *) printf '{"error":"bad_key"}\n400' ;;
esac
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

run --key claude acme-x/one Jomaries777/two
check "--key claude: sets the Actions secret for each repo" grep -q "acme-x/one: CLAUDE_APP_PRIVATE_KEY set (actions)" <<<"$out"
check "second repo too" grep -q "Jomaries777/two: CLAUDE_APP_PRIVATE_KEY set (actions)" <<<"$out"
check "identity sent as a header" grep -qx "Authorization: Bearer $ident" "$tmp/hdrs"
check "gh token sent as a header" grep -qx "X-GitHub-Token: $gh_tok" "$tmp/hdrs"
# shellcheck disable=SC2329 # called through check
absent() { ! grep -qF -e "$ident" -e "$gh_tok" "$@"; }
check "credentials never in args" absent "$tmp/args"
check "credentials never in output" absent <<<"$out$err"
check "posts to /secrets" grep -q "https://broker.test/secrets$" "$tmp/args"
check "body is {repo, key}" test "$(head -n 1 "$tmp/body")" == '{"repo":"acme-x/one","key":"claude"}'

run --key ci Jomaries777/two
check "--key ci: sets the Dependabot secret" grep -q "Jomaries777/two: CI_APP_PRIVATE_KEY set (dependabot)" <<<"$out"
check "--key ci: body names the ci key" test "$(head -n 1 "$tmp/body")" == '{"repo":"Jomaries777/two","key":"ci"}'

# BOT_BROKER_URL wins over the saved broker_url, as in bot-relay.sh.
TEST_BROKER_URL=https://env-broker.test run --key claude Jomaries777/two
check "BOT_BROKER_URL overrides the saved broker URL" grep -q "https://env-broker.test/secrets$" "$tmp/args"

FAKE_CODE=403 FAKE_BODY='{"error":"github_token_not_owner"}' run --key claude Jomaries777/two
check "refusal fails" test "$rc" != 0
check "refusal names the code and a hint" grep -q "github_token_not_owner (HTTP 403); gh is logged in as another account" <<<"$err"
FAKE_CODE=400 FAKE_BODY='{"error":"bad_apps"}' run --key ci Jomaries777/two
check "a broker from before the cutover gets a hint" grep -q "bad_apps (HTTP 400); this broker predates --key" <<<"$err"
FAKE_CODE=500 FAKE_BODY='{"error":"missing_key"}' run --key ci Jomaries777/two
check "a missing broker key gets a hint" grep -q "missing_key (HTTP 500); the broker has no ci App key loaded" <<<"$err"
FAKE_CODE=200 FAKE_BODY='{"key":"ci"}' run --key ci Jomaries777/two
check "a 200 that names no secret fails" test "$rc" != 0 -a -z "$out"
FAKE_CODE=404 FAKE_BODY='{"error":"not_found"}' run --key ci Jomaries777/two
check "not_found gets a hint" grep -q "not_found (HTTP 404); the repo doesn't exist" <<<"$err"

# Usage errors (exit 64) come before anything is sent.
for args in "Jomaries777/two" "--key agy Jomaries777/two" "--key Jomaries777/two" "--apps actions Jomaries777/two" "--key claude"; do
  # shellcheck disable=SC2086 # split on purpose
  run $args
  check "usage: [$args] is refused before sending" test "$rc" == 64 -a ! -s "$tmp/args"
done
run --key claude "not a repo"
check "bad repo refused before sending" test "$rc" != 0 -a ! -s "$tmp/args"
run --key ci --dry-run Jomaries777/two
check "dry run sends nothing" test "$rc" == 0 -a ! -s "$tmp/args"
check "dry run names the fixed target" grep -q "DRY-RUN: broker /secrets --key ci: CI_APP_PRIVATE_KEY (dependabot) for Jomaries777/two" <<<"$out"
rm "$tmp/cfg/identity"
run --key claude Jomaries777/two
check "not signed in: clear error" grep -q "isn't signed in" <<<"$err"

exit $((failures > 0))
