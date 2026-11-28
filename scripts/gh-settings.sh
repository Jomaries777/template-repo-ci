#!/usr/bin/env bash
# Apply the repo settings the spec requires (spec §4.3, §4.6, §4.7; C3, C4;
# spec 0003 FR-7). Idempotent: safe to re-run. Deterministic, no AI.
#
# Usage: scripts/gh-settings.sh [--repo owner/repo] [--template] [--dry-run]
#   --template  also mark the repo as a GitHub template (template-repo-ci only)
#   --dry-run   print every API call instead of executing it
#
# The main-review ruleset bypasses the -ci App (Integration actor_id). The ID
# comes from env CI_APP_ID, else the repo variable CI_APP_ID.
set -euo pipefail

repo=""
template=0
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || {
        echo "missing argument for --repo" >&2
        exit 64
      }
      repo="$2"
      shift 2
      ;;
    --template)
      template=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 64
      ;;
  esac
done
[ -n "$repo" ] || repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

root="$(cd "$(dirname "$0")/.." && pwd)"
ruleset_file="$root/.github/rulesets/main.json"
review_ruleset_file="$root/.github/rulesets/main-review.json"

ci_app_id="${CI_APP_ID:-}"
if [ -z "$ci_app_id" ] && [ "$dry_run" -eq 0 ]; then
  ci_app_id="$(gh variable get CI_APP_ID --repo "$repo" 2>/dev/null || true)"
fi
if [ "$dry_run" -eq 1 ]; then
  if [ -n "$ci_app_id" ] && ! [[ "$ci_app_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "gh-settings: CI_APP_ID must be a number (set env CI_APP_ID or repo variable CI_APP_ID), got: $ci_app_id" >&2
    exit 1
  fi
else
  if ! [[ "$ci_app_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "gh-settings: CI_APP_ID must be a number (set env CI_APP_ID or repo variable CI_APP_ID), got: ${ci_app_id:-<empty>}" >&2
    exit 1
  fi
fi

review_json=""
if [ -n "$ci_app_id" ]; then
  review_json="$(jq --argjson id "$ci_app_id" \
    '(.bypass_actors[] | select(.actor_type == "Integration") | .actor_id) = $id' \
    "$review_ruleset_file")"
  jq -e --argjson id "$ci_app_id" \
    '.bypass_actors[] | select(.actor_type == "Integration" and .actor_id == $id)' \
    >/dev/null <<<"$review_json" || {
    echo "gh-settings: failed to fill CI_APP_ID into $review_ruleset_file" >&2
    exit 1
  }
fi

run() {
  if [ "$dry_run" -eq 1 ]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
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

rulesets_json=""
if [ "$dry_run" -eq 0 ]; then
  rulesets_json="$(gh api "repos/$repo/rulesets")"
fi
ruleset_id() {
  jq -r --arg name "$1" '[.[]? | select(.name == $name) | .id] | first // empty' <<<"$rulesets_json"
}

# main-review goes first: applying main.json drops main's pull_request rule,
# so if main-review failed after it, main would be left without one.
step "Ruleset 'main-review' from .github/rulesets/main-review.json (CI_APP_ID=${ci_app_id:-<CI_APP_ID>})"
review_id=""
if [ "$dry_run" -eq 0 ]; then
  review_id="$(ruleset_id main-review)"
fi
if [ -n "$review_id" ]; then
  run gh api -X PUT "repos/$repo/rulesets/$review_id" --silent --input - <<<"$review_json"
else
  run gh api -X POST "repos/$repo/rulesets" --silent --input - <<<"$review_json"
fi

step "Ruleset 'main' from .github/rulesets/main.json (C4: admin bypass is PRs-only)"
main_id=""
if [ "$dry_run" -eq 0 ]; then
  main_id="$(ruleset_id main)"
fi
if [ -n "$main_id" ]; then
  run gh api -X PUT "repos/$repo/rulesets/$main_id" --silent --input "$ruleset_file"
else
  run gh api -X POST "repos/$repo/rulesets" --silent --input "$ruleset_file"
fi

step "Done: $repo"
