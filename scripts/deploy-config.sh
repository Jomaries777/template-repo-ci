#!/usr/bin/env bash
# Print the deploy settings deploy.yml (the workflow) needs, as key=value lines
# for $GITHUB_OUTPUT (spec §4.10, §4.11). Reads deploy.yml and the chosen
# adapter's target.yml with grep/sed; no yq, no network, no AI.
#
# Usage: scripts/deploy-config.sh
# Env:   DEPLOY_CONFIG (default: deploy.yml at the repo root)
#        DEPLOY_TARGET (overrides deploy.yml target:, as in scripts/deploy.sh)
#
# Output keys:
#   target            adapter name
#   dark_deploy       true|false, from target.yml
#   dev               true when the adapter lists a dev environment and
#                     deploy.yml has `dev: { enabled: true }`
#   live_checks       smoke.live_checks (default 3)
#   interval_seconds  smoke.interval_seconds (default 60)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config="${DEPLOY_CONFIG:-$root/deploy.yml}"
[[ -f "$config" ]] || {
  echo "deploy-config: missing $config" >&2
  exit 64
}

# value <file> <regex for the whole key prefix>: first matching value, with
# comments, surrounding space and quotes removed.
value() {
  grep -E "$2" "$1" | head -n 1 |
    sed -E "s/$2[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^[\"'](.*)[\"']$/\1/" || true
}

target="${DEPLOY_TARGET:-$(value "$config" '^target:')}"
[[ "$target" =~ ^[a-z0-9-]+$ ]] || {
  echo "deploy-config: invalid or missing target: ${target:-<empty>}" >&2
  exit 64
}
target_yml="$root/deploy/targets/$target/target.yml"
[[ -f "$target_yml" ]] || {
  echo "deploy-config: unknown target: $target" >&2
  exit 64
}

dark="$(value "$target_yml" '^dark_deploy:')"
[[ "$dark" == true ]] || dark=false

# The adapter supports dev if target.yml lists `- dev` under environments.
adapter_dev=false
if sed -n '/^environments:/,/^[^[:space:]-]/p' "$target_yml" | grep -qE '^[[:space:]]*-[[:space:]]*dev[[:space:]]*$'; then
  adapter_dev=true
fi
# deploy.yml enables dev with `  dev: { enabled: true }` under environments:.
config_dev=false
if sed -n '/^environments:/,/^[^[:space:]]/p' "$config" | grep -qE '^[[:space:]]+dev:.*enabled:[[:space:]]*true'; then
  config_dev=true
fi
dev=false
[[ "$adapter_dev" == true && "$config_dev" == true ]] && dev=true

checks="$(value "$config" '^[[:space:]]+live_checks:')"
interval="$(value "$config" '^[[:space:]]+interval_seconds:')"
checks="${checks:-3}"
interval="${interval:-60}"
[[ "$checks" =~ ^[1-9][0-9]?$ ]] || {
  echo "deploy-config: smoke.live_checks must be 1-99, got: $checks" >&2
  exit 64
}
[[ "$interval" =~ ^[0-9]{1,3}$ ]] || {
  echo "deploy-config: smoke.interval_seconds must be 0-999, got: $interval" >&2
  exit 64
}
# Live checks run after promote inside a 20-minute job: keep them within 10.
if (((checks - 1) * interval > 600)); then
  echo "deploy-config: smoke: $checks live checks ${interval}s apart exceed 10 minutes" >&2
  exit 64
fi

printf 'target=%s\ndark_deploy=%s\ndev=%s\nlive_checks=%s\ninterval_seconds=%s\n' \
  "$target" "$dark" "$dev" "$checks" "$interval"
