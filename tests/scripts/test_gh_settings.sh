#!/usr/bin/env bash
# Dry-run test for scripts/gh-settings.sh and a schema check of the main
# ruleset. No network: --dry-run prints every gh call instead of running it.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }
has() { # name text regex
  if grep -Eq -- "$3" <<<"$2"; then ok "$1"; else nok "$1 (no match for: $3)"; fi
}
jq_true() { # name filter
  if jq -e "$2" "$root/.github/rulesets/main.json" >/dev/null; then ok "$1"; else nok "$1"; fi
}

out="$("$root/scripts/gh-settings.sh" --repo o/r --dry-run 2>&1)"
has "squash only" "$out" 'gh repo edit o/r --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false'
has "delete branch on merge" "$out" '--delete-branch-on-merge'
has "secret scanning + push protection" "$out" 'gh api -X PATCH repos/o/r'
has "dependabot alerts" "$out" 'repos/o/r/vulnerability-alerts'
has "dependabot security updates" "$out" 'repos/o/r/automated-security-fixes'
has "private vulnerability reporting" "$out" 'repos/o/r/private-vulnerability-reporting'
has "codeql default setup off" "$out" 'code-scanning/default-setup.*state=not-configured'
has "actions token read-only" "$out" 'default_workflow_permissions=read'
has "workflows cannot approve PRs" "$out" 'can_approve_pull_request_reviews=false'
has "ruleset created from main.json" "$out" 'repos/o/r/rulesets .*--input .*/\.github/rulesets/main\.json'
if grep -q -- '--template' <<<"$out"; then nok "no --template without flag"; else ok "no --template without flag"; fi

out="$("$root/scripts/gh-settings.sh" --repo o/r --template --dry-run 2>&1)"
has "--template marks repo as template" "$out" 'gh repo edit o/r --template'

if "$root/scripts/gh-settings.sh" --bogus >/dev/null 2>&1; then nok "unknown flag errors"; else ok "unknown flag errors"; fi

# Update path (idempotency): a stubbed gh returns an existing ruleset id, so
# the script must PUT rulesets/<id> instead of POSTing a second ruleset.
stub="$(mktemp -d)"
trap 'rm -rf "$stub"' EXIT
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_STUB_LOG"
case "$*" in
  "api repos/o/r/rulesets --jq"*) echo 4242 ;;
esac
exit 0
STUB
chmod +x "$stub/gh"
export GH_STUB_LOG="$stub/gh.log"
PATH="$stub:$PATH" "$root/scripts/gh-settings.sh" --repo o/r >/dev/null 2>&1
log="$(cat "$GH_STUB_LOG")"
has "re-run updates existing ruleset (PUT rulesets/4242)" "$log" 'api -X PUT repos/o/r/rulesets/4242 '
if grep -q 'api -X POST repos/o/r/rulesets' <<<"$log"; then nok "re-run does not create a second ruleset"; else ok "re-run does not create a second ruleset"; fi

: >"$GH_STUB_LOG"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_STUB_LOG"
case "$*" in *default-setup*) exit 1 ;; esac
exit 0
STUB
if PATH="$stub:$PATH" "$root/scripts/gh-settings.sh" --repo o/r >/dev/null 2>&1; then ok "default-setup failure is tolerated"; else nok "default-setup failure is tolerated"; fi
has "ruleset still applied after default-setup failure" "$(cat "$GH_STUB_LOG")" 'api -X POST repos/o/r/rulesets '

jq_true "ruleset: targets default branch" '.target == "branch" and .conditions.ref_name.include == ["~DEFAULT_BRANCH"]'
jq_true "ruleset: active" '.enforcement == "active"'
jq_true "ruleset: admin bypass is PRs-only (C4)" '.bypass_actors == [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]'
jq_true "ruleset: no deletion, no force push, linear" '[.rules[].type] | contains(["deletion","non_fast_forward","required_linear_history"])'
jq_true "ruleset: 1 approval, last-push approval, threads resolved" \
  '.rules[] | select(.type=="pull_request") | .parameters | .required_approving_review_count == 1 and .require_last_push_approval and .required_review_thread_resolution'
jq_true "ruleset: squash only" '.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods == ["squash"]'
jq_true "ruleset: ci-ok required from GitHub Actions only" \
  '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks == [{"context":"ci-ok","integration_id":15368}]'

exit "$fail"
