#!/usr/bin/env bash
# Shared helpers for the cloud-run deploy adapter (spec §4.11). Sourced by
# every verb. Contract: a verb prints only its result (a URL or revision
# name) on stdout; progress, gcloud output and DRY-RUN lines go to stderr, so
# the release composite can capture results with $(...).
#
# DEPLOY_DRY_RUN=1 prints mutating commands instead of running them, and
# answers read-only queries from built-in fixtures, so every verb runs with
# no gcloud, docker or credentials. Every gcloud call passes --project
# explicitly; the active gcloud config is never used.
# Variables set here (SERVICE, TAG, IMAGE, ...) are read by the verbs.
# shellcheck disable=SC2034
set -euo pipefail

DRY_RUN="${DEPLOY_DRY_RUN:-0}"

die() {
  echo "cloud-run: $*" >&2
  exit 1
}

usage_error() {
  echo "cloud-run: $*" >&2
  exit 64
}

# run <cmd...>: execute a mutating command, or print it in dry run.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    {
      printf 'DRY-RUN:'
      printf ' %q' "$@"
      printf '\n'
    } >&2
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
    {
      printf 'DRY-RUN:'
      printf ' %q' "$@"
      printf '\n'
    } >&2
    printf '%s\n' "$fixture"
  else
    "$@"
  fi
}

# exists <cmd...>: true if a describe-style command succeeds. Dry run assumes
# nothing exists, so bootstrap prints every create command.
exists() {
  if [[ "$DRY_RUN" == "1" ]]; then
    {
      printf 'DRY-RUN:'
      printf ' %q' "$@"
      printf '\n'
    } >&2
    return 1
  fi
  "$@" >/dev/null 2>&1
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
    GCP_PROJECT_ID) echo "dry-run-project" ;;
    APP_NAME) echo "app" ;;
    GCP_WIF_PROVIDER) echo "projects/123456789012/locations/global/workloadIdentityPools/github/providers/github" ;;
    GCP_DEPLOY_SA) echo "deployer@dry-run-project.iam.gserviceaccount.com" ;;
    BILLING_ACCOUNT) echo "000000-000000-000000" ;;
    GITHUB_REPOSITORY) echo "owner/repo" ;;
    *) echo "dry-run" ;;
  esac
}

# init_common: validate the variables every verb needs and derive names.
init_common() {
  GCP_REGION="${GCP_REGION:-us-central1}"
  require_vars GCP_PROJECT_ID APP_NAME
  [[ "$GCP_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "invalid GCP_PROJECT_ID: $GCP_PROJECT_ID"
  [[ "$GCP_REGION" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] || die "invalid GCP_REGION: $GCP_REGION"
  [[ "$APP_NAME" =~ ^[a-z][a-z0-9-]{0,39}$ ]] || die "invalid APP_NAME: $APP_NAME"
  RUNTIME_SA="runtime@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  REGISTRY="${GCP_REGION}-docker.pkg.dev"
  IMAGE_BASE="${REGISTRY}/${GCP_PROJECT_ID}/app/${APP_NAME}"
}

# service_for <env>: sets ENV_NAME and SERVICE.
service_for() {
  case "${1:-}" in
    dev) SERVICE="${APP_NAME}-dev" ;;
    production) SERVICE="${APP_NAME}-prod" ;;
    *) usage_error "environment must be dev or production, got: ${1:-<empty>}" ;;
  esac
  ENV_NAME="$1"
}

# sha_vars <sha>: sets SHA, TAG (c + 7 chars) and IMAGE.
sha_vars() {
  [[ "${1:-}" =~ ^[0-9a-f]{7,40}$ ]] || usage_error "invalid commit sha: ${1:-<empty>}"
  SHA="$1"
  TAG="c${SHA:0:7}"
  IMAGE="${IMAGE_BASE}:${SHA}"
}

# Dry-run fixtures: an old revision serves 100% (as after a revert) and the
# newest revision is a tagged candidate at 0%. Tests can set
# DRY_RUN_SERVING_REVISION to make another revision the serving one.
fixture_service() {
  local tag="${1:-c0000000}"
  cat <<EOF
{"status": {"url": "https://${SERVICE}-dryrun.a.run.app",
  "traffic": [
    {"revisionName": "${DRY_RUN_SERVING_REVISION:-${SERVICE}-00002-aaa}", "percent": 100},
    {"revisionName": "${SERVICE}-00009-aaa", "percent": 0, "tag": "${tag}",
     "url": "https://${tag}---${SERVICE}-dryrun.a.run.app"}
  ]}}
EOF
}

# tag_deployed <image ref>: tag the image serving ENV_NAME as "<env>". The
# registry's keep-deployed rule never deletes "dev*" / "production*" tags, so
# the image a cold start pulls (min-instances 0) is never cleaned up.
tag_deployed() {
  run gcloud artifacts docker tags add "$1" "${IMAGE_BASE}:${ENV_NAME}" --project "$GCP_PROJECT_ID" --quiet
}

# revision_image <revision>: the image a revision runs. The dry-run fixture is
# digest-pinned, the form gcloud reports for a deployed revision; tests set
# DRY_RUN_REVISION_IMAGE to try other cases.
revision_image() {
  query "${DRY_RUN_REVISION_IMAGE:-${IMAGE_BASE}@sha256:0000000000000000000000000000000000000000000000000000000000000000}" \
    gcloud run revisions describe "$1" --project "$GCP_PROJECT_ID" \
    --region "$GCP_REGION" --format 'value(spec.containers[0].image)'
}

# ours <image ref>: true if the image comes from this app's registry path
# (not, e.g., the sample image bootstrap serves before the first deploy).
ours() { [[ "$1" == "${IMAGE_BASE}"[:@]* ]]; }

# describe_service [tag]: service JSON (real, or the dry-run fixture).
describe_service() {
  query "$(fixture_service "${1:-}")" \
    gcloud run services describe "$SERVICE" --project "$GCP_PROJECT_ID" \
    --region "$GCP_REGION" --format json
}

# revision_for_tag <tag>: the revision name behind a traffic tag.
revision_for_tag() {
  local rev
  rev="$(describe_service "$1" | jq -r --arg t "$1" '.status.traffic[] | select(.tag == $t) | .revisionName' | head -n 1)"
  [[ -n "$rev" ]] || die "no revision is tagged $1 on $SERVICE"
  printf '%s\n' "$rev"
}
