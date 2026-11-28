#!/usr/bin/env bash
# Dry-run, stubbed-gh and schema tests for scripts/gh-settings.sh and both
# rulesets (.github/rulesets/main.json and main-review.json; spec 0003 FR-7).
# No network: --dry-run and stubbed gh run hermetically.
set -euo pipefail

unset CI_APP_ID

root="$(git rev-parse --show-toplevel)"
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }
has() { # name text regex
  if grep -Eq -- "$3" <<<"$2"; then ok "$1"; else nok "$1 (no match for: $3)"; fi
}
jq_file() { # name file filter
  if jq -e "$3" "$2" >/dev/null; then ok "$1"; else nok "$1"; fi
}

main_file="$root/.github/rulesets/main.json"
review_file="$root/.github/rulesets/main-review.json"

out="$(CI_APP_ID=5955211 "$root/scripts/gh-settings.sh" --repo o/r --dry-run 2>&1)"
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
has "ruleset main-review printed with CI_APP_ID" "$out" "Ruleset 'main-review' from \.github/rulesets/main-review\.json \(CI_APP_ID=5955211\)"
has "ruleset main-review API call printed" "$out" 'DRY-RUN: gh api -X POST repos/o/r/rulesets --silent --input -'
if grep -q -- '--template' <<<"$out"; then nok "no --template without flag"; else ok "no --template without flag"; fi

out_no_id="$(env -u CI_APP_ID "$root/scripts/gh-settings.sh" --repo o/r --dry-run 2>&1)"
has "dry-run without CI_APP_ID prints placeholder" "$out_no_id" "Ruleset 'main-review'.*CI_APP_ID=<CI_APP_ID>"

out_bad_dry=""
if out_bad_dry="$(CI_APP_ID=notanumber "$root/scripts/gh-settings.sh" --repo o/r --dry-run 2>&1)"; then
  nok "dry-run rejects non-numeric CI_APP_ID"
else
  has "dry-run non-numeric CI_APP_ID mentions CI_APP_ID" "$out_bad_dry" 'CI_APP_ID must be a number'
fi

out="$(CI_APP_ID=5955211 "$root/scripts/gh-settings.sh" --repo o/r --template --dry-run 2>&1)"
has "--template marks repo as template" "$out" 'gh repo edit o/r --template'

if "$root/scripts/gh-settings.sh" --bogus >/dev/null 2>&1; then nok "unknown flag errors"; else ok "unknown flag errors"; fi

# Stubbed gh: captures every call and stdin for ruleset payloads.
stub="$(mktemp -d)"
trap 'rm -rf "$stub"' EXIT
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_STUB_LOG"
case "$*" in
  "variable get CI_APP_ID --repo o/r")
    if [[ -n "${STUB_CI_APP_ID:-}" ]]; then
      echo "$STUB_CI_APP_ID"
      exit 0
    fi
    exit 1
    ;;
  "api repos/o/r/rulesets")
    echo "${STUB_RULESETS:-[]}"
    exit 0
    ;;
  *"default-setup"*)
    [[ -n "${STUB_FAIL_DEFAULT_SETUP:-}" ]] && exit 1
    exit 0
    ;;
  *"repos/o/r/rulesets"*"--input -"*)
    cat >"$GH_STUB_REVIEW_JSON"
    exit 0
    ;;
  *"--input -"*)
    cat >/dev/null
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$stub/gh"
export GH_STUB_LOG="$stub/gh.log"
export GH_STUB_REVIEW_JSON="$stub/review.json"

# Create path (fresh repo): neither ruleset exists -> POST both, never PUT.
: >"$GH_STUB_LOG"
rm -f "$GH_STUB_REVIEW_JSON"
PATH="$stub:$PATH" CI_APP_ID=12345678901234 STUB_RULESETS='[]' \
  "$root/scripts/gh-settings.sh" --repo o/r >/dev/null 2>&1
log="$(cat "$GH_STUB_LOG")"
has "fresh repo creates main (POST)" "$log" 'api -X POST repos/o/r/rulesets --silent --input .*/main\.json'
has "fresh repo creates main-review (POST)" "$log" 'api -X POST repos/o/r/rulesets --silent --input -'
if grep -q 'api -X PUT repos/o/r/rulesets' <<<"$log"; then nok "fresh repo does not PUT rulesets"; else ok "fresh repo does not PUT rulesets"; fi
jq_file "large numeric CI_APP_ID preserved exactly in main-review" "$GH_STUB_REVIEW_JSON" \
  '[.bypass_actors[] | select(.actor_type == "Integration" and .actor_id == 12345678901234)] | length == 1'

# Update path (idempotency): both rulesets exist (including duplicate name entries
# to verify jq first // empty has no pipefail SIGPIPE) -> PUT both, never POST.
: >"$GH_STUB_LOG"
rm -f "$GH_STUB_REVIEW_JSON"
PATH="$stub:$PATH" CI_APP_ID=5955211 STUB_RULESETS='[{"id":4242,"name":"main"},{"id":4249,"name":"main"},{"id":4343,"name":"main-review"},{"id":4349,"name":"main-review"}]' \
  "$root/scripts/gh-settings.sh" --repo o/r >/dev/null 2>&1
log="$(cat "$GH_STUB_LOG")"
has "re-run updates existing main ruleset (PUT rulesets/4242)" "$log" 'api -X PUT repos/o/r/rulesets/4242 '
has "re-run updates existing main-review ruleset (PUT rulesets/4343)" "$log" 'api -X PUT repos/o/r/rulesets/4343 '
if grep -q 'api -X POST repos/o/r/rulesets' <<<"$log"; then nok "re-run does not create a second ruleset"; else ok "re-run does not create a second ruleset"; fi
jq_file "env CI_APP_ID filled into main-review as a number" "$GH_STUB_REVIEW_JSON" \
  '.name == "main-review" and ([.bypass_actors[] | select(.actor_type == "Integration" and .actor_id == 5955211 and .bypass_mode == "pull_request")] | length == 1)'

# Order: main-review is applied before main loses its pull_request rule, so a
# failed main-review call never leaves main without a review requirement.
review_line="$(grep -n 'rulesets.*--input -' <<<"$log" | head -n 1 | cut -d: -f1)"
main_line="$(grep -n 'rulesets.*main\.json' <<<"$log" | head -n 1 | cut -d: -f1)"
if [[ -n "$review_line" && -n "$main_line" ]] && ((review_line < main_line)); then
  ok "main-review is applied before main"
else
  nok "main-review is applied before main (review line ${review_line:-none}, main line ${main_line:-none})"
fi

# Mixed path (cutover): main exists (PUT), main-review does not (POST).
# Also tests reading CI_APP_ID from repo variable when env CI_APP_ID is unset.
: >"$GH_STUB_LOG"
rm -f "$GH_STUB_REVIEW_JSON"
env -u CI_APP_ID PATH="$stub:$PATH" STUB_CI_APP_ID=7777 STUB_RULESETS='[{"id":4242,"name":"main"}]' \
  "$root/scripts/gh-settings.sh" --repo o/r >/dev/null 2>&1
log="$(cat "$GH_STUB_LOG")"
has "reads CI_APP_ID from repo variable when env is unset" "$log" '^variable get CI_APP_ID --repo o/r$'
has "mixed path updates main (PUT 4242)" "$log" 'api -X PUT repos/o/r/rulesets/4242 '
has "mixed path creates main-review (POST)" "$log" 'api -X POST repos/o/r/rulesets --silent --input -'
jq_file "repo variable CI_APP_ID filled into main-review as a number" "$GH_STUB_REVIEW_JSON" \
  '[.bypass_actors[] | select(.actor_type == "Integration" and .actor_id == 7777)] | length == 1'

# Missing CI_APP_ID error: env unset and repo variable missing -> fails before mutating.
: >"$GH_STUB_LOG"
missing_out=""
if missing_out="$(env -u CI_APP_ID PATH="$stub:$PATH" "$root/scripts/gh-settings.sh" --repo o/r 2>&1)"; then
  nok "missing CI_APP_ID fails"
else
  has "missing CI_APP_ID gives clear message" "$missing_out" 'CI_APP_ID must be a number'
fi
if grep -q 'repo edit' "$GH_STUB_LOG"; then nok "missing CI_APP_ID makes no mutating calls"; else ok "missing CI_APP_ID makes no mutating calls"; fi

# Non-numeric or zero CI_APP_ID from repo variable -> fails before mutating.
for bad in abc 0 -5; do
  : >"$GH_STUB_LOG"
  bad_out=""
  if bad_out="$(env -u CI_APP_ID PATH="$stub:$PATH" STUB_CI_APP_ID="$bad" "$root/scripts/gh-settings.sh" --repo o/r 2>&1)"; then
    nok "bad CI_APP_ID ($bad) fails"
  else
    has "bad CI_APP_ID ($bad) gives clear message" "$bad_out" 'CI_APP_ID must be a number'
  fi
  if grep -q 'repo edit' "$GH_STUB_LOG"; then nok "bad CI_APP_ID ($bad) makes no mutating calls"; else ok "bad CI_APP_ID ($bad) makes no mutating calls"; fi
done

# Tolerates default-setup failure and still applies both rulesets.
: >"$GH_STUB_LOG"
if PATH="$stub:$PATH" CI_APP_ID=5955211 STUB_FAIL_DEFAULT_SETUP=1 "$root/scripts/gh-settings.sh" --repo o/r >/dev/null 2>&1; then
  ok "default-setup failure is tolerated"
else
  nok "default-setup failure is tolerated"
fi
has "main ruleset still applied after default-setup failure" "$(cat "$GH_STUB_LOG")" 'api -X POST repos/o/r/rulesets --silent --input .*/main\.json'
has "main-review ruleset still applied after default-setup failure" "$(cat "$GH_STUB_LOG")" 'api -X POST repos/o/r/rulesets --silent --input -'

# Schema checks: .github/rulesets/main.json
jq_file "main ruleset: name is main" "$main_file" '.name == "main"'
jq_file "main ruleset: targets default branch" "$main_file" '.target == "branch" and .conditions.ref_name.include == ["~DEFAULT_BRANCH"]'
jq_file "main ruleset: active" "$main_file" '.enforcement == "active"'
jq_file "main ruleset: admin bypass is PRs-only (C4) and no Integration bypass" "$main_file" \
  '.bypass_actors == [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]'
jq_file "main ruleset: no deletion, no force push, linear" "$main_file" \
  '[.rules[].type] | contains(["deletion","non_fast_forward","required_linear_history"])'
jq_file "main ruleset: ci-ok required from GitHub Actions only" "$main_file" \
  '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks == [{"context":"ci-ok","integration_id":15368}]'
jq_file "main ruleset: pull_request rule moved out" "$main_file" \
  '[.rules[].type] | index("pull_request") == null'

# Schema checks: .github/rulesets/main-review.json
jq_file "main-review ruleset: name is main-review" "$review_file" '.name == "main-review"'
jq_file "main-review ruleset: targets default branch" "$review_file" '.target == "branch" and .conditions.ref_name.include == ["~DEFAULT_BRANCH"]'
jq_file "main-review ruleset: active" "$review_file" '.enforcement == "active"'
jq_file "main-review ruleset: admin + Integration placeholder bypass (pull_request only)" "$review_file" \
  '.bypass_actors == [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"},{"actor_id":"CI_APP_ID","actor_type":"Integration","bypass_mode":"pull_request"}]'
jq_file "main-review ruleset: 1 approval, code owner review, last-push approval, threads resolved" "$review_file" \
  '.rules[] | select(.type=="pull_request") | .parameters | .required_approving_review_count == 1 and .dismiss_stale_reviews_on_push and .require_code_owner_review == true and .require_last_push_approval and .required_review_thread_resolution'
jq_file "main-review ruleset: squash only" "$review_file" \
  '.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods == ["squash"]'
jq_file "main-review ruleset: no required_status_checks rule" "$review_file" \
  '[.rules[].type] | index("required_status_checks") == null'

exit "$fail"
