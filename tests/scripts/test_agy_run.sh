#!/usr/bin/env bash
# --dry-run tests for scripts/agy-run.sh and scripts/agy-report.sh (no network).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
run="$root/scripts/agy-run.sh"
report="$root/scripts/agy-report.sh"
plan="intent/0001-github-cicd-pipeline/plan.md"
slug="0001-github-cicd-pipeline"
# A bootstrapped project has no template intent: use a fixture plan instead
# (agy-run.sh needs intent/<id>-<slug>/plan.md inside the repo).
if [[ ! -f "$plan" ]]; then
  slug="0000-agy-run-fixture"
  plan="intent/$slug/plan.md"
  mkdir -p "intent/$slug"
  trap 'rm -rf "$root/intent/0000-agy-run-fixture"' EXIT
  printf '# Plan (test fixture)\n\nStatus: Accepted\n' >"$plan"
fi
fail=0

ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }
has() { # name text pattern
  if grep -Eq -- "$3" <<<"$2"; then ok "$1"; else nok "$1"; fi
}
hasnt() {
  if grep -Eq -- "$3" <<<"$2"; then nok "$1"; else ok "$1"; fi
}

out="$("$run" boost "$plan" --repo o/r --dry-run 2>&1)"
has "boost: agy flags" "$out" 'agy -p .* --output-format stream-json --sandbox'
hasnt "boost: never --mode auto" "$out" 'mode auto'
has "boost: agy runs with token env stripped" "$out" 'env -u GH_TOKEN -u GITHUB_TOKEN .*agy -p'
has "boost: gate restores harness from origin/main" "$out" 'restored from origin/main'
has "boost: final check run on superseding SHA" "$out" 'neutral'
has "boost: prompt starts with /boost" "$out" '/boost'
has "boost: branch agy/$slug" "$out" "agy/$slug"
has "boost: draft PR" "$out" 'gh pr create .*--draft'
has "boost: check run in_progress" "$out" 'check-runs.*antigravity/boost|antigravity/boost.*status=in_progress|status=in_progress'
has "boost: gate runs make lint test" "$out" 'make .* lint test'
has "boost: cost class low" "$out" 'cost class: low'
hasnt "boost: no token printed" "$out" 'ghs_|x-access-token:[A-Za-z0-9_]{10,}'

out="$("$run" plain "$plan" --repo o/r --dry-run 2>&1)"
has "plain: agy -p" "$out" 'agy -p'
hasnt "plain: no /boost prefix" "$out" 'agy -p /boost'

if out="$("$run" swarm "$plan" --repo o/r --dry-run 2>&1)"; then
  nok "swarm without --yes refuses"
else
  has "swarm without --yes refuses" "$out" '--yes'
fi
has "swarm: Quota Heavy warning" "$out" 'Quota Heavy'

out="$("$run" swarm "$plan" --repo o/r --yes --dry-run 2>&1)"
has "swarm --yes: interactive" "$out" 'Interactive mode'
hasnt "swarm --yes: no agy -p" "$out" 'agy -p'

out="$("$run" teamwork "$plan" --repo o/r --task "extra" --dry-run 2>&1)"
has "teamwork: interactive instructions" "$out" '/teamwork \[skip-interview\]'
has "teamwork: mentions agy-report" "$out" 'agy-report.sh'
has "teamwork: notes per-call token" "$out" 'mints its own short-lived bot token'
hasnt "teamwork: no agy -p" "$out" 'agy -p'
has "teamwork: cost class medium" "$out" 'cost class: medium'

if out="$("$run" boost intent/nope/plan.md --dry-run 2>&1)"; then
  nok "bad plan path errors"
else
  has "bad plan path errors" "$out" 'plan not found'
fi
if out="$("$run" boost tests/fixtures/agy/plain.ndjson --dry-run 2>&1)"; then
  nok "non-plan path errors"
else
  has "non-plan path errors" "$out" 'plan must be intent'
fi
if "$run" bogus "$plan" --dry-run >/dev/null 2>&1; then nok "bad mode errors"; else ok "bad mode errors"; fi

# agy-report.sh
out="$("$report" start "hello" --repo o/r --dry-run 2>&1)"
has "report start: PATCH check run in_progress" "$out" 'gh api -X PATCH repos/o/r/check-runs/.*status=in_progress'
out="$("$report" blocked "need input" --repo o/r --dry-run 2>&1)"
has "report blocked: PR comment" "$out" 'gh pr comment'
out="$("$report" failed "boom" --repo o/r --dry-run 2>&1)"
has "report failed: conclusion=failure" "$out" 'conclusion=failure'
out="$("$report" "done" "finished" --repo o/r --dry-run 2>&1)"
has "report done: gate make lint test" "$out" 'make .* lint test'
has "report done: conclusion=success" "$out" 'conclusion=success'
has "report done: pr ready" "$out" 'gh pr ready'
if "$report" bogus "x" --dry-run >/dev/null 2>&1; then nok "report bad kind errors"; else ok "report bad kind errors"; fi

exit "$fail"
