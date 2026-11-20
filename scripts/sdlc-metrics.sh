#!/usr/bin/env bash
# Monthly SDLC metrics (spec §7, FR-10), v1: what the GitHub API can measure,
# with no AI. Prints a Markdown report for one calendar month; maintain.yml
# posts it as an issue. Metrics v1 can't measure yet are printed as "n/a"
# with the reason, never left out (plan.md Deviations, 2026-11-20).
#
# Usage: scripts/sdlc-metrics.sh [--repo owner/name] [--month YYYY-MM] [--due-tokens]
#   --month       default: the month before today (UTC)
#   --due-tokens  print only the names of tokens due for renewal (one per line)
# Env: GH_TOKEN with read access to contents, pull requests, issues, checks
#      and deployments (a workflow's GITHUB_TOKEN with those permissions).
#      <NAME>_SET_AT (YYYY-MM-DD) for each long-lived token: the repo
#      variables bootstrap writes when it sets the secret. A token is due for
#      renewal 11 months (335 days) after it was set.
#      SDLC_METRICS_NOW: epoch seconds to use as "now" (tests).
#
# Limits: one page (100) of merged PRs and of each issue search per month, and
# the newest 100 production deployments overall, which fits a solo project.
# The report says when the PR or deployment list was cut off. Lead time is
# measured from the deployed commit's date, so a redeploy of an old commit
# would read long.
set -euo pipefail

TOKENS=(CLAUDE_CODE_OAUTH_TOKEN CLOUDFLARE_API_TOKEN)
RENEW_DAYS=335

die() {
  echo "sdlc-metrics: $*" >&2
  exit 1
}
usage() {
  echo "usage: scripts/sdlc-metrics.sh [--repo owner/name] [--month YYYY-MM] [--due-tokens]" >&2
  exit 64
}

repo="${GITHUB_REPOSITORY:-}" month="" due_only=0
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || usage; repo="$2"; shift 2 ;;
    --month) [[ $# -ge 2 ]] || usage; month="$2"; shift 2 ;;
    --due-tokens) due_only=1; shift ;;
    *) usage ;;
  esac
done

now="${SDLC_METRICS_NOW:-$(jq -n 'now | floor')}"
[[ "$now" =~ ^[0-9]+$ ]] || die "invalid SDLC_METRICS_NOW: $now"
# Check the dates here, not in token_rows: it runs in a subshell, where a
# failure would not stop the report. A real calendar date: 2026-02-30 fails,
# because it doesn't survive a round trip through mktime.
for name in "${TOKENS[@]}"; do
  var="${name}_SET_AT"
  [[ -n "${!var:-}" ]] || continue
  if ! [[ "${!var}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
    ! jq -en --arg d "${!var}" 'try ($d | strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d") == $d) catch false' >/dev/null; then
    die "invalid $var: ${!var} (want a date, YYYY-MM-DD)"
  fi
done

# --- tokens: needs no API, so --due-tokens works without one.
# token_rows: "name<TAB>set_at<TAB>age_days<TAB>due" per token with a date.
# An untracked adapter token is listed only when deploy.yml uses its target.
token_rows() {
  local name var set_at target
  target="$(sed -n 's/^target:[[:space:]]*\([a-z0-9-]*\).*/\1/p' "${DEPLOY_CONFIG:-deploy.yml}" 2>/dev/null | head -n 1)"
  for name in "${TOKENS[@]}"; do
    var="${name}_SET_AT"
    set_at="${!var:-}"
    if [[ -z "$set_at" ]]; then
      [[ "$name" != CLOUDFLARE_API_TOKEN || "$target" == cloudflare-workers ]] || continue
      printf '%s\t\t\t\n' "$name"
      continue
    fi
    jq -nr --arg n "$name" --arg d "$set_at" --argjson now "$now" --argjson renew "$RENEW_DAYS" '
      (($now - ($d + "T00:00:00Z" | fromdateiso8601)) / 86400 | floor) as $age
      | [$n, $d, ($age | tostring), (if $age >= $renew then "due" else "" end)] | @tsv'
  done
}

if ((due_only)); then
  token_rows | awk -F '\t' '$4 == "due" { print $1 }'
  exit 0
fi

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "set GITHUB_REPOSITORY or pass --repo owner/name"

# --- the month: [start, end] as dates, and as ISO bounds for timestamps.
if [[ -z "$month" ]]; then
  month="$(jq -nr --argjson t "$now" '$t | gmtime | if .[1] == 0 then [.[0] - 1, 12] else [.[0], .[1]] end
    | "\(.[0])-\(if .[1] < 10 then "0" else "" end)\(.[1])"')"
fi
[[ "$month" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || die "invalid --month: $month (want YYYY-MM)"
start="$month-01"
end="$(jq -nr --arg m "$month" '($m | split("-") | map(tonumber)) as [$y, $mo]
  | (if $mo == 12 then [$y + 1, 0] else [$y, $mo] end) as [$ny, $nm]
  | [$ny, $nm, 1, 0, 0, 0, 0, 0] | mktime - 86400 | strftime("%Y-%m-%d")')"
from="${start}T00:00:00Z" to="${end}T23:59:59Z"

api() { gh api "$1" || die "GitHub API call failed: $1"; }
# search <qualifiers>: items of an issues/PR search in this repo, one page.
search() {
  local q="repo:$repo $1"
  api "search/issues?per_page=100&q=$(jq -rn --arg q "$q" '$q | @uri')"
}

# --- merged PRs: first-pass ci-ok and Claude reviews.
prs="$(search "is:pr is:merged merged:$start..$end")"
pr_total="$(jq '.total_count' <<<"$prs")"
pr_cut=""
[[ "$pr_total" -le 100 ]] || pr_cut=" (first 100 of $pr_total)"
first_pass=0 evaluated=0 reviews=0 skipped=0
while IFS= read -r n; do
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  sha="$(api "repos/$repo/pulls/$n/commits?per_page=1" | jq -r '.[0].sha // empty')"
  if [[ -n "$sha" ]]; then
    # The first attempt: reruns add runs, and the API lists the newest first.
    conclusion="$(api "repos/$repo/commits/$sha/check-runs?check_name=ci-ok&per_page=100" |
      jq -r '.check_runs | sort_by(.started_at) | .[0].conclusion // empty')"
    if [[ -n "$conclusion" ]]; then
      evaluated=$((evaluated + 1))
      [[ "$conclusion" == success ]] && first_pass=$((first_pass + 1))
    fi
  fi
  counts="$(api "repos/$repo/issues/$n/comments?per_page=100" | jq -r '
    [(map(select(.body | startswith("<!-- claude-review -->"))) | length),
     (map(select(.body | startswith("<!-- claude-review-skipped -->"))) | length)] | @tsv')"
  reviews=$((reviews + ${counts%%$'\t'*}))
  skipped=$((skipped + ${counts##*$'\t'}))
done < <(jq -r '.items[].number' <<<"$prs")
merged="$(jq '.items | length' <<<"$prs")"

# --- production deploys: successful statuses in the month, and lead time from
# the deployed commit (on main, the merge) to that status.
deps="$(api "repos/$repo/deployments?environment=production&per_page=100")"
# Cut off only when the page is full and doesn't reach back to the month's
# start: then older deployments in the month may be missing.
dep_cut="$(jq -r --arg f "$from" 'if length >= 100 and (map(.created_at) | min) > $f
  then " (newest 100 deployments only: may undercount)" else "" end' <<<"$deps")"
leads="[]" deploys=0
while IFS=$'\t' read -r id sha; do
  [[ "$id" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
  ok_at="$(api "repos/$repo/deployments/$id/statuses?per_page=100" | jq -r --arg f "$from" --arg t "$to" '
    map(select(.state == "success" and .created_at >= $f and .created_at <= $t)) | .[0].created_at // empty')"
  [[ -n "$ok_at" ]] || continue
  deploys=$((deploys + 1))
  merged_at="$(api "repos/$repo/commits/$sha" | jq -r '.commit.committer.date // empty')"
  [[ -n "$merged_at" ]] || continue
  leads="$(jq -c --arg a "$merged_at" --arg b "$ok_at" '. + [(($b | fromdateiso8601) - ($a | fromdateiso8601)) / 60]' <<<"$leads")"
done < <(jq -r '.[] | "\(.id)\t\(.sha)"' <<<"$deps")

# --- issues opened in the month by the pipeline's own jobs.
failures="$(search "is:issue label:deploy-failure created:$start..$end")"
# The label exists once maintain.yml's daily smoke test has opened an issue;
# until then "0 / 0" would look healthy, so the row says n/a instead.
smoke_label=true
gh api "repos/$repo/labels/prod-smoke-failure" >/dev/null 2>&1 || smoke_label=false
smoke="$(search "is:issue label:prod-smoke-failure created:$start..$end")"

# --- report. jq does the arithmetic so the script runs the same on macOS.
fmt="$(jq -nr \
  --arg month "$month" --arg repo "$repo" --arg cut "$pr_cut" --arg dcut "$dep_cut" \
  --argjson merged "$merged" --argjson evaluated "$evaluated" --argjson first "$first_pass" \
  --argjson reviews "$reviews" --argjson skipped "$skipped" \
  --argjson deploys "$deploys" --argjson leads "$leads" \
  --argjson failures "$failures" --argjson smoke "$smoke" --argjson smoke_label "$smoke_label" '
  def median: sort | if length == 0 then null else .[(length - 1) / 2 | floor] end;
  def pct($a; $b): if $b == 0 then "n/a (none)" else "\($a * 100 / $b | round)% (\($a)/\($b))" end;
  def mins: if . == null then "n/a (none)" elif . < 120 then "\(round) min" else "\(. / 60 * 10 | round / 10) h" end;
  ($failures.items | length) as $fail
  | ($failures.items | map(select(.closed_at)) | map(((.closed_at | fromdateiso8601) - (.created_at | fromdateiso8601)) / 60) | median) as $restore
  | [
    "# SDLC metrics: \($month)",
    "",
    "`\($repo)`, calendar month \($month) (UTC). Measured from the GitHub API by `scripts/sdlc-metrics.sh`, with no AI.",
    "",
    "| Play | Metric | Value |",
    "|---|---|---|",
    "| Build | PRs merged\($cut) | \($merged) |",
    "| Build | First-pass `ci-ok` (merged PRs whose first commit passed) | \(pct($first; $evaluated)) |",
    "| Review | Claude reviews per merged PR | \(if $merged == 0 then "n/a (none)" else "\($reviews * 10 / $merged | round / 10) (\($reviews) reviews)" end) |",
    "| Review | Claude reviews skipped (quota or token) | \($skipped) |",
    "| Deploy | Production deploys\($dcut) | \($deploys) |",
    "| Deploy | Median lead time, merge to production | \($leads | median | mins) |",
    "| Deploy | Change failure rate (`deploy-failure` issues / production deploys) | \(pct($fail; $deploys)) |",
    "| Deploy | Median time to restore (`deploy-failure` issue open to close) | \($restore | mins) |",
    "| Maintain | `prod-smoke-failure` issues opened / closed | \(if $smoke_label then "\($smoke.items | length) / \($smoke.items | map(select(.closed_at)) | length)" else "n/a: no `prod-smoke-failure` label yet (the daily smoke test in maintain.yml opens these)" end) |",
    "| Cost | Claude reviews this month (on merged PRs) | \($reviews) |",
    "| Cost | GitHub Actions minutes | free (public repository) |",
    "| Cost | Deploy-target spend | n/a: not readable from CI; $0 by design, and cloud-run has a $10 budget alert |",
    "| Plan / Design | Intent to merged spec time; spec rework | n/a: not measured in v1 |",
    "| Build | Antigravity runs per PR; Claude interventions per run | n/a: not measured in v1 |",
    "| Maintain | Time from breach issue to intent | n/a: not measured in v1 |"
  ] | join("\n")')"
printf '%s\n' "$fmt"

printf '\n## Long-lived tokens (renew at %s days)\n\n| Token | Set | Age | Status |\n|---|---|---|---|\n' "$RENEW_DAYS"
# shellcheck disable=SC2016 # the backticks are Markdown, printed as is
while IFS=$'\t' read -r name set_at age due; do
  if [[ -z "$set_at" ]]; then
    printf '| `%s` | unknown | | not tracked: set the repo variable `%s_SET_AT` (YYYY-MM-DD) |\n' "$name" "$name"
  elif [[ "$due" == due ]]; then
    printf '| `%s` | %s | %s days | **renew now** |\n' "$name" "$set_at" "$age"
  else
    printf '| `%s` | %s | %s days | ok |\n' "$name" "$set_at" "$age"
  fi
done < <(token_rows)
