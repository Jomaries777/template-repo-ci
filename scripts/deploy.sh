#!/usr/bin/env bash
# Deploy contract dispatcher (spec §4.10, §4.11; FR-13).
# Reads target: from deploy.yml (or DEPLOY_TARGET env override) with grep/sed
# and delegates to deploy/targets/<target>/<verb>.
#
# Usage: scripts/deploy.sh <verb> [args...]
# Verbs: bootstrap publish current deploy-dark promote revert url discard cleanup
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/deploy.sh <verb> [args...]
verbs: bootstrap publish current deploy-dark promote revert url discard cleanup
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
  bootstrap | publish | current | deploy-dark | promote | revert | url | discard | cleanup) ;;
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
  target="$(grep -E '^[[:space:]]*target:' "$config_file" | head -n 1 | sed -E 's/^[[:space:]]*target:[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^["'\''](.*)["'\'']$/\1/' || true)"
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

export DEPLOY_DRY_RUN="${DEPLOY_DRY_RUN:-0}"
exec "$verb_path" "$@"
