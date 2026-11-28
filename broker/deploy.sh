#!/usr/bin/env bash
# Build and deploy the broker to Cloud Run, or flip its kill switch (spec 0004
# FR-5, FR-6, Deploy). The owner runs it with their own gcloud login:
#
#   BROKER_PROJECT=<P> broker/deploy.sh             # build from broker/ and deploy
#   BROKER_PROJECT=<P> broker/deploy.sh --disable   # kill switch on: every request gets 503 disabled
#   BROKER_PROJECT=<P> broker/deploy.sh --enable    # kill switch off
#
# A plain deploy keeps the live BROKER_ENABLED, so it never turns a disabled
# broker back on (FR-5). It pins the newest enabled version of each secret,
# never "latest" (C8): after put-secret.sh that is the new version. To roll a
# key back before --prune, disable the new version
# (gcloud secrets versions disable <n> --secret <s> --project <P>) and deploy.
# --enable and --disable make a new revision with the one variable changed and
# no rebuild. Every run ends by checking /healthz and that there are no
# traffic tags. The broker is never deployed from CI.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=broker/lib.sh disable=SC1091
source "$here/lib.sh"

mode=deploy
case "${1:-}" in
  "") ;;
  --enable) mode=enable ;;
  --disable) mode=disable ;;
  *)
    echo "usage: BROKER_PROJECT=<project> $0 [--enable|--disable]" >&2
    exit 64
    ;;
esac
(($# <= 1)) || { echo "usage: BROKER_PROJECT=<project> $0 [--enable|--disable]" >&2; exit 64; }

config="${BROKER_CONFIG:-$here/config.yaml}"

init_project
require_label
require_clean

fixture_service='{"spec":{"template":{"spec":{"containers":[{"env":[{"name":"BROKER_ENABLED","value":"true"}]}]}}}}'
live="$(query "${BROKER_FIXTURE_SERVICE_JSON-$fixture_service}" \
  gcloud run services describe "$SERVICE" --project "$P" --region "$REGION" --format json 2>/dev/null || true)"
live_enabled="$(jq -r '[.spec.template.spec.containers[0].env[]? | select(.name == "BROKER_ENABLED") | .value][0] // empty' \
  <<<"${live:-null}" 2>/dev/null || true)"

# no_tags: the service has no traffic tags (FR-1). A tag gives an old
# revision, with its old keys, a URL of its own.
no_tags() {
  local tags
  tags="$(query "${BROKER_FIXTURE_TAGS-}" \
    gcloud run services describe "$SERVICE" --project "$P" --region "$REGION" --format "value(status.traffic[].tag)")"
  [[ -z "${tags//[[:space:];]/}" ]] ||
    die "the service has traffic tags ($tags); remove them (gcloud run services update-traffic $SERVICE --clear-tags)"
}

# check_live <want-enabled>: no traffic tags, and /healthz answers with that
# value.
check_live() {
  local want="$1" url health
  url="$(query "${BROKER_FIXTURE_URL-https://agent-bot-broker-123456789012.us-west1.run.app}" \
    gcloud run services describe "$SERVICE" --project "$P" --region "$REGION" --format "value(status.url)")"
  [[ "$url" == https://* ]] || die "no service URL"
  no_tags
  health="$(query "{\"ok\":true,\"enabled\":$want}" curl -fsS --max-time 30 "$url/healthz")" ||
    die "$url/healthz didn't answer"
  jq -e --argjson w "$want" '.ok == true and .enabled == $w' <<<"$health" >/dev/null ||
    die "$url/healthz answered $health, expected enabled $want"
  say "$url/healthz: $health"
  echo "$url"
}

[[ -z "$live_enabled" ]] || no_tags

if [[ "$mode" != deploy ]]; then
  [[ -n "$live_enabled" ]] || die "$SERVICE isn't deployed in $P/$REGION yet; run broker/deploy.sh first"
  want=true
  [[ "$mode" == enable ]] || want=false
  run gcloud run services update "$SERVICE" --project "$P" --region "$REGION" \
    --update-env-vars "BROKER_ENABLED=$want" --quiet
  check_live "$want"
  exit 0
fi

# --- a plain deploy
[[ -f "$config" ]] || die "no $config"
! grep -q 'BROKER_ENABLED' "$config" || die "$config must not set BROKER_ENABLED (deploy.sh keeps the live value)"
enabled="${live_enabled:-true}"
[[ "$enabled" == true || "$enabled" == false ]] || die "live BROKER_ENABLED is '$enabled'"
say "BROKER_ENABLED stays $enabled"

pins=()
for s in "${SECRETS[@]}"; do
  v="$(query "${BROKER_FIXTURE_VERSION-1}" \
    gcloud secrets versions list "$s" --project "$P" --filter "state=ENABLED" \
    --sort-by "~createTime" --limit 1 --format "value(name)")"
  v="${v##*/}"
  [[ "$v" =~ ^[0-9]+$ ]] || die "$s has no enabled version; load it with broker/put-secret.sh $s <file>"
  pins+=("$(secret_env "$s")=$s:$v")
done
pinned="$(IFS=,; echo "${pins[*]}")"
say "secrets: $pinned"

# --env-vars-file replaces every variable, so the file carries the live value.
envfile="$(mktemp)"
trap 'rm -f "$envfile"' EXIT
{
  cat "$config"
  printf '\nBROKER_ENABLED: "%s"\n' "$enabled"
} >"$envfile"
say "env file: config.yaml + BROKER_ENABLED=$enabled"

run gcloud run deploy "$SERVICE" --source "$here" --project "$P" --region "$REGION" \
  --service-account "$BROKER_SA" \
  --build-service-account "projects/$P/serviceAccounts/$BUILDER_SA" \
  --env-vars-file "$envfile" --set-secrets "$pinned" \
  --max-instances 1 --cpu 1 --memory 512Mi --concurrency 80 --timeout 60 \
  --allow-unauthenticated --clear-base-image --quiet
check_live "$enabled"
