#!/usr/bin/env bash
# Tests for scripts/release.sh (spec §4.10). Fakes deploy.sh, the smoke suite
# and curl; no network, no cloud. Run from the repo root.
set -euo pipefail

release="$PWD/scripts/release.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fake deploy.sh: logs each verb, prints the result the real contract prints.
cat >"$tmp/deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case "$1" in
  current) [[ -n "${CURRENT_EMPTY:-}" ]] || echo "svc-00001-old" ;;
  revert) [[ -z "${REVERT_FAIL:-}" ]] || exit 1; touch "$CALLS.reverted" ;;
  deploy-dark) [[ -z "${DARK_FAIL:-}" ]] || exit 1; echo "https://cand.example" ;;
  preview) [[ -z "${PREVIEW_FAIL:-}" ]] || exit 1; echo "http://127.0.0.1:9999/" ;;
  url)
    # URL_FAIL_FIRST: the first `url` call (the baseline's) fails.
    if [[ -n "${URL_FAIL_FIRST:-}" && ! -e "$CALLS.url1" ]]; then touch "$CALLS.url1"; exit 1; fi
    # URL_FAIL_AFTER_REVERT: `url` fails once the fake revert ran.
    if [[ -n "${URL_FAIL_AFTER_REVERT:-}" && -e "$CALLS.reverted" ]]; then exit 1; fi
    if [[ -n "${URL_FOLLOWS_REVERT:-}" && -e "$CALLS.reverted" ]]; then echo "https://prev.example/"; else echo "https://live.example/"; fi ;;
esac
EOF
# Fake smoke: fails for the URL in SMOKE_FAIL_URL; with SMOKE_FAIL_AFTER=n,
# fails from the (n+1)th call on; SMOKE_FAIL_NTH=n fails only call n, and
# SMOKE_FAIL_NTHS="n m ..." each listed call.
# Smoke call order when PREV exists and its baseline passes: 1 the baseline
# (the serving version, before the deploy), 2 the candidate, 3.. the live
# checks, then the re-check, which always follows a revert (whether or not
# the baseline passed). A failed baseline adds one retry.
cat >"$tmp/smoke" <<'EOF'
#!/usr/bin/env bash
echo "smoke $1" >>"$CALLS"
n=$(($(cat "$COUNT" 2>/dev/null || echo 0) + 1)); echo "$n" >"$COUNT"
[[ "$1" == "${SMOKE_FAIL_URL:-}" ]] && exit 1
[[ -n "${SMOKE_FAIL_AFTER:-}" && "$n" -gt "$SMOKE_FAIL_AFTER" ]] && exit 1
[[ -n "${SMOKE_FAIL_NTH:-}" && "$n" == "$SMOKE_FAIL_NTH" ]] && exit 1
[[ " ${SMOKE_FAIL_NTHS:-} " == *" $n "* ]] && exit 1
exit 0
EOF
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
echo "curl $url" >>"$CALLS"
[[ "$url" == "${CURL_FAIL_URL:-}" ]] && exit 22
# CURL_FAIL_HEALTH_FIRST: the first /health call fails (once).
if [[ -n "${CURL_FAIL_HEALTH_FIRST:-}" && "$url" == */health && ! -e "$CALLS.health1" ]]; then touch "$CALLS.health1"; exit 22; fi
# CURL_FAIL_HEALTH_AFTER_REVERT: /health fails once the fake revert ran.
[[ -n "${CURL_FAIL_HEALTH_AFTER_REVERT:-}" && "$url" == */health && -e "$CALLS.reverted" ]] && exit 22
exit 0
EOF
chmod +x "$tmp/deploy.sh" "$tmp/smoke" "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" DEPLOY_SH="$tmp/deploy.sh" SMOKE_CMD="$tmp/smoke" RELEASE_INTERVAL=0 RELEASE_BASELINE_RETRY_DELAY=0
# The fake deploy.sh prints its live URL with a trailing slash, as some hosts do.

sha=1234567abcdef

# run <name> [env assignments...]: runs release.sh dev <sha>; sets rc, calls.
run() {
  local name="$1"
  shift
  export CALLS="$tmp/calls.$name" COUNT="$tmp/count.$name"
  : >"$CALLS"
  rc=0
  env "$@" "$release" dev "$sha" >"$tmp/out.$name" 2>"$tmp/err.$name" || rc=$?
  calls="$(cat "$CALLS")"
}
pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}
rc_is() { if [[ "$rc" == "$2" ]]; then pass "$1"; else fail "$1 (rc $rc, want $2)"; fi; }
has() { if grep -qxF -- "$2" <<<"$calls"; then pass "$1"; else fail "$1 (no call: $2)"; fi; }
lacks() { if grep -qF -- "$2" <<<"$calls"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }
count_is() {
  local n
  n="$(grep -cxF -- "$2" <<<"$calls" || true)"
  if [[ "$n" == "$3" ]]; then pass "$1"; else fail "$1 ($n calls of '$2', want $3)"; fi
}

# --- happy path
run ok
rc_is "happy: exits 0" 0
want="current dev
url dev
smoke https://live.example
curl https://live.example/health
deploy-dark dev $sha
smoke https://cand.example
promote dev $sha
url dev
smoke https://live.example
curl https://live.example/health
smoke https://live.example
curl https://live.example/health
smoke https://live.example
curl https://live.example/health
cleanup dev"
if [[ "$calls" == "$want" ]]; then pass "happy: steps run in spec order"; else fail "happy: order was: $(tr '\n' ';' <<<"$calls")"; fi
lacks "happy: no revert" "revert"
lacks "happy: no discard" "discard"

# --- pre-traffic failure: discard, no traffic
run pre SMOKE_FAIL_URL=https://cand.example
rc_is "pre-traffic failure: exits 1" 1
has "pre-traffic failure: discards the candidate" "discard dev $sha"
lacks "pre-traffic failure: never promotes" "promote"
lacks "pre-traffic failure: no cleanup" "cleanup"

# --- live failure on the 2nd check: revert to PREV and re-check. Smoke call 1
# is the baseline check of the serving version, 2 the candidate, 3+ live.
run live SMOKE_FAIL_AFTER=3
rc_is "live failure: exits 1" 1
has "live failure: reverts to the previous revision" "revert dev svc-00001-old"
lacks "live failure: no cleanup" "cleanup"
lacks "live failure: no discard" "discard"
count_is "live failure: re-checks once after revert" "smoke https://live.example" 4

# --- /health failure counts as a live failure
run health CURL_FAIL_URL=https://live.example/health
rc_is "health failure: exits 1" 1
has "health failure: reverts" "revert dev svc-00001-old"

# --- live checks count comes from RELEASE_LIVE_CHECKS
run five RELEASE_LIVE_CHECKS=5
# 5 live checks plus the baseline check before the deploy.
count_is "live checks: honours RELEASE_LIVE_CHECKS" "curl https://live.example/health" 6

# --- no dark deploy (C9): promote is the deploy
run nodark RELEASE_DARK_DEPLOY=false
rc_is "no dark deploy: exits 0" 0
lacks "no dark deploy: skips deploy-dark" "deploy-dark"
has "no dark deploy: promotes" "promote dev $sha"
has "no dark deploy: cleans up" "cleanup dev"
# C9: without a dark deploy, the pre-traffic test runs against the artifact
# served locally (`deploy.sh preview`), which is stopped before the deploy.
want="current dev
url dev
smoke https://live.example
curl https://live.example/health
preview dev $sha
smoke http://127.0.0.1:9999/
discard dev $sha
promote dev $sha"
got="$(head -n 8 <<<"$calls")"
if [[ "$got" == "$want" ]]; then pass "no dark deploy: local pre-traffic test, then promote"; else fail "no dark deploy: order was: $(tr '\n' ';' <<<"$got")"; fi
run nodarkfail RELEASE_DARK_DEPLOY=false SMOKE_FAIL_URL=http://127.0.0.1:9999/
rc_is "no dark deploy: failed local pre-traffic test exits 1" 1
lacks "no dark deploy: failed local pre-traffic test never promotes" "promote"
has "no dark deploy: failed local pre-traffic test stops the preview" "discard dev $sha"
run nopreview RELEASE_DARK_DEPLOY=false PREVIEW_FAIL=1
rc_is "no dark deploy: a preview that fails exits 1" 1
lacks "no dark deploy: a preview that fails never promotes" "promote"

# --- first deploy: nothing to revert to
run first CURRENT_EMPTY=1 SMOKE_FAIL_AFTER=1
if [[ "$rc" == 1 ]] && grep -q "no previous revision" "$tmp/err.first"; then pass "no previous revision: fails and says so"; else fail "no previous revision (rc $rc)"; fi
lacks "no previous revision: no revert" "revert"
if [[ "$(sed -n 2p <<<"$calls")" == "deploy-dark dev $sha" ]]; then pass "no previous revision: no baseline check"; else fail "no previous revision: baseline ran: $(tr '\n' ';' <<<"$calls")"; fi
lacks "no previous revision: no cleanup" "cleanup"

# --- revert whose re-check fails
run recheck SMOKE_FAIL_AFTER=3
if grep -q "revert did not pass the live check" "$tmp/err.recheck"; then pass "failed re-check after revert: says manual action is needed"; else fail "failed re-check: no message"; fi
rc_is "failed re-check after revert: exits 1" 1
if grep -q "^::error.*NOT confirmed" "$tmp/out.recheck"; then pass "failed re-check: annotates the revert as not confirmed"; else fail "failed re-check: no annotation"; fi
# Only the 2nd live check (4th smoke call) fails; the re-check after revert passes.
run confirm SMOKE_FAIL_NTH=4
rc_is "confirmed revert: still exits 1" 1
if grep -q "^::error.*(revert confirmed)" "$tmp/out.confirm"; then pass "confirmed revert: annotated as confirmed"; else fail "confirmed revert: no annotation"; fi

# --- the serving version already failed the live check before this release
# (a first deploy over bootstrap's placeholder): revert, then re-check anyway
# (the baseline runs this commit's suite, so a healthy PREV can fail it when
# the release adds a smoke test; review of #64)
run unhealthy SMOKE_FAIL_URL=https://live.example
rc_is "unhealthy baseline, live failure: exits 1" 1
has "unhealthy baseline, live failure: still reverts" "revert dev svc-00001-old"
# Smoke calls of the live URL: baseline, its retry, live check 1, re-check.
count_is "unhealthy baseline, live failure: retries the baseline once, re-checks once after revert" "smoke https://live.example" 4
if [[ "$(grep -A2 -xF "revert dev svc-00001-old" <<<"$calls" | sed -n 2,3p | tr '\n' ';')" == "url dev;smoke https://live.example;" ]]; then pass "unhealthy baseline: re-checks after the revert"; else fail "unhealthy baseline: no re-check after revert: $(tr '\n' ';' <<<"$calls")"; fi
if grep -q "^::error.*live test failed; reverted to svc-00001-old, which was not healthy before this release either (on a first deploy, bootstrap's placeholder): fix forward" "$tmp/out.unhealthy"; then pass "unhealthy baseline, failed re-check: annotated as not healthy before"; else fail "unhealthy baseline: no annotation: $(cat "$tmp/out.unhealthy")"; fi
if grep -q "NOT confirmed" "$tmp/out.unhealthy"; then fail "unhealthy baseline: says NOT confirmed"; else pass "unhealthy baseline: no NOT confirmed annotation"; fi
if grep -q "which was not healthy before this release either" "$tmp/err.unhealthy"; then pass "unhealthy baseline, failed re-check: logs it"; else fail "unhealthy baseline: no log"; fi
# Baseline and retry fail (calls 1, 2), the candidate passes (3), live check 1
# fails (4), the re-check passes (5): the revert is confirmed.
run unhealthyconfirm SMOKE_FAIL_NTHS="1 2 4"
rc_is "unhealthy baseline, passing re-check: exits 1" 1
has "unhealthy baseline, passing re-check: reverts" "revert dev svc-00001-old"
if grep -q "^::error.*(revert confirmed)" "$tmp/out.unhealthyconfirm"; then pass "unhealthy baseline, passing re-check: annotated as confirmed"; else fail "unhealthy baseline, passing re-check: no confirmed annotation: $(cat "$tmp/out.unhealthyconfirm")"; fi
if grep -q "fix forward" "$tmp/out.unhealthyconfirm"; then fail "unhealthy baseline, passing re-check: says fix forward"; else pass "unhealthy baseline, passing re-check: no fix forward annotation"; fi
# A PREV that only fails this commit's smoke tests (its /health passed at the
# baseline) must not hide a revert that broke service: /health failing
# after the revert is NOT confirmed (review of #64).
run healthlost SMOKE_FAIL_URL=https://live.example CURL_FAIL_HEALTH_AFTER_REVERT=1
rc_is "baseline failed, revert broke /health: exits 1" 1
if grep -q "^::error.*NOT confirmed" "$tmp/out.healthlost"; then pass "baseline failed, revert broke /health: NOT confirmed"; else fail "baseline failed, revert broke /health: $(cat "$tmp/out.healthlost")"; fi
if grep -q "/health passed before this release" "$tmp/err.healthlost"; then pass "baseline failed, revert broke /health: logs why"; else fail "baseline failed, revert broke /health: no log"; fi
# The baseline's /health is retried once too (review of #68): one transient
# /health failure there must not turn a lost revert into fix forward.
run healthflake SMOKE_FAIL_URL=https://live.example CURL_FAIL_HEALTH_FIRST=1 CURL_FAIL_HEALTH_AFTER_REVERT=1
if grep -q "^::error.*NOT confirmed" "$tmp/out.healthflake"; then pass "baseline /health flaky, revert broke /health: NOT confirmed"; else fail "baseline /health flaky: $(cat "$tmp/out.healthflake")"; fi
# The placeholder: /health failed at the baseline too, so fix forward.
run placeholder SMOKE_FAIL_URL=https://live.example CURL_FAIL_URL=https://live.example/health
if grep -q "^::error.*fix forward" "$tmp/out.placeholder" && ! grep -q "NOT confirmed" "$tmp/out.placeholder"; then pass "placeholder: fix forward, not NOT confirmed"; else fail "placeholder: $(cat "$tmp/out.placeholder")"; fi
# No URL after the revert, after a failed baseline: NOT confirmed, the safe side.
run nourl SMOKE_FAIL_URL=https://live.example URL_FAIL_AFTER_REVERT=1
if grep -q "^::error.*NOT confirmed" "$tmp/out.nourl"; then pass "failed baseline, no URL after revert: NOT confirmed"; else fail "no URL after revert: $(cat "$tmp/out.nourl")"; fi

# Only the baseline and its retry fail: the baseline never fails a release.
run baselineonly SMOKE_FAIL_NTHS="1 2"
rc_is "unhealthy baseline, healthy release: exits 0" 0
lacks "unhealthy baseline, healthy release: no revert" "revert"
if grep -q "serving version is not healthy" "$tmp/err.baselineonly"; then pass "unhealthy baseline: logged before the deploy"; else fail "unhealthy baseline: not logged"; fi

# A baseline that fails once and passes on its retry counts as healthy, so a
# failed re-check after a revert is still reported as NOT confirmed (review
# of #64: one transient failure must not hide a failed revert).
run baselineflake SMOKE_FAIL_NTHS="1 6 7"
rc_is "flaky baseline: exits 1" 1
count_is "flaky baseline: retried once" "smoke https://live.example" 6
if grep -q "baseline: passed on retry" "$tmp/err.baselineflake"; then pass "flaky baseline: logs that it passed on retry"; else fail "flaky baseline: no passed-on-retry log"; fi
if grep -q "^::error.*NOT confirmed" "$tmp/out.baselineflake"; then pass "flaky baseline, failed re-check: still NOT confirmed"; else fail "flaky baseline: not annotated NOT confirmed: $(cat "$tmp/out.baselineflake")"; fi
# An unreadable URL during the baseline counts as healthy: no baseline
# smoke, and the release goes on.
run baselineurl URL_FAIL_FIRST=1
rc_is "baseline URL unreadable: the release still succeeds" 0
if [[ "$(sed -n 3p <<<"$calls")" == "deploy-dark dev $sha" ]]; then pass "baseline URL unreadable: no baseline smoke"; else fail "baseline URL unreadable: calls $(tr '\n' ';' <<<"$calls")"; fi

# --- revert itself fails
run revfail SMOKE_FAIL_AFTER=3 REVERT_FAIL=1
if [[ "$rc" == 1 ]] && grep -q "revert failed; manual action needed" "$tmp/err.revfail"; then pass "failed revert: logs it and exits 1"; else fail "failed revert (rc $rc)"; fi

# --- the live URL's trailing slash is stripped before /health
run slash
has "trailing slash: /health has a single slash" "curl https://live.example/health"

# --- fail closed without a stack smoke suite
printf 'target: cloud-run\n' >"$tmp/nostack.yml"
export CALLS="$tmp/calls.nostack"
: >"$CALLS"
rc=0
env -u SMOKE_CMD DEPLOY_CONFIG="$tmp/nostack.yml" "$release" dev "$sha" 2>"$tmp/err.nostack" || rc=$?
calls="$(cat "$CALLS")"
if [[ "$rc" == 1 && -z "$calls" ]] && grep -q "no smoke suite" "$tmp/err.nostack"; then pass "no stack smoke suite: refuses before deploying anything"; else fail "no stack smoke suite (rc $rc, calls [$calls])"; fi
printf 'target: cloud-run\nstack: node\n' >"$tmp/stack.yml"
rc=0
env -u SMOKE_CMD DEPLOY_CONFIG="$tmp/stack.yml" "$release" dev "$sha" >/dev/null 2>"$tmp/err.stack" || rc=$?
if ! grep -q "no smoke suite" "$tmp/err.stack"; then pass "a stack in deploy.yml passes the smoke-suite check"; else fail "stack present but refused"; fi

# --- a failing dark deploy is discarded, never promoted
run darkfail DARK_FAIL=1
rc_is "failed dark deploy: exits 1" 1
has "failed dark deploy: discards the candidate" "discard dev $sha"
lacks "failed dark deploy: never promotes" "promote"

# --- live checks must fit the job timeout
rc=0
RELEASE_LIVE_CHECKS=12 RELEASE_INTERVAL=60 "$release" dev "$sha" >/dev/null 2>&1 || rc=$?
rc_is "rejects live checks longer than 10 minutes with 64" 64

# --- the re-check after revert asks for the live URL again (targets whose
# URL follows the serving revision, like the test-only local target)
run follows URL_FOLLOWS_REVERT=1 SMOKE_FAIL_NTH=4
has "revert re-check: uses the URL after revert" "smoke https://prev.example"
if grep -q "^::error.*(revert confirmed)" "$tmp/out.follows"; then pass "revert re-check: confirmed against the restored URL"; else fail "revert re-check: not confirmed"; fi

# --- argument validation
for args in "staging $sha" "dev not-a-sha" "dev"; do
  rc=0
  # shellcheck disable=SC2086 # split the pair on purpose
  "$release" $args >/dev/null 2>&1 || rc=$?
  rc_is "rejects '$args' with 64" 64
done
rc=0
RELEASE_LIVE_CHECKS=0 "$release" dev "$sha" >/dev/null 2>&1 || rc=$?
rc_is "rejects RELEASE_LIVE_CHECKS=0 with 64" 64

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
