#!/usr/bin/env bash
# Tests for scripts/deploy-config.sh (spec §4.10, §4.11). Run from the repo root.
set -euo pipefail

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Run the script from a fixture tree, so the test doesn't depend on which
# adapters this repo has or what its deploy.yml says (a bootstrapped project
# keeps one adapter and its own deploy.yml).
fx="$tmp/root"
mkdir -p "$fx/scripts" "$fx/deploy/targets/none" "$fx/deploy/targets/cloud-run"
cp "$PWD/scripts/deploy-config.sh" "$fx/scripts/"
printf 'name: none\ndark_deploy: false\nenvironments: []\n' >"$fx/deploy/targets/none/target.yml"
printf 'name: cloud-run\ndark_deploy: true\nenvironments:\n  - dev\n  - production\nauth: oidc\n' >"$fx/deploy/targets/cloud-run/target.yml"
cat >"$fx/deploy.yml" <<'YAML'
target: none                 # cloud-run (default) | cloudflare-workers | github-pages | none
environments:
  dev:        { enabled: true }
  production: { approval: required }
smoke:
  live_checks: 3
  interval_seconds: 60
YAML
cfg_sh="$fx/scripts/deploy-config.sh"

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}

# check <name> <expected key=value lines> [env assignments...]
check() {
  local name="$1" want="$2" got rc=0
  shift 2
  got="$(env "$@" "$cfg_sh" 2>&1)" || rc=$?
  if [[ "$rc" == 0 && "$got" == "$want" ]]; then pass "$name"; else fail "$name (rc $rc): $(tr '\n' ';' <<<"$got")"; fi
}
rc_is() {
  local name="$1" want="$2" rc=0
  shift 2
  env "$@" "$cfg_sh" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$want" ]]; then pass "$name"; else fail "$name (rc $rc, want $want)"; fi
}

check "template-style deploy.yml: none, no dev" "target=none
dark_deploy=false
dev=false
live_checks=3
interval_seconds=60"

check "cloud-run: dark deploy and dev" "target=cloud-run
dark_deploy=true
dev=true
live_checks=3
interval_seconds=60" DEPLOY_TARGET=cloud-run

cat >"$tmp/nodev.yml" <<'EOF'
target: cloud-run
environments:
  dev:        { enabled: false }
  production: { approval: required }
smoke:
  live_checks: 5
  interval_seconds: 30
EOF
check "dev disabled in deploy.yml; smoke values read" "target=cloud-run
dark_deploy=true
dev=false
live_checks=5
interval_seconds=30" DEPLOY_CONFIG="$tmp/nodev.yml"

printf 'target: "cloud-run"  # quoted\n' >"$tmp/bare.yml"
check "quoted target, missing blocks use defaults" "target=cloud-run
dark_deploy=true
dev=false
live_checks=3
interval_seconds=60" DEPLOY_CONFIG="$tmp/bare.yml"

printf 'target: nope\n' >"$tmp/unknown.yml"
rc_is "unknown target exits 64" 64 DEPLOY_CONFIG="$tmp/unknown.yml"
printf 'target: ../none\n' >"$tmp/path.yml"
rc_is "path-like target exits 64" 64 DEPLOY_CONFIG="$tmp/path.yml"
printf 'target: none\nsmoke:\n  live_checks: 0\n' >"$tmp/zero.yml"
rc_is "live_checks 0 exits 64" 64 DEPLOY_CONFIG="$tmp/zero.yml"
rc_is "missing config exits 64" 64 DEPLOY_CONFIG="$tmp/missing.yml"
printf 'target: none\nsmoke:\n  live_checks: 11\n  interval_seconds: 61\n' >"$tmp/long.yml"
rc_is "live checks over 10 minutes exit 64" 64 DEPLOY_CONFIG="$tmp/long.yml"

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
