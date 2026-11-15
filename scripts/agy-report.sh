#!/usr/bin/env bash
# Milestone reporting for interactive Antigravity runs (/teamwork, /swarm).
#
# Usage: scripts/agy-report.sh <start|progress|blocked|done|failed> "<message>"
#                              [--repo owner/repo] [--dry-run]
#
# Finds the open PR for the current branch and the newest `antigravity/*`
# check run for it (on the PR head, else on the branch's recent commits; an
# `antigravity/interactive` run is created only if none exists anywhere), then:
#   start|progress  keep it in_progress, append a summary line
#   blocked         same, plus a PR comment so Claude Code wakes up
#   done            run the verification gate (changes exist, no
#                   .github/workflows/ paths, no protected paths (there is no
#                   override here: the interactive agent runs this script, so
#                   protected changes go to the owner, who reviews and runs
#                   `gh pr ready` themselves), `make lint test` with the harness
#                   restored from origin/main), commit+push leftovers as the
#                   bot, then record the final result as a check run on the
#                   current head SHA (the old run is marked neutral/superseded)
#   failed          final failure run on the PR head + PR comment
#
# Token handling: a short-lived bot token is minted by scripts/bot-token.sh on
# demand into a non-exported variable and passed inline only to the gh/git
# calls made here. It is never exported to the shell or the agent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/agy-run.sh
source "$SCRIPT_DIR/agy-run.sh"

kind="" message="" repo=""
while (($#)); do
  case "$1" in
    --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    --allow-protected) die "--allow-protected is owner-only: use scripts/agy-run.sh, or review and run gh pr ready yourself" ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)
      if [[ -z "$kind" ]]; then kind="$1"
      elif [[ -z "$message" ]]; then message="$1"
      else die "unexpected argument: $1"; fi
      shift
      ;;
  esac
done
case "$kind" in start | progress | blocked | done | failed) ;; *) die "usage: agy-report.sh <start|progress|blocked|done|failed> \"<message>\"" ;; esac
[[ -n "$message" ]] || message="$kind"

root="$(git rev-parse --show-toplevel)"
branch="$(git -C "$root" rev-parse --abbrev-ref HEAD)"
if [[ "$branch" == HEAD ]]; then
  # Dry runs only print commands, so CI's detached PR checkout can still test them.
  [[ "${DRY_RUN:-0}" == 1 ]] || die "detached HEAD: check out the PR branch first"
  branch="DRY-RUN-BRANCH"
fi
[[ -n "$repo" ]] || repo="$(repo_from_remote)"
setup_bot_token "$repo"

check_json_on() { # sha -> newest antigravity/* check run object (or empty)
  ghb api "repos/$repo/commits/$1/check-runs" \
    --jq '[.check_runs[] | select(.name | startswith("antigravity/"))] | sort_by(.started_at) | last // empty'
}

# Open PR for this branch.
if [[ "$DRY_RUN" == 1 ]]; then
  pr="<PR_NUMBER>" sha="<HEAD_SHA>"
  run gh pr list --repo "$repo" --head "$branch" --state open --json number,headRefOid
else
  info="$(ghb pr list --repo "$repo" --head "$branch" --state open --json number,headRefOid --jq '.[0] // empty')"
  [[ -n "$info" ]] || die "no open PR for branch $branch"
  pr="$(jq -r .number <<<"$info")"
  sha="$(jq -r .headRefOid <<<"$info")"
fi

# Newest antigravity/* check run: on the head, else on recent PR commits.
check_id="" check_name="" check_sha="" old_summary=""
if [[ "$DRY_RUN" == 1 ]]; then
  check_id="<CHECK_RUN_ID>" check_name="antigravity/<mode>" check_sha="<CHECK_SHA>"
  run gh api "repos/$repo/commits/$sha/check-runs" --jq '<newest antigravity/* run>'
else
  found="$(check_json_on "$sha")"
  if [[ -z "$found" ]]; then
    while IFS= read -r c; do
      [[ -n "$c" && "$c" != "$sha" ]] || continue
      found="$(check_json_on "$c")"
      [[ -z "$found" ]] || break
    done < <(ghb api "repos/$repo/pulls/$pr/commits?per_page=100" --jq 'reverse | .[:20] | .[].sha')
  fi
  if [[ -n "$found" ]]; then
    check_id="$(jq -r .id <<<"$found")"
    check_name="$(jq -r .name <<<"$found")"
    check_sha="$(jq -r .head_sha <<<"$found")"
    old_summary="$(jq -r '.output.summary // ""' <<<"$found")"
  else
    check_name="antigravity/interactive"
    check_sha="$sha"
    check_create "$repo" "$check_name" "$sha" "agy interactive: started" "Interactive run reporting."
    check_id="$CHECK_ID"
  fi
fi

ts="$(date -u +%H:%M:%SZ)"
summary="${old_summary:+$old_summary$'\n'}- $ts $kind: $message"
short="${check_name#antigravity/}"

case "$kind" in
  start | progress)
    check_update "$repo" "$check_id" "agy $short: $kind" "$summary"
    ;;
  blocked)
    check_update "$repo" "$check_id" "agy $short: blocked" "$summary"
    ghb pr comment "$pr" --repo "$repo" --body "Antigravity is **blocked**: $message"
    ;;
  failed)
    finalize_check "$repo" "$check_id" "$check_name" "$check_sha" "$sha" \
      "agy $short: failed" "$summary" failure
    ghb pr comment "$pr" --repo "$repo" --body "Antigravity **failed**: $message"
    ;;
  done)
    verify_gate "$root" -
    if [[ -z "$GATE_REASONS" ]]; then
      commit_and_push "$repo" "$root" "$branch" "feat: agy interactive run complete"
      cap final_sha "<FINAL_SHA>" git -C "$root" rev-parse HEAD
      finalize_check "$repo" "$check_id" "$check_name" "$check_sha" "$final_sha" \
        "agy $short: passed" "$summary"$'\n'"Verification gate passed." success
      ghb pr ready "$pr" --repo "$repo"
    else
      bullets="- ${GATE_REASONS//$'\n'/$'\n'- }"
      msg="Verification gate FAILED:"$'\n'"$bullets"
      finalize_check "$repo" "$check_id" "$check_name" "$check_sha" "$sha" \
        "agy $short: failed" "$summary"$'\n'"$msg" failure
      ghb pr comment "$pr" --repo "$repo" --body "$msg"
      echo "$msg" >&2
      exit 1
    fi
    ;;
esac
