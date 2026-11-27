#!/usr/bin/env bash
# Tests for scripts/bot-token.sh (spec 0003 FR-5, D6, C5; acceptance
# criterion 7): --agent is required and the broker is the only token source.
# A fake curl stands in for the broker and records what it would receive;
# fake security and gh record any call, so a fallback would show. Run from
# the repo root.
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

# A PATH with only the tools bot-token.sh needs, plus the fakes, so a real
# security (on a Mac), gh or curl is never reached.
mkdir -p "$tmp/bin"
for t in bash env jq cat head tr; do
  ln -s "$(command -v "$t")" "$tmp/bin/$t"
done
cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_ARGS"
prev=""
for a in "$@"; do
  # A header read from a file (-H @file): keep what the broker would see.
  if [[ "$prev" == -H && "$a" == @* ]]; then cat "${a#@}" >>"$CURL_HDRS"; fi
  if [[ "$prev" == --data ]]; then printf '%s\n' "$a" >>"$CURL_BODY"; fi
  prev="$a"
done
[[ -z "${FAKE_CURL_FAIL:-}" ]] || exit 7
body='{"token":"from-broker","expires_at":"2026-11-28T12:00:00Z","login":"jomaries777-agy[bot]","id":42}'
printf '%s\n%s' "${FAKE_BODY:-$body}" "${FAKE_CODE:-200}"
CURL
for t in security gh; do
  # shellcheck disable=SC2016 # $* and $OTHER_CALLS expand in the fake, not here
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$OTHER_CALLS"\nexit 99\n' "$t" >"$tmp/bin/$t"
done
chmod +x "$tmp/bin/curl" "$tmp/bin/security" "$tmp/bin/gh"

ident="$(printf 'ident-%s' "$RANDOM$RANDOM")"
mkdir -p "$tmp/.config/agent-bot"
printf '%s' "$ident" >"$tmp/.config/agent-bot/identity"
printf '%s\n' "https://broker.test" >"$tmp/.config/agent-bot/broker_url"

# run [env...] -- [args...]: run bot-token.sh with a clean environment; sets
# out, err and rc.
run() {
  local envs=()
  while (($#)) && [[ "$1" != -- ]]; do
    envs+=("$1")
    shift
  done
  shift
  rm -f "$tmp/args" "$tmp/hdrs" "$tmp/body" "$tmp/other"
  rc=0
  out="$(env -i PATH="$tmp/bin" HOME="$tmp" CURL_ARGS="$tmp/args" CURL_HDRS="$tmp/hdrs" CURL_BODY="$tmp/body" \
    OTHER_CALLS="$tmp/other" ${envs[@]+"${envs[@]}"} bash "$src/scripts/bot-token.sh" "$@" 2>"$tmp/err")" || rc=$?
  err="$(cat "$tmp/err")"
}
check() { # check <name> <condition...>
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name (rc $rc, out [$out], err [$err])"; fi
}
# shellcheck disable=SC2329 # called through check
nothing_sent() { [[ ! -s "$tmp/args" && ! -s "$tmp/other" ]]; }

# --- usage (criterion 7: "no --agent")
run -- acme/hello
check "no --agent: usage error" test "$rc" == 64
check "no --agent: nothing sent" nothing_sent
check "no --agent: says how to call it" grep -q "usage: scripts/bot-token.sh --agent" <<<"$err"
for a in ci antigravity "" CLAUDE; do
  run -- --agent "$a" acme/hello
  check "--agent [$a]: usage error, nothing sent" test "$rc" == 64 -a ! -s "$tmp/args"
done
run -- --agent claude acme/hello extra/repo
check "two repos: usage error" test "$rc" == 64

# --- a token from the broker
run -- --agent claude acme/hello
check "prints the token" test "$rc" == 0 -a "$out" == from-broker
check "posts to /token" grep -q "https://broker.test/token$" "$tmp/args"
check "body is {repo, agent}" test "$(cat "$tmp/body")" == '{"repo":"acme/hello","agent":"claude"}'
check "sends the identity as a bearer header" grep -qxF "Authorization: Bearer $ident" "$tmp/hdrs"
# shellcheck disable=SC2329 # called through check
lacks_ident() { ! grep -qF -e "$ident" "$@"; }
check "identity never on the command line" lacks_ident "$tmp/args"
check "no other source asked" test ! -s "$tmp/other"

run -- --agent agy acme/hello
check "--agent agy is sent" test "$(jq -r .agent "$tmp/body")" == agy

run -- --agent agy --json acme/hello
check "--json: login and id from the broker" test "$(jq -c '[.token, .login, .id]' <<<"$out")" == '["from-broker","jomaries777-agy[bot]",42]'
run FAKE_BODY='{"token":"old-broker","expires_at":"x"}' -- --agent agy --json acme/hello
check "--json: a broker from before the cutover gives null login and id" test "$(jq -c '[.token, .login, .id]' <<<"$out")" == '["old-broker",null,null]'
run FAKE_BODY='{"expires_at":"x"}' -- --agent claude acme/hello
check "a 200 without a token fails" test "$rc" != 0 -a -z "$out"

run BOT_BROKER_URL=https://env-broker.test -- --agent claude acme/hello
check "BOT_BROKER_URL overrides the saved URL" grep -q "https://env-broker.test/token$" "$tmp/args"

# --- refusals and outages: no fallback (criterion 7: "broker down, no fallback")
run FAKE_CODE=403 FAKE_BODY='{"error":"wrong_owner"}' -- --agent claude acme/hello
check "a refusal shows its error code" test "$rc" != 0 -a -z "$out"
check "a refusal names the code" grep -q "refused: wrong_owner (HTTP 403)" <<<"$err"
check "a refusal never prints the identity" lacks_ident <<<"$err"

for case in "503" "fail"; do
  if [[ "$case" == fail ]]; then run FAKE_CURL_FAIL=1 -- --agent claude acme/hello; else run FAKE_CODE=503 FAKE_BODY='{"error":"disabled"}' -- --agent claude acme/hello; fi
  check "broker down, no fallback ($case): fails with no output" test "$rc" == 1 -a -z "$out"
  check "broker down, no fallback ($case): says there is no other source" grep -q "unavailable.*no other token source" <<<"$err"
  check "broker down, no fallback ($case): curl called exactly once" test "$(wc -l <"$tmp/args" | tr -d ' ')" == 1
  check "broker down, no fallback ($case): security and gh never called" test ! -s "$tmp/other"
done

# --- refused before anything is sent
run BOT_BROKER_URL=http://broker.test -- --agent claude acme/hello
check "refuses a non-https URL before sending anything" test "$rc" != 0 -a ! -s "$tmp/args"
run -- --agent claude "not a repo"
check "refuses a repo that isn't owner/name before sending" test "$rc" != 0 -a ! -s "$tmp/args"
rm "$tmp/.config/agent-bot/identity"
run -- --agent claude acme/hello
check "not signed in: clear error" grep -q "isn't signed in to the broker: run scripts/bot-login.sh" <<<"$err"
check "not signed in: nothing sent, no other source asked" nothing_sent

# --- criterion 7: no local key source left in the script
if grep -qE 'Keychain|BOT_APP_KEY_B64|security find-generic-password' "$src/scripts/bot-token.sh"; then
  fail "no local key source in bot-token.sh (criterion 7 grep)"
else
  pass "no local key source in bot-token.sh (criterion 7 grep)"
fi

exit $((failures > 0))
