#!/usr/bin/env bash
# Provision the deploy target named in deploy.yml (spec §4.11, criterion 11).
# Runs the adapter's own `bootstrap` (its cloud resources, repo variables and
# Environment secrets) and changes no file: switching a project's target is
# "edit target: in deploy.yml, run make bootstrap-target, merge the PR", and
# no workflow ever changes. bootstrap.sh calls it for a project's first
# target. Idempotent: a rerun only fills in what is missing. No AI.
#
# Usage: scripts/bootstrap-target.sh [--target <t>] [--stack <s>] [--repo owner/name] [--dry-run]
#   --target / --stack  default to deploy.yml's target: and stack:
#   --dry-run           print every remote call; change nothing
# Target settings come from the environment, e.g. for cloud-run:
#   GCP_PROJECT_ID, BILLING_ACCOUNT, GCP_REGION, APP_NAME (default: the repo name).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
die() {
  echo "bootstrap-target: $*" >&2
  exit 1
}
usage_error() {
  echo "bootstrap-target: $*" >&2
  exit 64
}

target="" stack="" repo="" dry_run=0
while (($#)); do
  case "$1" in
    --target) target="${2:-}"; shift 2 ;;
    --stack) stack="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) usage_error "usage: scripts/bootstrap-target.sh [--target <t>] [--stack <s>] [--repo owner/name] [--dry-run]" ;;
  esac
done

config="${DEPLOY_CONFIG:-deploy.yml}"
[[ -n "$target" ]] || target="$(sed -n 's/^target:[[:space:]]*\([a-z0-9-]*\).*/\1/p' "$config" 2>/dev/null | head -n 1)"
[[ -n "$stack" ]] || stack="$(sed -n 's/^stack:[[:space:]]*\([a-z0-9-]*\).*/\1/p' "$config" 2>/dev/null | head -n 1)"
[[ -n "$stack" ]] || usage_error "$config names no stack: run make bootstrap first"
[[ "$target" =~ ^[a-z0-9-]+$ ]] || usage_error "invalid or missing target in $config: ${target:-<empty>}"
target_yml="deploy/targets/$target/target.yml"
if [[ ! -f "$target_yml" ]]; then
  adapters=""
  for d in deploy/targets/*/; do adapters+="$(basename "$d") "; done
  usage_error "unknown target: $target (adapters: ${adapters% })"
fi

# A target may list the stacks it supports (target.yml `stacks:`); no list
# means every stack.
supported="$(sed -n '/^stacks:/,/^[^[:space:]-]/p' "$target_yml" | sed -n 's/^[[:space:]]*-[[:space:]]*\([a-z0-9-]*\).*/\1/p' | tr '\n' ' ')"
if [[ -n "$supported" && " $supported" != *" $stack "* ]]; then
  usage_error "$target doesn't support the $stack stack (supported: ${supported% })"
fi

if [[ -z "$repo" ]]; then
  if ((dry_run)); then repo="owner/repo"; else repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"; fi
fi
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage_error "invalid repository: $repo"

echo "==> Target: $target ($repo, stack $stack)" >&2
if [[ "$target" == none ]]; then
  echo "    nothing to provision" >&2
  exit 0
fi
if [[ -z "${APP_NAME:-}" ]]; then
  APP_NAME="$(tr 'A-Z_.' 'a-z--' <<<"${repo#*/}")"
  # Cloud Run service names must start with a letter.
  [[ "$APP_NAME" =~ ^[a-z] ]] || APP_NAME="app-$APP_NAME"
  # Cloud Run: at most 49 characters for "<app>-prod"/"-dev", no trailing hyphen.
  APP_NAME="${APP_NAME:0:40}"
  while [[ "$APP_NAME" == *- ]]; do APP_NAME="${APP_NAME%-}"; done
fi
export APP_NAME
export GITHUB_REPOSITORY="$repo"
if ((dry_run)); then
  DEPLOY_DRY_RUN=1 DEPLOY_TARGET="$target" scripts/deploy.sh bootstrap 2>&1 | sed 's/^/    /' >&2
else
  DEPLOY_TARGET="$target" scripts/deploy.sh bootstrap
  echo "==> $target is ready. Commit deploy.yml's target: $target in a PR; the next deploy after the merge uses it." >&2
fi
