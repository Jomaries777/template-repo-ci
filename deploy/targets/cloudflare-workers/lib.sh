#!/usr/bin/env bash
# Shared helpers for the cloudflare-workers deploy adapter (spec §4.11, C10).
# Sourced by every verb. Contract: a verb prints only its result (a URL or a
# version ID) on stdout; progress, wrangler output and DRY-RUN lines go to
# stderr, so release.sh can capture results with $(...).
#
# Node stack only (target.yml `stacks:`): the Worker is the stack's
# src/worker.ts, which shares route() with the HTTP server.
#
# Credentials: CLOUDFLARE_API_TOKEN (an Environment secret, readable only by
# the dev and production jobs) and CLOUDFLARE_ACCOUNT_ID (a repo variable).
# wrangler reads both from the environment; neither is ever printed.
#
# DEPLOY_DRY_RUN=1 prints mutating commands instead of running them and
# answers read-only queries from built-in fixtures, so every verb runs with
# no wrangler, network or credentials.
# Variables set here (WORKER, CONFIG, ...) are read by the verbs.
# shellcheck disable=SC2034
set -euo pipefail

DRY_RUN="${DEPLOY_DRY_RUN:-0}"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Fixed, so a wrangler update never changes runtime behaviour silently.
# Moving it is a reviewed change (and a new version of every Worker).
COMPATIBILITY_DATE="2026-11-01"

die() {
  echo "cloudflare-workers: $*" >&2
  exit 1
}

usage_error() {
  echo "cloudflare-workers: $*" >&2
  exit 64
}

dry_print() {
  printf 'DRY-RUN:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

# wrangler <args...>: the version pinned in this adapter's package-lock.json,
# installed on first use (npm ci checks every package's integrity hash).
# WRANGLER_BIN replaces it in tests (tests/scripts/test_deploy.sh).
wrangler() {
  local bin="${WRANGLER_BIN:-$ADAPTER_DIR/node_modules/.bin/wrangler}"
  if [[ -z "${WRANGLER_BIN:-}" && ! -x "$bin" ]]; then
    npm ci --prefix "$ADAPTER_DIR" --no-audit --no-fund --loglevel=error >&2 ||
      die "could not install wrangler (npm ci in $ADAPTER_DIR)"
  fi
  WRANGLER_SEND_METRICS=false "$bin" "$@"
}

# run <cmd...>: execute a mutating command (output to stderr), or print it.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    dry_print "$@"
  else
    "$@" >&2
  fi
}

# query <fixture> <cmd...>: run a read-only command and print its stdout. In
# dry run, print the command to stderr and print <fixture> instead.
query() {
  local fixture="$1"
  shift
  if [[ "$DRY_RUN" == "1" ]]; then
    dry_print "$@"
    printf '%s\n' "$fixture"
  else
    "$@"
  fi
}

# require_vars <name...>: fail unless each variable is set. Dry run fills
# placeholders instead.
require_vars() {
  local name missing=()
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      if [[ "$DRY_RUN" == "1" ]]; then
        printf -v "$name" '%s' "$(placeholder "$name")"
      else
        missing+=("$name")
      fi
    fi
  done
  ((${#missing[@]} == 0)) || die "missing required variables: ${missing[*]}"
}

placeholder() {
  case "$1" in
    CLOUDFLARE_ACCOUNT_ID) echo "0123456789abcdef0123456789abcdef" ;;
    CLOUDFLARE_API_TOKEN) echo "dry-run-token" ;;
    CLOUDFLARE_WORKERS_SUBDOMAIN) echo "dry-run" ;;
    APP_NAME) echo "app" ;;
    GITHUB_REPOSITORY) echo "owner/repo" ;;
    *) echo "dry-run" ;;
  esac
}

# init_common: validate what every verb needs. The token is checked only by
# verbs that call Cloudflare (need_token), so `url` and `publish` run without it.
init_common() {
  require_vars CLOUDFLARE_ACCOUNT_ID APP_NAME
  [[ "$CLOUDFLARE_ACCOUNT_ID" =~ ^[0-9a-f]{32}$ ]] || die "invalid CLOUDFLARE_ACCOUNT_ID"
  # Worker names: lowercase letters, digits and hyphens, at most 63
  # characters; "<app>-dev" must fit too.
  [[ "$APP_NAME" =~ ^[a-z][a-z0-9-]{0,58}$ && "$APP_NAME" != *- ]] || die "invalid APP_NAME: $APP_NAME"
  export CLOUDFLARE_ACCOUNT_ID
}

need_token() {
  require_vars CLOUDFLARE_API_TOKEN
  export CLOUDFLARE_API_TOKEN
}

# worker_for <env>: sets ENV_NAME and WORKER (spec §4.11: <app>-dev, <app>).
worker_for() {
  case "${1:-}" in
    dev) WORKER="${APP_NAME}-dev" ;;
    production) WORKER="${APP_NAME}" ;;
    *) usage_error "environment must be dev or production, got: ${1:-<empty>}" ;;
  esac
  ENV_NAME="$1"
}

# sha_vars <sha>: sets SHA and TAG (c + 7 chars), the version's tag.
sha_vars() {
  [[ "${1:-}" =~ ^[0-9a-f]{7,40}$ ]] || usage_error "invalid commit sha: ${1:-<empty>}"
  SHA="$1"
  TAG="c${SHA:0:7}"
}

# entry_point: the stack's Worker module.
entry_point() {
  local ctx="${DEPLOY_BUILD_CONTEXT:-}"
  [[ -n "$ctx" || "$DRY_RUN" != "1" ]] || ctx="stacks/node"
  [[ -n "$ctx" ]] || die "no stack: deploy.yml names no stack (run make bootstrap)"
  local entry="$ctx/src/worker.ts"
  [[ "$DRY_RUN" == "1" || -f "$entry" ]] || die "$entry not found: the cloudflare-workers target supports the node stack only"
  printf '%s\n' "$entry"
}

# write_config <worker> <main>: a throwaway wrangler.json, so no config file
# is committed and switching targets changes no file. Sets CONFIG_DIR (one
# per process, removed on exit) and CONFIG. A relative <main> is resolved
# against CONFIG_DIR by wrangler. preview_urls gives every uploaded version
# its own URL: the dark deploy. Its EXIT trap replaces any other: lib.sh is
# sourced only by this adapter's verbs, each its own process.
write_config() {
  if [[ -z "${CONFIG_DIR:-}" ]]; then
    CONFIG_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064 # expand now: the path is fixed for this process
    trap "rm -rf '$CONFIG_DIR'" EXIT
  fi
  CONFIG="$CONFIG_DIR/wrangler.json"
  jq -n --arg name "$1" --arg main "$2" --arg date "$COMPATIBILITY_DATE" \
    '{name: $name, main: $main, compatibility_date: $date,
      workers_dev: true, preview_urls: true, send_metrics: false}' >"$CONFIG"
}

# Dry-run fixtures. The serving version is DRY_RUN_SERVING_VERSION; the
# newest uploaded version carries the tag being promoted.
SERVING_FIXTURE_ID="11111111-1111-4111-8111-111111111111"
CANDIDATE_FIXTURE_ID="22222222-2222-4222-8222-222222222222"

fixture_status() {
  printf '{"id": "dep-1", "versions": [{"version_id": "%s", "percentage": 100}]}\n' \
    "${DRY_RUN_SERVING_VERSION:-$SERVING_FIXTURE_ID}"
}

fixture_versions() {
  local tag="${1:-c0000000}"
  cat <<EOF
[{"id": "${SERVING_FIXTURE_ID}", "metadata": {"created_on": "2026-01-01T00:00:00Z"},
  "annotations": {"workers/tag": "c0000000"}},
 {"id": "${CANDIDATE_FIXTURE_ID}", "metadata": {"created_on": "2026-01-02T00:00:00Z"},
  "annotations": {"workers/tag": "${tag}"}}]
EOF
}

# serving_version: the version ID that serves 100% of WORKER's traffic. A
# split (a manual gradual rollout) fails rather than guess a revert target.
serving_version() {
  local status id
  status="$(query "$(fixture_status)" wrangler deployments status --json --name "$WORKER" --config "$CONFIG")" ||
    die "could not read the deployment of $WORKER (run make bootstrap-target)"
  id="$(jq -r '[.versions[]? | select(.percentage == 100) | .version_id] | first // empty' <<<"$status")"
  [[ -n "$id" ]] || die "no version serves 100% of traffic on $WORKER"
  printf '%s\n' "$id"
}

# version_for_tag <tag>: the newest version of WORKER tagged <tag>. A version
# uploaded seconds ago may not be listed yet (seen live 2026-11-23: missing
# 5 s after the upload), so ask CF_TAG_LOOKUP_ATTEMPTS times (default 7),
# CF_TAG_LOOKUP_INTERVAL seconds apart (default 5): about 30 s in all.
version_for_tag() {
  local versions id i attempts="${CF_TAG_LOOKUP_ATTEMPTS:-7}" interval="${CF_TAG_LOOKUP_INTERVAL:-5}"
  for ((i = 1; i <= attempts; i++)); do
    versions="$(query "$(fixture_versions "$1")" wrangler versions list --json --name "$WORKER" --config "$CONFIG")"
    id="$(jq -r --arg t "$1" '[.[] | select(.annotations["workers/tag"] == $t)]
      | sort_by(.metadata.created_on) | last | .id // empty' <<<"$versions")"
    if [[ -n "$id" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
    ((i == attempts)) || sleep "$interval"
  done
  die "no version of $WORKER is tagged $1 after $attempts lookups (did deploy-dark run?)"
}

# worker_url: the live workers.dev URL of WORKER.
worker_url() {
  require_vars CLOUDFLARE_WORKERS_SUBDOMAIN
  [[ "$CLOUDFLARE_WORKERS_SUBDOMAIN" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "invalid CLOUDFLARE_WORKERS_SUBDOMAIN"
  printf 'https://%s.%s.workers.dev\n' "$WORKER" "$CLOUDFLARE_WORKERS_SUBDOMAIN"
}

# wait_serving <sha>: after a deploy, wait until the live URL's /health
# reports version <sha> (the stack's APP_VERSION, set by deploy-dark).
# Cloudflare takes a few seconds to move traffic (seen live 2026-11-23: the
# placeholder still answered 2.5 s after promote). Polls CF_SERVING_ATTEMPTS
# times (default 12), CF_SERVING_INTERVAL seconds apart (default 5). Not
# confirmed in time is only a warning: release.sh's live check decides.
wait_serving() {
  local url v i attempts="${CF_SERVING_ATTEMPTS:-12}" interval="${CF_SERVING_INTERVAL:-5}"
  url="$(worker_url)"
  for ((i = 1; i <= attempts; i++)); do
    v="$(curl -fsS --max-time 10 "$url/health" 2>/dev/null | jq -r '.version? // empty' 2>/dev/null || true)"
    if [[ "$v" == "$1" ]]; then
      echo "cloudflare-workers: $url serves $1" >&2
      return 0
    fi
    ((i == attempts)) || sleep "$interval"
  done
  echo "cloudflare-workers: warning: $url did not report version $1 within $((attempts * interval)) s; the live check decides" >&2
}

valid_version_id() {
  [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}
