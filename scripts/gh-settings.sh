#!/usr/bin/env bash
# Apply the repo settings the spec requires (spec §4.3, §4.6, §4.7; C3, C4).
# Idempotent: safe to re-run. Deterministic, no AI.
#
# Usage: scripts/gh-settings.sh [--repo owner/repo] [--template] [--dry-run]
#   --template  also mark the repo as a GitHub template (template-repo-ci only)
#   --dry-run   print every API call instead of executing it
set -euo pipefail

repo=""
template=0
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --template) template=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
[ -n "$repo" ] || repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

root="$(cd "$(dirname "$0")/.." && pwd)"
ruleset_file="$root/.github/rulesets/main.json"

run() {
  if [ "$dry_run" -eq 1 ]; then
    printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

step() { printf '==> %s\n' "$*"; }

step "Merge settings: squash only, delete branches, allow auto-merge"
run gh repo edit "$repo" \
  --enable-squash-merge \
  --enable-merge-commit=false \
  --enable-rebase-merge=false \
  --delete-branch-on-merge \
  --enable-auto-merge
if [ "$template" -eq 1 ]; then
  run gh repo edit "$repo" --template
fi

step "Security: secret scanning + push protection"
run gh api -X PATCH "repos/$repo" --silent --input - <<'JSON'
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
JSON

step "Security: Dependabot alerts + security updates, private vulnerability reporting"
run gh api -X PUT "repos/$repo/vulnerability-alerts" --silent
run gh api -X PUT "repos/$repo/automated-security-fixes" --silent
run gh api -X PUT "repos/$repo/private-vulnerability-reporting" --silent

step "CodeQL: default setup off (advanced setup runs in pr.yml, C3)"
# Can fail on repos where code scanning was never set up; that is already "off".
run gh api -X PATCH "repos/$repo/code-scanning/default-setup" --silent -f state=not-configured ||
  echo "    (default setup not changed; it is off unless someone enabled it)"

step "Actions: read-only default token; workflows cannot approve PRs"
run gh api -X PUT "repos/$repo/actions/permissions/workflow" --silent \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

step "Ruleset 'main' from .github/rulesets/main.json (C4: admin bypass is PRs-only)"
existing_id=""
if [ "$dry_run" -eq 0 ]; then
  existing_id="$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name=="main") | .id')"
fi
if [ -n "$existing_id" ]; then
  run gh api -X PUT "repos/$repo/rulesets/$existing_id" --silent --input "$ruleset_file"
else
  run gh api -X POST "repos/$repo/rulesets" --silent --input "$ruleset_file"
fi

step "Done: $repo"
