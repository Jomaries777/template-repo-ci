#!/usr/bin/env bash
# Shared helpers for the broker owner scripts (spec 0004 FR-6): setup.sh,
# put-secret.sh and deploy.sh. Sourced, never run. The owner runs these with
# their own gcloud login, never from CI and never by an agent (no-secrets.sh
# blocks Claude from running them).
#
# BROKER_PROJECT names the broker project. Every gcloud call passes
# --project "$BROKER_PROJECT", so the active gcloud config is never used.
# Regional calls use BROKER_REGION, default us-west1 (spec C4).
#
# DRY_RUN=1 prints each mutating command instead of running it, and answers
# read-only queries from BROKER_FIXTURE_* values (defaults below describe a
# healthy, labelled project), so the scripts' tests run with no gcloud.
# Variables set here are read by the scripts.
# shellcheck disable=SC2034
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
SERVICE="agent-bot-broker"
LABEL_KEY="purpose"
LABEL_VALUE="agent-bot-broker"
SECRETS=(claude-key agy-key ci-key login-client-secret)
# The environment variable each secret reaches the service as (FR-3).
secret_env() {
  case "$1" in
    claude-key) echo CLAUDE_KEY_PKCS8 ;;
    agy-key) echo AGY_KEY_PKCS8 ;;
    ci-key) echo CI_KEY_PKCS8 ;;
    login-client-secret) echo LOGIN_CLIENT_SECRET ;;
    *) return 1 ;;
  esac
}

die() {
  echo "broker: $*" >&2
  exit 1
}

say() { echo "broker: $*" >&2; }

dry_line() {
  printf 'DRY-RUN:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

# run <cmd...>: a mutating command, or its DRY-RUN line.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    dry_line "$@"
  else
    "$@" >&2
  fi
}

# query <fixture> <cmd...>: a read-only command's stdout. In dry run, print
# the command as a DRY-RUN line and answer <fixture>.
query() {
  local fixture="$1"
  shift
  if [[ "$DRY_RUN" == "1" ]]; then
    dry_line "$@"
    printf '%s\n' "$fixture"
  else
    "$@"
  fi
}

# exists <cmd...>: a describe-style command succeeds. Dry run assumes nothing
# exists, so setup.sh prints every create.
exists() {
  if [[ "$DRY_RUN" == "1" ]]; then
    dry_line "$@"
    return 1
  fi
  "$@" >/dev/null 2>&1
}

# init_project: check BROKER_PROJECT and BROKER_REGION, derive names.
init_project() {
  P="${BROKER_PROJECT:-}"
  [[ -n "$P" ]] || die "set BROKER_PROJECT to the broker project ID (broker/README.md)"
  [[ "$P" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "invalid BROKER_PROJECT: $P"
  # Never the owner's other projects (spec, "The broker project").
  [[ "$P" != "pse-advisor-feat001" ]] || die "$P is not a broker project"
  REGION="${BROKER_REGION:-us-west1}"
  [[ "$REGION" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] || die "invalid BROKER_REGION: $REGION"
  BROKER_SA="broker@${P}.iam.gserviceaccount.com"
  BUILDER_SA="builder@${P}.iam.gserviceaccount.com"
}

# require_label: the project carries purpose=agent-bot-broker (FR-6).
require_label() {
  local v
  v="$(query "${BROKER_FIXTURE_LABEL-$LABEL_VALUE}" \
    gcloud projects describe "$P" --project "$P" --format "value(labels.${LABEL_KEY})")"
  [[ "$v" == "$LABEL_VALUE" ]] ||
    die "$P has no label ${LABEL_KEY}=${LABEL_VALUE}; refusing (gcloud projects update $P --update-labels ${LABEL_KEY}=${LABEL_VALUE})"
}

# require_clean: no workload identity pool, no user-managed service account
# key, and no Cloud Run service but the broker (FR-6, NFR-2).
require_clean() {
  local pools services s sas sa keys
  pools="$(query "${BROKER_FIXTURE_POOLS-}" \
    gcloud iam workload-identity-pools list --location global --project "$P" --format "value(name)")"
  [[ -z "$pools" ]] || die "$P has a workload identity pool; a broker project must have none"
  services="$(query "${BROKER_FIXTURE_SERVICES-$SERVICE}" \
    gcloud run services list --project "$P" --format "value(metadata.name)")"
  for s in $services; do
    [[ "$s" == "$SERVICE" ]] || die "$P runs another Cloud Run service ($s); a broker project holds only $SERVICE"
  done
  sas="$(query "${BROKER_FIXTURE_SAS-$BROKER_SA}" \
    gcloud iam service-accounts list --project "$P" --format "value(email)")"
  for sa in $sas; do
    keys="$(query "${BROKER_FIXTURE_KEYS-}" \
      gcloud iam service-accounts keys list --iam-account "$sa" --managed-by user --project "$P" --format "value(name)")"
    [[ -z "$keys" ]] || die "$sa has a user-managed key; delete it (a broker project has no service account keys)"
  done
}
