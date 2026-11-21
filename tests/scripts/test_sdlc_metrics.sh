#!/usr/bin/env bash
# Tests for scripts/sdlc-metrics.sh (spec §7, FR-10). A fake gh serves JSON
# fixtures by API path; "now" is fixed. Run from the repo root.
# shellcheck disable=SC2016 # expected output holds Markdown backticks
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
if ! command -v jq >/dev/null 2>&1; then
  echo "ok - skipped (needs jq)"
  exit 0
fi

# Fake gh: `gh api <path>` prints $FIX/<key>.json, where the key is the path
# with its query string removed and / replaced by _ (searches are keyed by
# their label or "prs"). It logs every path; a missing fixture fails.
mkdir -p "$tmp/bin" "$tmp/fix"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == api ]] || exit 99
path="$2"
echo "$path" >>"$FIX/calls"
case "$path" in
  search/issues*deploy-failure*) key=search_deploy_failure ;;
  search/issues*prod-smoke-failure*) key=search_smoke ;;
  search/issues*) key=search_prs ;;
  *) key="${path%%\?*}"; key="${key//\//_}" ;;
esac
cat "$FIX/$key.json" 2>/dev/null || { echo "fake gh: no fixture $key" >&2; exit 1; }
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" FIX="$tmp/fix" GITHUB_REPOSITORY=acme/app
# 2026-11-20T12:00:00Z: the default month is 2026-10.
export SDLC_METRICS_NOW=1795176000
export DEPLOY_CONFIG="$tmp/deploy.yml"
printf 'target: github-pages\n' >"$DEPLOY_CONFIG"

f() { cat >"$FIX/$1.json"; }
sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
sha_d=dddddddddddddddddddddddddddddddddddddddd
# Two merged PRs: #1 passed ci-ok first time and got one review; #2 failed
# its first ci-ok and got one review and one skip.
f search_prs <<<'{"total_count":2,"items":[{"number":1},{"number":2}]}'
f repos_acme_app_pulls_1_commits <<<"[{\"sha\":\"$sha_a\"}]"
f repos_acme_app_pulls_2_commits <<<"[{\"sha\":\"$sha_b\"}]"
f "repos_acme_app_commits_${sha_a}_check-runs" <<<'{"check_runs":[{"conclusion":"success"}]}'
# PR 2's first commit failed, then a rerun passed: the API lists the rerun
# first, but first-pass counts the earliest attempt.
f "repos_acme_app_commits_${sha_b}_check-runs" <<<'{"check_runs":[{"conclusion":"success","started_at":"2026-10-03T00:00:00Z"},{"conclusion":"failure","started_at":"2026-10-02T00:00:00Z"}]}'
f repos_acme_app_issues_1_comments <<<'[{"body":"<!-- claude-review -->\nok"},{"body":"thanks"}]'
f repos_acme_app_issues_2_comments <<<'[{"body":"<!-- claude-review -->\nfix x"},{"body":"<!-- claude-review-skipped -->\nquota"}]'
# Deployments: #10 succeeded in October, 30 min after its merge; #11 only in
# November (not counted); #12 never succeeded.
f repos_acme_app_deployments <<<"[{\"id\":10,\"sha\":\"$sha_d\"},{\"id\":11,\"sha\":\"$sha_d\"},{\"id\":12,\"sha\":\"$sha_d\"}]"
f repos_acme_app_deployments_10_statuses <<<'[{"state":"success","created_at":"2026-10-15T10:30:00Z"},{"state":"in_progress","created_at":"2026-10-15T10:20:00Z"}]'
f repos_acme_app_deployments_11_statuses <<<'[{"state":"success","created_at":"2026-11-02T09:00:00Z"}]'
f repos_acme_app_deployments_12_statuses <<<'[{"state":"failure","created_at":"2026-10-20T09:00:00Z"}]'
f "repos_acme_app_commits_${sha_d}" <<<'{"commit":{"committer":{"date":"2026-10-15T10:00:00Z"}}}'
# One deploy failure, restored after 90 minutes; one smoke failure, open.
f search_deploy_failure <<<'{"total_count":1,"items":[{"created_at":"2026-10-15T10:31:00Z","closed_at":"2026-10-15T12:01:00Z"}]}'
f search_smoke <<<'{"total_count":1,"items":[{"created_at":"2026-10-20T06:00:00Z","closed_at":null}]}'
f repos_acme_app_labels_prod-smoke-failure <<<'{"name":"prod-smoke-failure"}'

# run [VAR=value...]: run the script with extra environment, no arguments.
run() {
  rc=0
  : >"$FIX/calls"
  out="$(env "$@" "$src/scripts/sdlc-metrics.sh" 2>"$tmp/err")" || rc=$?
  err="$(cat "$tmp/err")"
}
# run_args [args...]: run the script with arguments.
run_args() {
  rc=0
  : >"$FIX/calls"
  out="$("$src/scripts/sdlc-metrics.sh" "$@" 2>"$tmp/err")" || rc=$?
  err="$(cat "$tmp/err")"
}
has() { if grep -qF -- "$2" <<<"$out"; then pass "$1"; else fail "$1 (missing: $2; out: $out; err: $err)"; fi; }
lacks() { if grep -qF -- "$2" <<<"$out"; then fail "$1 (found: $2)"; else pass "$1"; fi; }

run CLAUDE_CODE_OAUTH_TOKEN_SET_AT=2026-01-10
if [[ "$rc" == 0 ]]; then pass "report: exits 0"; else fail "report: rc $rc ($err)"; fi
has "default month is the previous one" "# SDLC metrics: 2026-10"
if grep -q 'merged%3A2026-10-01..2026-10-31' "$FIX/calls"; then pass "searches the whole month"; else fail "search range ($(cat "$FIX/calls"))"; fi
has "merged PRs" "| Build | PRs merged | 2 |"
has "first-pass ci-ok counts the earliest run, not a later rerun" "| 50% (1/2) |"
has "reviews per merged PR" "| 1 (2 reviews) |"
has "skipped reviews" "| Review | Claude reviews skipped (quota or token) | 1 |"
has "production deploys count only October successes" "| Deploy | Production deploys | 1 |"
has "lead time from merge to the success status" "| 30 min |"
has "change failure rate" "| 100% (1/1) |"
has "time to restore (under 2 h, in minutes)" "| Deploy | Median time to restore (\`deploy-failure\` issue open to close) | 90 min |"
has "smoke issues opened / closed" "| 1 / 0 |"
lacks "a full deployment list is not cut off when it reaches the month" "newest 100 deployments only"
has "unmeasured metrics are listed as n/a" "| Build | Antigravity runs per PR; Claude interventions per run | n/a: not measured in v1 |"
has "token age" '| `CLAUDE_CODE_OAUTH_TOKEN` | 2026-01-10 | 314 days | ok |'
lacks "no Cloudflare row for another target" "CLOUDFLARE_API_TOKEN"

run CLAUDE_CODE_OAUTH_TOKEN_SET_AT=2025-12-20
has "a token at 335 days is due" "| 335 days | **renew now** |"

run_args --month 2026-02
if grep -q 'merged%3A2026-02-01..2026-02-28' "$FIX/calls"; then pass "--month: February ends on the 28th"; else fail "--month range ($(tail -n 5 "$FIX/calls"))"; fi
has "untracked Claude token says how to track it" 'set the repo variable `CLAUDE_CODE_OAUTH_TOKEN_SET_AT`'

printf 'target: cloudflare-workers\n' >"$DEPLOY_CONFIG"
run
has "Cloudflare token listed for its target" '| `CLOUDFLARE_API_TOKEN` | unknown |'
printf 'target: github-pages\n' >"$DEPLOY_CONFIG"

# --due-tokens: names only, and no API call.
rc=0
out="$(CLAUDE_CODE_OAUTH_TOKEN_SET_AT=2025-01-01 CLOUDFLARE_API_TOKEN_SET_AT=2026-11-01 \
  "$src/scripts/sdlc-metrics.sh" --due-tokens 2>"$tmp/err")" || rc=$?
: >"$FIX/calls"
if [[ "$rc" == 0 && "$out" == CLAUDE_CODE_OAUTH_TOKEN ]]; then pass "--due-tokens prints only due names"; else fail "--due-tokens (rc $rc, out [$out])"; fi
rc=0
CLAUDE_CODE_OAUTH_TOKEN_SET_AT=2026-11-01 "$src/scripts/sdlc-metrics.sh" --due-tokens >"$tmp/o" 2>&1 || rc=$?
if [[ "$rc" == 0 && ! -s "$tmp/o" && ! -s "$FIX/calls" ]]; then pass "--due-tokens: nothing due, no API call"; else fail "--due-tokens quiet case"; fi

# Errors.
rc=0
"$src/scripts/sdlc-metrics.sh" --month 2026-13 >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 1 ]]; then pass "invalid --month refused"; else fail "invalid --month (rc $rc)"; fi
for bad in yesterday 2026-13-45 2026-02-30; do
  rc=0
  CLAUDE_CODE_OAUTH_TOKEN_SET_AT="$bad" "$src/scripts/sdlc-metrics.sh" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == 1 ]]; then pass "invalid _SET_AT refused: $bad"; else fail "invalid _SET_AT $bad (rc $rc)"; fi
done
rc=0
CLAUDE_CODE_OAUTH_TOKEN_SET_AT=2028-02-29 "$src/scripts/sdlc-metrics.sh" --due-tokens >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 0 ]]; then pass "a leap day is a valid _SET_AT"; else fail "leap day refused (rc $rc)"; fi

# 100 deployments, all newer than October: older October ones may be missing.
jq -n '[range(100) | {id: 10, sha: "dddddddddddddddddddddddddddddddddddddddd", created_at: "2026-11-05T00:00:00Z"}]' >"$FIX/repos_acme_app_deployments.json"
run
has "a full list that doesn't reach the month start is flagged" "newest 100 deployments only: may undercount"

# Before maintain.yml opens one, the label doesn't exist: n/a, not "0 / 0".
rm "$FIX/repos_acme_app_labels_prod-smoke-failure.json"
run
has "no smoke label yet: n/a" "n/a: no \`prod-smoke-failure\` label yet"

# A quiet month: every rate says none instead of dividing by zero.
for k in search_prs search_deploy_failure search_smoke; do echo '{"total_count":0,"items":[]}' >"$FIX/$k.json"; done
echo '[]' >"$FIX/repos_acme_app_deployments.json"
run
has "quiet month: first-pass n/a" "| First-pass \`ci-ok\` (merged PRs whose first commit passed) | n/a (none) |"
has "quiet month: change failure rate n/a" "| Deploy | Change failure rate (\`deploy-failure\` issues / production deploys) | n/a (none) |"
rm "$FIX/repos_acme_app_deployments.json"
run
if [[ "$rc" == 1 ]] && grep -q "GitHub API call failed" <<<"$err"; then pass "an API failure fails the run"; else fail "API failure (rc $rc, err $err)"; fi

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
