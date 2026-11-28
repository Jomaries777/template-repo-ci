#!/usr/bin/env bash
# broker/deploy.sh in DRY_RUN=1 (spec 0004 FR-5, FR-6, criteria 5 and 9).
# gcloud and curl are stubs that fail, so nothing real runs.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
script="$root/broker/deploy.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
for t in gcloud curl; do
  printf '#!/usr/bin/env bash\necho "real %s called" >&2\nexit 99\n' "$t" >"$tmp/bin/$t"
  chmod +x "$tmp/bin/$t"
done
P="agent-bot-broker-t1"
cat >"$tmp/config.yaml" <<'EOF'
OWNER_LOGIN: "acme"
CLAUDE_APP_ID: "1"
EOF

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
  out="$(env PATH="$tmp/bin:$PATH" DRY_RUN=1 BROKER_PROJECT="$P" BROKER_CONFIG="$tmp/config.yaml" \
    ${envs[@]+"${envs[@]}"} "$script" ${@+"$@"} 2>&1)" || rc=$?
}
has() { if grep -qF -- "$2" <<<"$out"; then ok "$1"; else nok "$1 (missing: $2)"; fi; }
svc() { # svc <enabled>
  printf '{"spec":{"template":{"spec":{"containers":[{"env":[{"name":"BROKER_ENABLED","value":"%s"}]}]}}}}' "$1"
}

# A plain deploy.
go --
if [[ "$rc" == 0 ]]; then ok "deploy: dry run exits 0"; else nok "deploy: dry run exits 0 (rc $rc): $out"; fi
if grep -q 'real .* called' <<<"$out"; then nok "deploy: no real tool runs"; else ok "deploy: no real tool runs"; fi
lines="$(grep '^DRY-RUN: gcloud' <<<"$out")"
if ! grep -v -- "--project $P" <<<"$lines" | grep -q .; then ok "deploy: every gcloud line passes --project"; else nok "deploy: every gcloud line passes --project"; fi
regional="$(grep -E 'run deploy|run services (describe|update)' <<<"$lines")"
if [[ -n "$regional" ]] && ! grep -v -- '--region us-west1' <<<"$regional" | grep -q .; then
  ok "deploy: every regional line uses us-west1"
else
  nok "deploy: every regional line uses us-west1"
fi
d="$(grep 'DRY-RUN: gcloud run deploy' <<<"$out" || true)"
for want in "--source $root/broker" "--service-account broker@$P.iam.gserviceaccount.com" \
  "--build-service-account projects/$P/serviceAccounts/builder@$P.iam.gserviceaccount.com" \
  "--max-instances 1" "--allow-unauthenticated" "--clear-base-image" "--env-vars-file"; do
  if grep -qF -- "$want" <<<"$d"; then ok "deploy: run deploy has $want"; else nok "deploy: run deploy has $want"; fi
done
pins="CLAUDE_KEY_PKCS8=claude-key:1\,AGY_KEY_PKCS8=agy-key:1\,CI_KEY_PKCS8=ci-key:1\,LOGIN_CLIENT_SECRET=login-client-secret:1"
if grep -qF -- "--set-secrets $pins" <<<"$d"; then ok "deploy: pins numbered secret versions"; else nok "deploy: pins numbered secret versions: $d"; fi
if grep -q 'latest' <<<"$d"; then nok "deploy: never latest"; else ok "deploy: never latest"; fi
if grep -q -- '--min-instances\|--tag\|--no-traffic' <<<"$d"; then nok "deploy: no min instances or tags"; else ok "deploy: no min instances or tags"; fi
has "deploy: keeps BROKER_ENABLED=true" "env file: config.yaml + BROKER_ENABLED=true"
has "deploy: checks /healthz" "DRY-RUN: curl -fsS --max-time 30 https://agent-bot-broker-123456789012.us-west1.run.app/healthz"
has "deploy: checks traffic tags" "--format value\(status.traffic\[\].tag\)"

# FR-5: a plain deploy while disabled stays disabled.
go "BROKER_FIXTURE_SERVICE_JSON=$(svc false)" --
if [[ "$rc" == 0 ]] && grep -qF "env file: config.yaml + BROKER_ENABLED=false" <<<"$out" && ! grep -q 'BROKER_ENABLED=true' <<<"$out"; then
  ok "deploy: plain deploy keeps disabled"
else
  nok "deploy: plain deploy keeps disabled (rc $rc): $out"
fi
# First deploy (no service yet): enabled.
go "BROKER_FIXTURE_SERVICE_JSON=" --
has "deploy: first deploy is enabled" "BROKER_ENABLED=true"

# Kill switch.
go -- --disable
if [[ "$rc" == 0 ]]; then ok "disable: exits 0"; else nok "disable: exits 0 (rc $rc): $out"; fi
has "disable: new revision with BROKER_ENABLED=false" "run services update agent-bot-broker --project $P --region us-west1 --update-env-vars BROKER_ENABLED=false"
if grep -q 'run deploy' <<<"$out"; then nok "disable: no rebuild"; else ok "disable: no rebuild"; fi
go -- --enable
has "enable: BROKER_ENABLED=true" "--update-env-vars BROKER_ENABLED=true"
go "BROKER_FIXTURE_SERVICE_JSON=" -- --disable
if [[ "$rc" != 0 ]] && ! grep -q 'services update' <<<"$out"; then ok "disable: refuses before the first deploy"; else nok "disable: refuses before the first deploy"; fi

# Refusals.
refuse() { # name want-text env... -- args...
  local name="$1" want="$2"
  shift 2
  go "$@"
  if [[ "$rc" != 0 ]] && grep -qF -- "$want" <<<"$out" && ! grep -q 'DRY-RUN: gcloud run deploy\|DRY-RUN: gcloud run services update ' <<<"$out"; then
    ok "deploy: refuses $name"
  else
    nok "deploy: refuses $name (rc $rc): $out"
  fi
}
refuse "a project without the label" "has no label" BROKER_FIXTURE_LABEL= --
refuse "a workload identity pool" "workload identity pool" BROKER_FIXTURE_POOLS=pool --
refuse "another Cloud Run service" "another Cloud Run service" "BROKER_FIXTURE_SERVICES=agent-bot-broker web" --
refuse "a user-managed key" "user-managed key" BROKER_FIXTURE_KEYS=k --
refuse "a secret with no enabled version" "has no enabled version" BROKER_FIXTURE_VERSION= --
refuse "traffic tags" "traffic tags" BROKER_FIXTURE_TAGS=canary --
printf 'BROKER_ENABLED: "true"\n' >"$tmp/bad.yaml"
refuse "a config that sets BROKER_ENABLED" "must not set BROKER_ENABLED" "BROKER_CONFIG=$tmp/bad.yaml" --
refuse "an unknown flag" "usage" -- --force

# The real config, once it exists, has no secret and no BROKER_ENABLED.
if [[ -f "$root/broker/config.yaml" ]]; then
  if grep -qiE 'BROKER_ENABLED|KEY_PKCS8|CLIENT_SECRET' "$root/broker/config.yaml"; then
    nok "config.yaml: no BROKER_ENABLED or secret"
  else
    ok "config.yaml: no BROKER_ENABLED or secret"
  fi
fi

exit "$fail"
