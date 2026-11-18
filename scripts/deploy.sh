#!/usr/bin/env bash
# Deploy contract dispatcher (spec §4.10, §4.11; FR-13).
# Reads target: from deploy.yml (or DEPLOY_TARGET env override) with grep/sed
# and delegates to deploy/targets/<target>/<verb>.
#
# Usage: scripts/deploy.sh <verb> [args...]
# Verbs: bootstrap publish current deploy-dark preview promote revert url discard cleanup
# (`preview` only for adapters with dark_deploy: false, C9)
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/deploy.sh <verb> [args...]
verbs: bootstrap publish current deploy-dark preview promote revert url discard cleanup
env:   DEPLOY_TARGET (overrides deploy.yml target:)
       DEPLOY_DRY_RUN=1 (print commands instead of executing)
       DEPLOY_CONFIG (config file, default: deploy.yml at the repo root)
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 64
fi

verb="$1"
shift

case "$verb" in
  -h | --help)
    usage 2>&1
    exit 0
    ;;
  bootstrap | publish | current | deploy-dark | preview | promote | revert | url | discard | cleanup) ;;
  *)
    echo "deploy.sh: unknown verb: $verb" >&2
    usage
    exit 64
    ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
config_file="${DEPLOY_CONFIG:-$root/deploy.yml}"

target="${DEPLOY_TARGET:-}"
if [[ -z "$target" ]]; then
  if [[ ! -f "$config_file" ]]; then
    echo "deploy.sh: missing config file: $config_file" >&2
    usage
    exit 64
  fi
  target="$(grep -E '^target:' "$config_file" | head -n 1 | sed -E 's/^target:[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^["'\''](.*)["'\'']$/\1/' || true)"
fi

if [[ -z "$target" || ! "$target" =~ ^[a-z0-9-]+$ ]]; then
  echo "deploy.sh: invalid or missing target: ${target:-<empty>}" >&2
  usage
  exit 64
fi

target_dir="$root/deploy/targets/$target"
verb_path="$target_dir/$verb"

if [[ ! -d "$target_dir" || ! -x "$verb_path" ]]; then
  echo "deploy.sh: unknown target or missing verb: $target/$verb" >&2
  usage
  exit 64
fi

# The stack's directory (deploy.yml `stack:`, written by bootstrap) is the
# build context for adapters that build an image. DEPLOY_BUILD_CONTEXT wins.
if [[ -z "${DEPLOY_BUILD_CONTEXT:-}" && -f "$config_file" ]]; then
  stack="$(grep -E '^stack:' "$config_file" | head -n 1 | sed -E 's/^stack:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' || true)"
  if [[ -n "$stack" ]]; then
    [[ "$stack" =~ ^[a-z0-9-]+$ && -d "$root/stacks/$stack" ]] || {
      echo "deploy.sh: invalid stack in $config_file: $stack" >&2
      exit 64
    }
    export DEPLOY_BUILD_CONTEXT="$root/stacks/$stack"
  fi
fi

export DEPLOY_DRY_RUN="${DEPLOY_DRY_RUN:-0}"
exec "$verb_path" "$@"
