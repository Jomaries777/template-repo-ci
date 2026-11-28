#!/usr/bin/env bash
# Load a key or the login client secret into Secret Manager (spec 0004 FR-6,
# "Keys and rotation"). The owner runs it with their own gcloud login:
#
#   BROKER_PROJECT=<P> broker/put-secret.sh claude-key ~/Downloads/claude.pem
#   BROKER_PROJECT=<P> broker/deploy.sh                 # pins the new version
#   BROKER_PROJECT=<P> broker/put-secret.sh --prune claude-key
#
# A key file is converted to PKCS#8 (openssl pkcs8 -topk8 -nocrypt). Empty
# input, and for the three keys anything that isn't a PEM private key, is
# refused: on 2026-11-28 an empty Worker secret was saved because nothing
# checked. The value goes to gcloud on stdin, never in a command line, an
# environment variable or this script's output. The file is deleted once the
# version is added. Only the new version number is printed.
#
# --prune destroys every version except the one the live service pins, so the
# project stays at one active version per secret (NFR-1). Run it only after
# deploy.sh has passed: until then the previous version is the rollback.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=broker/lib.sh disable=SC1091
source "$here/lib.sh"

# PEM armour, assembled so this file holds no key-shaped literal.
dashes="-----"
pem_begin="${dashes}BEGIN PRIVATE"" KEY${dashes}"
pem_end="${dashes}END PRIVATE"" KEY${dashes}"

usage() {
  echo "usage: BROKER_PROJECT=<project> $0 <secret> <file> | --prune <secret>" >&2
  echo "       <secret> is one of: ${SECRETS[*]}" >&2
  exit 64
}

prune=0
if [[ "${1:-}" == "--prune" ]]; then
  prune=1
  shift
fi
secret="${1:-}"
[[ -n "$secret" ]] || usage
secret_env "$secret" >/dev/null || { echo "broker: unknown secret: $secret" >&2; usage; }

init_project
require_label

if ((prune)); then
  (($# == 1)) || usage
  env_name="$(secret_env "$secret")"
  live="$(query "${BROKER_FIXTURE_SERVICE_JSON-}" \
    gcloud run services describe "$SERVICE" --project "$P" --region "$REGION" --format json)"
  [[ -n "$live" ]] || live='{}'
  pinned="$(jq -r --arg e "$env_name" --arg s "$secret" \
    '[.spec.template.spec.containers[0].env[]? | select(.name == $e) | .valueFrom.secretKeyRef
      | select(.name == $s) | .key][0] // empty' <<<"$live")"
  [[ "$pinned" =~ ^[0-9]+$ ]] || die "the live service doesn't pin a numbered version of $secret; deploy first (broker/deploy.sh)"
  versions="$(query "${BROKER_FIXTURE_VERSIONS-}" \
    gcloud secrets versions list "$secret" --project "$P" --filter "state!=DESTROYED" --format "value(name)")"
  kept=0
  for v in $versions; do
    v="${v##*/}"
    if [[ "$v" == "$pinned" ]]; then
      kept=1
      continue
    fi
    run gcloud secrets versions destroy "$v" --secret "$secret" --project "$P" --quiet
  done
  ((kept)) || die "the pinned version $pinned of $secret isn't active; check broker/deploy.sh before pruning"
  say "$secret: kept version $pinned (the deployed one)"
  exit 0
fi

(($# == 2)) || usage
file="$2"
[[ -f "$file" ]] || die "no such file: $file"
[[ -s "$file" ]] || die "$file is empty; refusing"

if [[ "$secret" == "login-client-secret" ]]; then
  value="$(tr -d '\r\n' <"$file")"
  [[ -n "$value" ]] || die "$file holds only whitespace; refusing"
  [[ "$value" != *"PRIVATE KEY"* ]] || die "$file looks like a private key, not the login client secret; refusing"
else
  grep -Eq -- "^${dashes}BEGIN ([A-Z]+ )?PRIVATE KEY${dashes}" "$file" ||
    die "$file is not a PEM private key; refusing"
  # Converted in memory; never echoed.
  value="$(openssl pkcs8 -topk8 -nocrypt -in "$file" 2>/dev/null)" ||
    die "openssl couldn't read $file as a private key; refusing"
  [[ "$value" == "$pem_begin"* && "$value" == *"$pem_end" ]] ||
    die "converting $file to PKCS#8 gave no key; refusing"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  dry_line gcloud secrets versions add "$secret" --project "$P" --data-file=- --format "value(name)"
  dry_line rm -f "$file"
  name="projects/$P/secrets/$secret/versions/0"
else
  name="$(printf '%s\n' "$value" | gcloud secrets versions add "$secret" --project "$P" --data-file=- --format "value(name)")"
  rm -f "$file"
fi
unset value
version="${name##*/}"
[[ "$version" =~ ^[0-9]+$ ]] || die "gcloud gave no version number for $secret"
echo "$version"
say "$secret: added version $version and deleted $file. Next: broker/deploy.sh, then broker/put-secret.sh --prune $secret"
