#!/usr/bin/env bash
# Release one commit to one environment (spec §4.10, FR-9). Shell only, no AI.
# Called by the .github/actions/release composite; runnable locally.
#
# Usage: scripts/release.sh <env> <sha>
#
#   1. PREV=$(deploy.sh current <env>)
#   2. dark deploy: CANDIDATE_URL=$(deploy.sh deploy-dark <env> <sha>)
#   3. pre-traffic test: make smoke URL=$CANDIDATE_URL; on failure discard, fail
#   4. promote
#   5. live test: smoke + /healthz, RELEASE_LIVE_CHECKS times, RELEASE_INTERVAL s apart
#   6. on live failure: revert to PREV, re-check once, fail
#   7. cleanup
#
# With RELEASE_DARK_DEPLOY=false (adapters without dark deploys, C9) steps 2-3
# are skipped here and step 4 is the deploy; a local pre-traffic test belongs
# to such an adapter.
#
# Env: RELEASE_LIVE_CHECKS (default 3), RELEASE_INTERVAL (seconds, default 60),
#      RELEASE_DARK_DEPLOY (default true),
#      DEPLOY_SH (default scripts/deploy.sh), SMOKE_CMD (default: make smoke URL=)
set -euo pipefail

env_name="${1:-}"
sha="${2:-}"
case "$env_name" in
  dev | production) ;;
  *)
    echo "release: environment must be dev or production, got: ${env_name:-<empty>}" >&2
    exit 64
    ;;
esac
[[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || {
  echo "release: invalid commit sha: ${sha:-<empty>}" >&2
  exit 64
}

root="$(cd "$(dirname "$0")/.." && pwd)"
deploy_sh="${DEPLOY_SH:-$root/scripts/deploy.sh}"
checks="${RELEASE_LIVE_CHECKS:-3}"
interval="${RELEASE_INTERVAL:-60}"
dark="${RELEASE_DARK_DEPLOY:-true}"
[[ "$checks" =~ ^[1-9][0-9]?$ ]] || {
  echo "release: invalid RELEASE_LIVE_CHECKS: $checks" >&2
  exit 64
}
[[ "$interval" =~ ^[0-9]{1,3}$ ]] || {
  echo "release: invalid RELEASE_INTERVAL: $interval" >&2
  exit 64
}

log() { echo "release[$env_name]: $*" >&2; }

smoke() {
  if [[ -n "${SMOKE_CMD:-}" ]]; then
    # SMOKE_CMD is a test hook: a command that takes the URL as its argument.
    "$SMOKE_CMD" "$1"
  else
    make -C "$root" smoke URL="$1"
  fi
}

# One live check: the prod-safe smoke suite plus /healthz.
live_check() {
  smoke "$1" && curl -fsS --max-time 10 -o /dev/null "$1/healthz"
}

# Fail closed: without the stack's prod-safe suite (bootstrap writes `stack:`
# to deploy.yml), the template's stub `make smoke` would pass vacuously.
config="${DEPLOY_CONFIG:-$root/deploy.yml}"
if [[ -z "${SMOKE_CMD:-}" ]] && ! grep -qE '^stack:[[:space:]]*[a-z0-9-]+' "$config" 2>/dev/null; then
  log "no smoke suite: $config names no stack (run make bootstrap); refusing to deploy"
  exit 1
fi

log "1/7 current revision"
prev="$("$deploy_sh" current "$env_name")"
log "serving now: ${prev:-<none>}"

if [[ "$dark" == true ]]; then
  log "2/7 dark deploy of $sha"
  candidate="$("$deploy_sh" deploy-dark "$env_name" "$sha")"
  [[ -n "$candidate" ]] || {
    log "deploy-dark printed no candidate URL"
    "$deploy_sh" discard "$env_name" "$sha" || true
    exit 1
  }
  log "3/7 pre-traffic test against $candidate"
  if ! smoke "$candidate"; then
    log "pre-traffic test failed: discarding the candidate; no traffic was sent"
    "$deploy_sh" discard "$env_name" "$sha" || log "discard failed"
    exit 1
  fi
else
  log "2-3/7 skipped: this target has no dark deploy"
fi

log "4/7 promote $sha"
"$deploy_sh" promote "$env_name" "$sha"

url="$("$deploy_sh" url "$env_name")"
url="${url%/}"
log "5/7 live test against $url ($checks checks, ${interval}s apart)"
failed=0
for ((i = 1; i <= checks; i++)); do
  if ! live_check "$url"; then
    log "live check $i/$checks failed"
    failed=1
    break
  fi
  log "live check $i/$checks passed"
  if ((i < checks)); then sleep "$interval"; fi
done

if ((failed)); then
  if [[ -z "$prev" ]]; then
    log "6/7 no previous revision to revert to; manual action needed"
    exit 1
  fi
  log "6/7 reverting to $prev"
  if ! "$deploy_sh" revert "$env_name" "$prev"; then
    log "revert failed; manual action needed"
    exit 1
  fi
  if live_check "$url"; then
    log "revert confirmed: $prev is serving and healthy"
  else
    log "revert did not pass the live check; manual action needed"
  fi
  exit 1
fi

log "7/7 cleanup"
"$deploy_sh" cleanup "$env_name"
log "released $sha"
