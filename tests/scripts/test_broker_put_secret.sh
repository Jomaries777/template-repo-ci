#!/usr/bin/env bash
# broker/put-secret.sh in DRY_RUN=1 (spec 0004 FR-6, criterion 9). gcloud is a
# stub that fails, so nothing real runs. The test key is made at run time.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
script="$root/broker/put-secret.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
for t in gcloud curl; do
  printf '#!/usr/bin/env bash\necho "real %s called" >&2\nexit 99\n' "$t" >"$tmp/bin/$t"
  chmod +x "$tmp/bin/$t"
done
P="agent-bot-broker-t1"

ok() { echo "ok - $1"; }
nok() {
  echo "not ok - $1"
  fail=1
}
go() { # go <env...> -- <args...>
  local envs=()
  while (($#)) && [[ "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  shift
  rc=0
  out="$(env PATH="$tmp/bin:$PATH" DRY_RUN=1 BROKER_PROJECT="$P" ${envs[@]+"${envs[@]}"} "$script" "$@" 2>&1)" || rc=$?
}
has() { if grep -qF -- "$2" <<<"$out"; then ok "$1"; else nok "$1 (missing: $2)"; fi; }

openssl genrsa -out "$tmp/k.pem" 2048 2>/dev/null
# A line from the middle of the key: it must never appear in any output.
probe="$(sed -n 5p "$tmp/k.pem")"
no_key() {
  if grep -qF -- "$probe" <<<"$out" || grep -q 'PRIVATE KEY' <<<"$out"; then nok "$1: no key material in output"; else ok "$1: no key material in output"; fi
}

# A good key.
cp "$tmp/k.pem" "$tmp/a.pem"
go -- claude-key "$tmp/a.pem"
if [[ "$rc" == 0 ]]; then ok "key: dry run exits 0"; else nok "key: dry run exits 0 (rc $rc): $out"; fi
has "key: adds a version on stdin, with --project" "DRY-RUN: gcloud secrets versions add claude-key --project $P --data-file=-"
has "key: deletes the file" "DRY-RUN: rm -f $tmp/a.pem"
if [[ -f "$tmp/a.pem" ]]; then ok "key: dry run leaves the file"; else nok "key: dry run leaves the file"; fi
if grep -qx '0' <<<"$out"; then ok "key: prints the version number"; else nok "key: prints the version number"; fi
no_key "key"
if grep -q 'real .* called' <<<"$out"; then nok "key: no real gcloud"; else ok "key: no real gcloud"; fi
lines="$(grep '^DRY-RUN: gcloud' <<<"$out")"
if ! grep -v -- "--project $P" <<<"$lines" | grep -q .; then ok "key: every gcloud line passes --project"; else nok "key: every gcloud line passes --project"; fi

# Already PKCS#8 works too.
openssl pkcs8 -topk8 -nocrypt -in "$tmp/k.pem" -out "$tmp/p8.pem"
go -- agy-key "$tmp/p8.pem"
if [[ "$rc" == 0 ]]; then ok "pkcs8 key: accepted"; else nok "pkcs8 key: accepted (rc $rc): $out"; fi
no_key "pkcs8 key"

# Refusals.
refuse() { # name want-text args...
  local name="$1" want="$2"
  shift 2
  go -- "$@"
  if [[ "$rc" != 0 ]] && grep -qF -- "$want" <<<"$out" && ! grep -q 'versions add' <<<"$out"; then
    ok "refuses $name"
  else
    nok "refuses $name (rc $rc): $out"
  fi
  no_key "refuses $name"
}
: >"$tmp/empty.pem"
refuse "an empty file" "is empty" ci-key "$tmp/empty.pem"
printf 'hello, not a key\n' >"$tmp/text.pem"
refuse "a non-PEM file" "is not a PEM private key" ci-key "$tmp/text.pem"
openssl rsa -in "$tmp/k.pem" -pubout -out "$tmp/pub.pem" 2>/dev/null
refuse "a public key" "is not a PEM private key" ci-key "$tmp/pub.pem"
{ head -3 "$tmp/k.pem"; tail -1 "$tmp/k.pem"; } >"$tmp/broken.pem"
refuse "a truncated key" "refusing" claude-key "$tmp/broken.pem"
refuse "a missing file" "no such file" claude-key "$tmp/none.pem"
refuse "an unknown secret" "unknown secret" other-key "$tmp/k.pem"
printf '\n\n' >"$tmp/blank.txt"
refuse "a blank login secret" "only whitespace" login-client-secret "$tmp/blank.txt"
refuse "a key as the login secret" "looks like a private key" login-client-secret "$tmp/k.pem"
go BROKER_FIXTURE_LABEL= -- claude-key "$tmp/k.pem"
if [[ "$rc" != 0 ]] && grep -q 'has no label' <<<"$out"; then ok "refuses a project without the label"; else nok "refuses a project without the label"; fi

# The login client secret, plain text.
printf 'abc123def456\n' >"$tmp/login.txt"
go -- login-client-secret "$tmp/login.txt"
if [[ "$rc" == 0 ]] && ! grep -q 'abc123def456' <<<"$out"; then ok "login secret: accepted, value not printed"; else nok "login secret: accepted, value not printed"; fi

# --prune keeps only the version the live service pins.
svc='{"spec":{"template":{"spec":{"containers":[{"env":[
  {"name":"CLAUDE_KEY_PKCS8","valueFrom":{"secretKeyRef":{"name":"claude-key","key":"3"}}},
  {"name":"BROKER_ENABLED","value":"true"}]}]}}}}'
vers="$(printf 'projects/%s/secrets/claude-key/versions/%s\n' "$P" 4 "$P" 3 "$P" 2)"
go "BROKER_FIXTURE_SERVICE_JSON=$svc" "BROKER_FIXTURE_VERSIONS=$vers" -- --prune claude-key
if [[ "$rc" == 0 ]]; then ok "prune: exits 0"; else nok "prune: exits 0 (rc $rc): $out"; fi
has "prune: destroys 4" "secrets versions destroy 4 --secret claude-key --project $P"
has "prune: destroys 2" "secrets versions destroy 2 --secret claude-key --project $P"
if grep -q 'versions destroy 3 ' <<<"$out"; then nok "prune: keeps the pinned 3"; else ok "prune: keeps the pinned 3"; fi
has "prune: describes the service in us-west1" "run services describe agent-bot-broker --project $P --region us-west1"
go "BROKER_FIXTURE_SERVICE_JSON=$svc" "BROKER_FIXTURE_VERSIONS=$vers" -- --prune agy-key
if [[ "$rc" != 0 ]] && ! grep -q 'versions destroy' <<<"$out"; then ok "prune: refuses a secret the service doesn't pin"; else nok "prune: refuses a secret the service doesn't pin"; fi
go "BROKER_FIXTURE_SERVICE_JSON=" -- --prune claude-key
if [[ "$rc" != 0 ]] && ! grep -q 'versions destroy' <<<"$out"; then ok "prune: refuses with no live service"; else nok "prune: refuses with no live service"; fi

exit "$fail"
