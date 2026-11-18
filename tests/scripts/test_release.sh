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
  url) if [[ -n "${URL_FOLLOWS_REVERT:-}" && -e "$CALLS.reverted" ]]; then echo "https://prev.example/"; else echo "https://live.example/"; fi ;;
esac
EOF
# Fake smoke: fails for the URL in SMOKE_FAIL_URL; with SMOKE_FAIL_AFTER=n,
# fails from the (n+1)th call on.
cat >"$tmp/smoke" <<'EOF'
#!/usr/bin/env bash
echo "smoke $1" >>"$CALLS"
n=$(($(cat "$COUNT" 2>/dev/null || echo 0) + 1)); echo "$n" >"$COUNT"
[[ "$1" == "${SMOKE_FAIL_URL:-}" ]] && exit 1
[[ -n "${SMOKE_FAIL_AFTER:-}" && "$n" -gt "$SMOKE_FAIL_AFTER" ]] && exit 1
[[ -n "${SMOKE_FAIL_NTH:-}" && "$n" == "$SMOKE_FAIL_NTH" ]] && exit 1
exit 0
EOF
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
echo "curl $url" >>"$CALLS"
[[ "$url" == "${CURL_FAIL_URL:-}" ]] && exit 22
exit 0
EOF
chmod +x "$tmp/deploy.sh" "$tmp/smoke" "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" DEPLOY_SH="$tmp/deploy.sh" SMOKE_CMD="$tmp/smoke" RELEASE_INTERVAL=0
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

# --- live failure on the 2nd check: revert to PREV and re-check
run live SMOKE_FAIL_AFTER=2
rc_is "live failure: exits 1" 1
has "live failure: reverts to the previous revision" "revert dev svc-00001-old"
lacks "live failure: no cleanup" "cleanup"
lacks "live failure: no discard" "discard"
count_is "live failure: re-checks once after revert" "smoke https://live.example" 3

# --- /health failure counts as a live failure
run health CURL_FAIL_URL=https://live.example/health
rc_is "health failure: exits 1" 1
has "health failure: reverts" "revert dev svc-00001-old"

# --- live checks count comes from RELEASE_LIVE_CHECKS
run five RELEASE_LIVE_CHECKS=5
count_is "live checks: honours RELEASE_LIVE_CHECKS" "curl https://live.example/health" 5

# --- no dark deploy (C9): promote is the deploy
run nodark RELEASE_DARK_DEPLOY=false
rc_is "no dark deploy: exits 0" 0
lacks "no dark deploy: skips deploy-dark" "deploy-dark"
has "no dark deploy: promotes" "promote dev $sha"
has "no dark deploy: cleans up" "cleanup dev"
# C9: without a dark deploy, the pre-traffic test runs against the artifact
# served locally (`deploy.sh preview`), which is stopped before the deploy.
want="current dev
preview dev $sha
smoke http://127.0.0.1:9999/
discard dev $sha
promote dev $sha"
got="$(head -n 5 <<<"$calls")"
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
lacks "no previous revision: no cleanup" "cleanup"

# --- revert whose re-check fails
run recheck SMOKE_FAIL_AFTER=2
if grep -q "revert did not pass the live check" "$tmp/err.recheck"; then pass "failed re-check after revert: says manual action is needed"; else fail "failed re-check: no message"; fi
rc_is "failed re-check after revert: exits 1" 1
if grep -q "^::error.*NOT confirmed" "$tmp/out.recheck"; then pass "failed re-check: annotates the revert as not confirmed"; else fail "failed re-check: no annotation"; fi
# Only the 2nd live check (3rd smoke call) fails; the re-check after revert passes.
run confirm SMOKE_FAIL_NTH=3
rc_is "confirmed revert: still exits 1" 1
if grep -q "^::error.*(revert confirmed)" "$tmp/out.confirm"; then pass "confirmed revert: annotated as confirmed"; else fail "confirmed revert: no annotation"; fi

# --- revert itself fails
run revfail SMOKE_FAIL_AFTER=2 REVERT_FAIL=1
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
run follows URL_FOLLOWS_REVERT=1 SMOKE_FAIL_NTH=3
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
