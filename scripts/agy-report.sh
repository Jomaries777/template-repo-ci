#!/usr/bin/env bash
# Milestone reporting for interactive Antigravity runs (/teamwork, /swarm).
#
# Usage: scripts/agy-report.sh <start|progress|blocked|done|failed> "<message>"
#                              [--repo owner/repo] [--dry-run]
#
# Finds the open PR for the current branch and the newest `antigravity/*`
# check run on its head SHA (creating `antigravity/interactive` if none), then:
#   start|progress  keep it in_progress, append a summary line
#   blocked         same, plus a PR comment so Claude Code wakes up
#   done            run the verification gate (changes exist, no
#                   .github/workflows/ paths, `make lint test`), commit+push
#                   leftovers as the bot, complete success|failure
#   failed          complete failure + PR comment
# All writes use the bot token from scripts/bot-token.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/agy-run.sh
source "$SCRIPT_DIR/agy-run.sh"

kind="" message="" repo=""
while (($#)); do
  case "$1" in
    --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
[[ -n "$repo" ]] || repo="$(repo_from_remote)"
setup_bot_token "$repo"

# Open PR for this branch.
if [[ "$DRY_RUN" == 1 ]]; then
  pr="<PR_NUMBER>" sha="<HEAD_SHA>"
  run gh pr list --repo "$repo" --head "$branch" --state open --json number,headRefOid
else
  info="$(gh pr list --repo "$repo" --head "$branch" --state open --json number,headRefOid --jq '.[0] // empty')"
  [[ -n "$info" ]] || die "no open PR for branch $branch"
  pr="$(jq -r .number <<<"$info")"
  sha="$(jq -r .headRefOid <<<"$info")"
fi

# Newest antigravity/* check run on the head SHA.
check_id="" old_summary="" check_name=""
if [[ "$DRY_RUN" == 1 ]]; then
  check_id="<CHECK_RUN_ID>"
  check_name="antigravity/<mode>"
  run gh api "repos/$repo/commits/$sha/check-runs" --jq '[.check_runs[] | select(.name | startswith("antigravity/"))] | sort_by(.started_at) | last'
else
  found="$(gh api "repos/$repo/commits/$sha/check-runs" --jq '[.check_runs[] | select(.name | startswith("antigravity/"))] | sort_by(.started_at) | last // empty')"
  if [[ -n "$found" ]]; then
    check_id="$(jq -r .id <<<"$found")"
    check_name="$(jq -r .name <<<"$found")"
    old_summary="$(jq -r '.output.summary // ""' <<<"$found")"
  else
    check_name="antigravity/interactive"
    check_create "$repo" "$check_name" "$sha" "agy interactive: started" "Interactive run reporting."
    check_id="$CHECK_ID"
  fi
fi

ts="$(date -u +%H:%M:%SZ)"
line="- $ts $kind: $message"
summary="${old_summary:+$old_summary$'\n'}$line"
title="agy ${check_name#antigravity/}: $kind"

case "$kind" in
  start | progress)
    check_update "$repo" "$check_id" "$title" "$summary"
    ;;
  blocked)
    check_update "$repo" "$check_id" "$title" "$summary"
    run gh pr comment "$pr" --repo "$repo" --body "Antigravity is **blocked**: $message"
    ;;
  failed)
    check_update "$repo" "$check_id" "$title" "$summary" failure
    run gh pr comment "$pr" --repo "$repo" --body "Antigravity **failed**: $message"
    ;;
  done)
    verify_gate "$root" -
    if [[ -z "$GATE_REASONS" ]]; then
      commit_and_push "$repo" "$root" "$branch" "feat: agy interactive run complete"
      check_update "$repo" "$check_id" "agy ${check_name#antigravity/}: passed" "$summary"$'\n'"Verification gate passed." success
      run gh pr ready "$pr" --repo "$repo"
    else
      msg="Verification gate FAILED:"$'\n'"- ${GATE_REASONS//$'\n'/$'\n'- }"
      check_update "$repo" "$check_id" "agy ${check_name#antigravity/}: failed" "$summary"$'\n'"$msg" failure
      run gh pr comment "$pr" --repo "$repo" --body "$msg"
      echo "$msg" >&2
      exit 1
    fi
    ;;
esac
