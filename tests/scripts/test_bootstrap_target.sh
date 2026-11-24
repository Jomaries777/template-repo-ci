#!/usr/bin/env bash
# Tests for scripts/bootstrap-target.sh (spec §4.11, criterion 11): it
# provisions the target named in deploy.yml through the adapter's bootstrap
# and changes no file, workflows included. Runs in throwaway copies, dry run
# only (no gh, gcloud or network). Run from the repo root.
# check() evals its condition later, so single quotes are intended (SC2016).
# shellcheck disable=SC2016,SC2034
set -euo pipefail

src="$PWD"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}
check() { if eval "$2"; then pass "$1"; else fail "$1 (rc $rc; out: $(tail -n 3 <<<"$out"))"; fi; }

# copy <dir>: the working tree (tracked + untracked, not ignored).
copy() {
  mkdir -p "$1"
  (cd "$src" && git ls-files -co --exclude-standard -z | tar --null -cf - -T -) | tar -xf - -C "$1"
}

p="$tmp/p"
copy "$p"
[[ -x "$p/scripts/bootstrap-target.sh" ]] || {
  echo "not ok - scripts/bootstrap-target.sh is missing"
  exit 1
}
real_targets=()
for d in "$p"/deploy/targets/*/; do
  grep -qx 'test_only: true' "$d/target.yml" 2>/dev/null || real_targets+=("$(basename "$d")")
done

# run: bootstrap-target.sh --dry-run in the copy, with deploy.yml naming
# stack node and target <target>.
run() {
  printf 'target: %s\nstack: node\n' "$1" >"$p/deploy.yml"
  rc=0
  out="$(cd "$p" && GCP_PROJECT_ID=proj-1 BILLING_ACCOUNT=0A1B2C-3D4E5F-6A7B8C scripts/bootstrap-target.sh --repo acme/hello --dry-run 2>&1)" || rc=$?
}

before="$(cd "$p" && find . -path ./deploy.yml -prune -o -type f -print | sort | xargs cksum)"
for t in "${real_targets[@]}"; do
  run "$t"
  check "$t: dry run exits 0" '[[ $rc == 0 ]]'
  if [[ "$t" != none ]]; then
    check "$t: runs the adapter's bootstrap" 'grep -q "Target: $t" <<<"$out" && grep -q "DRY-RUN" <<<"$out"'
  fi
done
after="$(cd "$p" && find . -path ./deploy.yml -prune -o -type f -print | sort | xargs cksum)"
check "switching targets changes no file, workflows included (criterion 11)" '[[ "$before" == "$after" ]]'

# A switch later on gets the "commit deploy.yml's target" hint; a first
# bootstrap (BOOTSTRAP_FIRST=1, set by bootstrap.sh) commits it itself.
run cloud-run
check "switch: prints the commit-the-target hint" 'grep -q "Commit deploy.yml.s target: cloud-run" <<<"$out"'
printf 'target: cloud-run\nstack: node\n' >"$p/deploy.yml"
rc=0
out="$(cd "$p" && BOOTSTRAP_FIRST=1 GCP_PROJECT_ID=proj-1 BILLING_ACCOUNT=0A1B2C-3D4E5F-6A7B8C scripts/bootstrap-target.sh --repo acme/hello --dry-run 2>&1)" || rc=$?
check "first bootstrap: no commit-the-target hint" '[[ $rc == 0 ]] && ! grep -q "Commit deploy.yml" <<<"$out"'

run nope
check "an unknown target is refused with 64" '[[ $rc == 64 ]] && grep -q "unknown target" <<<"$out"'

printf 'target: none\n' >"$p/deploy.yml"
rc=0
out="$(cd "$p" && scripts/bootstrap-target.sh --repo acme/hello --dry-run 2>&1)" || rc=$?
check "a project with no stack is refused with 64" '[[ $rc == 64 ]] && grep -q "make bootstrap" <<<"$out"'

# A target can list the stacks it supports (target.yml `stacks:`).
mkdir -p "$p/deploy/targets/onlygo"
cp "$p/deploy/targets/none/"* "$p/deploy/targets/onlygo/"
printf 'name: onlygo\nstacks:\n  - go\ndark_deploy: true\n' >"$p/deploy/targets/onlygo/target.yml"
run onlygo
check "a stack the target doesn't support is refused with 64" '[[ $rc == 64 ]] && grep -q "doesn.t support the node stack" <<<"$out"'

# scripts/target-stacks.sh, the parser both bootstrap scripts share.
printf 'name: x\nstacks:\n  - node\n  - go # comment\ndark_deploy: true\n' >"$tmp/t1.yml"
printf 'name: x\ndark_deploy: true\n' >"$tmp/t2.yml"
check "target-stacks: lists the stacks" '[[ "$("$src/scripts/target-stacks.sh" "$tmp/t1.yml")" == "node go" ]]'
check "target-stacks: no list prints nothing (every stack)" '[[ -z "$("$src/scripts/target-stacks.sh" "$tmp/t2.yml")" ]]'
rc=0
"$src/scripts/target-stacks.sh" "$tmp/missing.yml" 2>/dev/null || rc=$?
check "target-stacks: a missing file exits 64" '[[ $rc == 64 ]]'

# cloudflare-workers runs the node stack only (owner decision 2026-11-18).
if [[ -d "$p/deploy/targets/cloudflare-workers" ]]; then
  for s in python go; do
    printf 'target: cloudflare-workers\nstack: %s\n' "$s" >"$p/deploy.yml"
    rc=0
    out="$(cd "$p" && scripts/bootstrap-target.sh --repo acme/hello --dry-run 2>&1)" || rc=$?
    check "cloudflare-workers refuses the $s stack with 64" '[[ $rc == 64 ]] && grep -q "doesn.t support the $s stack" <<<"$out"'
  done
fi

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
