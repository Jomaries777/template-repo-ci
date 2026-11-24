#!/usr/bin/env bash
# Release one commit to one environment (spec §4.10, FR-9). Shell only, no AI.
# Called by the .github/actions/release composite; runnable locally.
#
# Usage: scripts/release.sh <env> <sha>
#
#   1. PREV=$(deploy.sh current <env>); baseline: one live test of PREV
#   2. dark deploy: CANDIDATE_URL=$(deploy.sh deploy-dark <env> <sha>)
#   3. pre-traffic test: make smoke URL=$CANDIDATE_URL; on failure discard, fail
#   4. promote
#   5. live test: smoke + /health, RELEASE_LIVE_CHECKS times, RELEASE_INTERVAL s apart
#   6. on live failure: revert to PREV, re-check once, fail (the baseline
#      only words a failed re-check: "fix forward" when PREV failed it too,
#      unless /health passed at the baseline and fails after the revert)
#   7. cleanup
#
# With RELEASE_DARK_DEPLOY=false (adapters without dark deploys, C9), step 2
# is `deploy.sh preview <env> <sha>`, which serves the artifact on localhost
# inside the job and prints its URL; step 3 smokes that URL, then `discard`
# stops it; step 4 (promote) is the deploy.
#
# Env: RELEASE_LIVE_CHECKS (default 3), RELEASE_INTERVAL (seconds, default 60),
#      RELEASE_DARK_DEPLOY (default true), RELEASE_BASELINE_RETRY_DELAY
#      (seconds before the baseline's one retry, default 10),
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
# The dev and production jobs time out at 20 minutes. Live checks run after
# promote, so a timeout mid-checks would leave the new version live without
# a revert: keep them within 10 minutes.
if (((checks - 1) * interval > 600)); then
  echo "release: $checks live checks ${interval}s apart exceed 10 minutes" >&2
  exit 64
fi

log() { echo "release[$env_name]: $*" >&2; }

smoke() {
  if [[ -n "${SMOKE_CMD:-}" ]]; then
    # SMOKE_CMD is a test hook: a command that takes the URL as its argument.
    "$SMOKE_CMD" "$1"
  else
    make -C "$root" smoke URL="$1"
  fi
}

health_ok() {
  curl -fsS --max-time 10 -o /dev/null "$1/health"
}

# One live check: the prod-safe smoke suite plus /health.
live_check() {
  smoke "$1" && health_ok "$1"
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

# Baseline: is the serving version healthy under this commit's live test? A
# first deploy's PREV is bootstrap's placeholder (503 on Workers, Google's
# sample image on Cloud Run), which never passes, so a failed re-check after
# reverting to it says "fix forward", not "manual action needed". It only
# picks that wording: the re-check always runs, because the baseline uses
# this commit's suite and a healthy PREV fails a smoke test the release adds
# (review of #64). It never fails a release, and an unreadable URL counts as
# healthy. A failure is retried once, so one transient failure can't turn
# "manual action needed" into "fix forward".
prev_healthy=1
prev_health_ok=1
baseline_delay="${RELEASE_BASELINE_RETRY_DELAY:-10}"
[[ "$baseline_delay" =~ ^[0-9]{1,2}$ ]] || {
  echo "release: invalid RELEASE_BASELINE_RETRY_DELAY (0-99 seconds): $baseline_delay" >&2
  exit 64
}
if [[ -n "$prev" ]]; then
  base_url="$("$deploy_sh" url "$env_name")" || base_url=""
  base_url="${base_url%/}"
  if [[ -n "$base_url" ]] && ! live_check "$base_url"; then
    log "baseline: the serving version failed the live check; retrying once in ${baseline_delay}s"
    sleep "$baseline_delay"
    if live_check "$base_url"; then
      log "baseline: passed on retry: the serving version is flaky ($prev at $base_url)"
    else
      prev_healthy=0
      # /health doesn't depend on this commit's smoke tests, so it tells a
      # revert that lost service from a PREV that only fails new tests.
      # Retried once, like the smoke baseline (review of #68).
      if ! health_ok "$base_url"; then
        sleep "$baseline_delay"
        health_ok "$base_url" || prev_health_ok=0
      fi
      log "baseline: the serving version is not healthy before this release ($prev at $base_url; /health $( ((prev_health_ok)) && echo passed || echo failed))"
    fi
  fi
fi

if [[ "$dark" == true ]]; then
  log "2/7 dark deploy of $sha"
  # A failed or half-done dark deploy is discarded too: no candidate is left
  # behind (it receives no traffic either way).
  if ! candidate="$("$deploy_sh" deploy-dark "$env_name" "$sha")" || [[ -z "$candidate" ]]; then
    log "dark deploy failed or printed no candidate URL: discarding; no traffic was sent"
    "$deploy_sh" discard "$env_name" "$sha" || log "discard failed"
    exit 1
  fi
  log "3/7 pre-traffic test against $candidate"
  if ! smoke "$candidate"; then
    log "pre-traffic test failed: discarding the candidate; no traffic was sent"
    "$deploy_sh" discard "$env_name" "$sha" || log "discard failed"
    exit 1
  fi
else
  # C9: no dark deploy on this target, so the pre-traffic test runs against
  # the artifact served locally inside the job (`deploy.sh preview`), which
  # is stopped (discard) before the deploy.
  log "2/7 no dark deploy: serving $sha locally"
  if ! candidate="$("$deploy_sh" preview "$env_name" "$sha")" || [[ -z "$candidate" ]]; then
    log "local preview failed or printed no URL: not deploying"
    "$deploy_sh" discard "$env_name" "$sha" || log "discard failed"
    exit 1
  fi
  log "3/7 pre-traffic test against the local preview $candidate"
  preview_ok=1
  smoke "$candidate" || preview_ok=0
  "$deploy_sh" discard "$env_name" "$sha" || log "stopping the local preview failed"
  if ((!preview_ok)); then
    log "pre-traffic test failed: not deploying; nothing changed on the target"
    exit 1
  fi
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
  # Ask again: on some targets the live URL follows the serving revision.
  url="$("$deploy_sh" url "$env_name")" || url=""
  url="${url%/}"
  if [[ -n "$url" ]] && live_check "$url"; then
    log "revert confirmed: $prev is serving and healthy"
    # Annotations let the report issue and triage tell the two outcomes apart.
    echo "::error title=release $env_name::live test failed; reverted to $prev (revert confirmed)"
  elif ((!prev_healthy)) && [[ -n "$url" ]] && { ((!prev_health_ok)) || health_ok "$url"; }; then
    # PREV failed the baseline too, and /health is no worse than before.
    log "revert did not pass the live check; reverted to $prev, which was not healthy before this release either (on a first deploy, bootstrap's placeholder): fix forward"
    echo "::error title=release $env_name::live test failed; reverted to $prev, which was not healthy before this release either (on a first deploy, bootstrap's placeholder): fix forward"
  else
    if ((!prev_healthy && prev_health_ok)); then
      log "the revert lost service: /health passed before this release and fails now (or the URL is unreadable)"
    fi
    log "revert did not pass the live check; manual action needed"
    echo "::error title=release $env_name::live test failed; reverted to $prev but the revert is NOT confirmed healthy: manual action needed"
  fi
  exit 1
fi

log "7/7 cleanup"
"$deploy_sh" cleanup "$env_name"
log "released $sha"
