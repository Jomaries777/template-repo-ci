#!/usr/bin/env bash
# Run an Antigravity mode against an accepted plan, reporting through GitHub
# as the agent bot (spec §4.8, plan.md M1 Track C + Deviations).
#
# Usage:
#   scripts/agy-run.sh <boost|plain|teamwork|swarm> <path/to/plan.md>
#                      [--task "<extra instruction>"] [--repo owner/repo]
#                      [--yes] [--allow-protected] [--dry-run]
#
# boost / plain  run headless (`agy -p ... --output-format stream-json --sandbox`)
#                and are verified by a tool-checked diff + `make lint test`.
# teamwork/swarm run INTERACTIVELY (headless /teamwork returns SUCCESS without
#                changing the workspace, Spike A). This script prepares the
#                worktree, draft PR and check run, then prints next steps;
#                the agent reports via scripts/agy-report.sh.
# --dry-run      prints every git/gh/agy command, executes nothing.
# --allow-protected  owner override: permit diffs touching protected harness
#                paths (.github/**, Makefile, tests/scripts/**, scripts/**,
#                .claude/settings.json, CLAUDE.md, AGENTS.md, REVIEW.md).
#                Changes under .github/workflows/ always fail the gate.
#
# Token handling: the bot token is minted by scripts/bot-token.sh into a
# NON-exported shell variable and passed inline (GH_TOKEN=... gh ...) only to
# the individual gh/git calls this script makes. Headless agy runs with
# GH_TOKEN/GITHUB_TOKEN stripped. The interactive agent never sees a token:
# scripts/agy-report.sh mints its own short-lived token per call and never
# exports it.
#
# This file can also be sourced (by agy-report.sh) for its helper functions.

DRY_RUN=0
ALLOW_PROTECTED=0
_TOK=""
_TOK_TS=0
BOT_REPO=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- helpers ---

fmt_arg() {
  local a="$1"
  if ((${#a} > 160)); then
    printf '%q' "${a:0:80}...[${#a} chars]"
  else
    printf '%q' "$a"
  fi
}

# Execute, or print in --dry-run mode.
run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    local a
    printf '+'
    if [[ "$1" == ghb ]]; then
      shift
      printf ' gh'
    fi
    for a in "$@"; do printf ' %s' "$(fmt_arg "$a")"; done
    printf '\n'
  else
    "$@"
  fi
}

# cap VAR PLACEHOLDER cmd... : capture stdout into VAR (placeholder in dry-run).
cap() {
  local var="$1" placeholder="$2"
  shift 2
  if [[ "$DRY_RUN" == 1 ]]; then
    run "$@"
    printf -v "$var" '%s' "$placeholder"
  else
    local out
    out="$("$@")"
    printf -v "$var" '%s' "$out"
  fi
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Test-only overrides (BOT_TOKEN_SCRIPT, AGY_PUSH_URL, AGY_GATE_PASS_ENV) are
# honoured only with AGY_TEST_MODE=1, so a stray env var cannot redirect the
# bot token or the push in real runs.
token_script() {
  if [[ "${AGY_TEST_MODE:-}" == 1 && -n "${BOT_TOKEN_SCRIPT:-}" ]]; then echo "$BOT_TOKEN_SCRIPT"; else echo "$SCRIPT_DIR/bot-token.sh"; fi
}
push_url() { # repo
  if [[ "${AGY_TEST_MODE:-}" == 1 && -n "${AGY_PUSH_URL:-}" ]]; then echo "$AGY_PUSH_URL"; else echo "https://x-access-token@github.com/$1.git"; fi
}

repo_from_remote() {
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  url="${url%.git}"
  case "$url" in
    *github.com[:/]*) echo "${url##*github.com[:/]}" ;;
    *)
      if [[ "${DRY_RUN:-0}" == 1 ]]; then echo "OWNER/REPO"; else die "cannot infer owner/repo from origin; pass --repo"; fi
      ;;
  esac
}

# Mint (or refresh) the bot token into a NON-exported variable. Never printed.
refresh_token() {
  [[ "$DRY_RUN" != 1 ]] || return 0
  local now
  now="$(date +%s)"
  if [[ -z "$_TOK" ]] || ((now - _TOK_TS > 2400)); then
    _TOK="$("$(token_script)" "$BOT_REPO")"
    _TOK_TS="$now"
  fi
}

setup_bot_token() {
  BOT_REPO="$1"
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "+ (bot token minted per call via scripts/bot-token.sh $BOT_REPO; never exported or printed)"
    return 0
  fi
  refresh_token
}

# gh as the bot: the token is passed inline to this one command only.
ghb() {
  if [[ "$DRY_RUN" == 1 ]]; then
    run ghb "$@"
    return 0
  fi
  refresh_token
  GH_TOKEN="$_TOK" gh "$@"
}

# Like ghb but discards stdout (PATCH responses).
ghq() {
  if [[ "$DRY_RUN" == 1 ]]; then
    ghb "$@"
  else
    ghb "$@" >/dev/null
  fi
}

bot_app_id() {
  local repo="$1"
  if [[ -n "${BOT_APP_ID:-}" ]]; then
    echo "$BOT_APP_ID"
  elif [[ "$DRY_RUN" == 1 ]]; then
    echo "<APP_ID>"
  else
    gh variable get BOT_APP_ID --repo "$repo"
  fi
}

# git as the bot identity: bot_git <repo> <dir> <git args...>
bot_git() {
  local repo="$1" dir="$2" id
  shift 2
  id="$(bot_app_id "$repo")"
  run git -C "$dir" -c user.name="jomaries777-agent-bot[bot]" \
    -c "user.email=${id}+jomaries777-agent-bot[bot]@users.noreply.github.com" "$@"
}

# Push over HTTPS as the bot; the token reaches git only via GIT_ASKPASS and
# inline env, never argv. The askpass temp file is always removed.
bot_push() {
  local repo="$1" dir="$2" branch="$3" rc=0
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "+ git -C $dir push https://x-access-token:<GH_TOKEN>@github.com/$repo.git HEAD:refs/heads/$branch"
    return 0
  fi
  refresh_token
  (
    askpass="$(mktemp)"
    trap 'rm -f "$askpass"' EXIT
    chmod 700 "$askpass"
    # shellcheck disable=SC2016
    printf '%s\n' '#!/bin/sh' 'echo "$GH_TOKEN"' >"$askpass"
    GH_TOKEN="$_TOK" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
      git -C "$dir" push "$(push_url "$repo")" "HEAD:refs/heads/$branch"
  ) || rc=$?
  return "$rc"
}

# check_create repo name sha title summary [conclusion] -> CHECK_ID
check_create() {
  local repo="$1" name="$2" sha="$3" title="$4" summary="$5" conclusion="${6:-}"
  if [[ -n "$conclusion" ]]; then
    cap CHECK_ID "<CHECK_RUN_ID>" ghb api -X POST "repos/$repo/check-runs" \
      -f "name=$name" -f "head_sha=$sha" -f status=completed -f "conclusion=$conclusion" \
      -f "output[title]=$title" -f "output[summary]=$summary" --jq .id
  else
    cap CHECK_ID "<CHECK_RUN_ID>" ghb api -X POST "repos/$repo/check-runs" \
      -f "name=$name" -f "head_sha=$sha" -f status=in_progress \
      -f "output[title]=$title" -f "output[summary]=$summary" --jq .id
  fi
}

# check_update repo id title summary [conclusion]
check_update() {
  local repo="$1" id="$2" title="$3" summary="$4" conclusion="${5:-}"
  if [[ -n "$conclusion" ]]; then
    ghq api -X PATCH "repos/$repo/check-runs/$id" -f status=completed \
      -f "conclusion=$conclusion" -f "output[title]=$title" -f "output[summary]=$summary"
  else
    ghq api -X PATCH "repos/$repo/check-runs/$id" -f status=in_progress \
      -f "output[title]=$title" -f "output[summary]=$summary"
  fi
}

# The final result must be visible on the PR head. If the head moved since the
# run was created, create the final run on the new SHA and mark the old one
# neutral ("superseded"); a check run's head_sha cannot be changed.
# finalize_check repo old_id name old_sha new_sha title summary conclusion
finalize_check() {
  local repo="$1" old_id="$2" name="$3" old_sha="$4" new_sha="$5" title="$6" summary="$7" conclusion="$8"
  if [[ "$new_sha" == "$old_sha" ]]; then
    check_update "$repo" "$old_id" "$title" "$summary" "$conclusion"
  else
    check_create "$repo" "$name" "$new_sha" "$title" "$summary" "$conclusion"
    check_update "$repo" "$old_id" "$title (superseded)" "superseded by $new_sha" neutral
  fi
}

# Paths an agent run may not touch unless the owner passes --allow-protected.
PROTECTED_RE='^(\.github/|Makefile$|tests/scripts/|scripts/|\.claude/settings\.json$|CLAUDE\.md$|AGENTS\.md$|REVIEW\.md$)'

# Run `make lint test` with Makefile and tests/scripts/ restored from
# origin/main so a modified harness can't fake a pass. The agent's versions
# are put back afterwards.
run_harness_make() { # wt logfile
  # Runs `make lint test` with Makefile and tests/scripts/ taken from
  # origin/main, so an agent cannot weaken the gate. The agent's versions are
  # restored by an EXIT/INT/TERM trap, so an interrupt cannot lose them.
  # The environment is scrubbed (env -i + allowlist) so no tokens reach the
  # agent-written code that lint/test executes. Residual risk: it still runs
  # as the owner's user (HOME, keychain); see plan.md Deviations.
  local wt="$1" log="$2"
  (
    set -euo pipefail
    bk="$(mktemp -d)"
    keep=()
    for p in Makefile tests/scripts; do
      if [[ -e "$wt/$p" ]]; then keep+=("$p"); fi
    done
    if ((${#keep[@]})); then tar -C "$wt" -cf "$bk/harness.tar" "${keep[@]}"; fi
    # shellcheck disable=SC2329 # invoked via trap
    restore() {
      rm -rf "${wt:?}/Makefile" "${wt:?}/tests/scripts"
      if [[ -f "$bk/harness.tar" ]] && ! tar -C "$wt" -xf "$bk/harness.tar"; then
        echo "agy-run: could not restore Makefile/tests/scripts; saved copy kept at $bk/harness.tar" >&2
        return
      fi
      rm -rf "$bk"
    }
    trap restore EXIT
    trap 'exit 130' INT TERM
    rm -rf "${wt:?}/Makefile" "${wt:?}/tests/scripts"
    for p in Makefile tests/scripts; do
      git -C "$wt" archive origin/main -- "$p" 2>/dev/null | tar -x -C "$wt" || true
    done
    extra=()
    if [[ "${AGY_TEST_MODE:-}" == 1 ]]; then
      for v in ${AGY_GATE_PASS_ENV:-}; do extra+=("$v=${!v:-}"); done
    fi
    env -i ${extra[@]+"${extra[@]}"} PATH="$PATH" HOME="$HOME" LANG="${LANG:-C.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" TERM="${TERM:-dumb}" \
      make -C "$wt" lint test >"$log" 2>&1
  )
}

# Verification gate (spec §4.8 as amended). Sets GATE_REASONS (newline-joined,
# empty = pass). Args: worktree-dir [agy-final-status|-]
verify_gate() {
  local wt="$1" agy_status="${2:--}" reasons="" changed prot log
  GATE_REASONS=""
  if [[ "$DRY_RUN" == 1 ]]; then
    run git -C "$wt" symbolic-ref -q HEAD
    run git -C "$wt" fetch -q origin main
    run git -C "$wt" diff --name-only origin/main
    run git -C "$wt" ls-files --others --exclude-standard
    echo "+ (gate) fail if: no changes; any path under .github/workflows/; protected paths without --allow-protected"
    echo "+ (gate) make lint test runs with Makefile and tests/scripts/ restored from origin/main"
    run make -C "$wt" lint test
    return 0
  fi
  if ! git -C "$wt" symbolic-ref -q HEAD >/dev/null; then
    GATE_REASONS="detached HEAD: check out the PR branch before verifying"
    return 0
  fi
  if ! git -C "$wt" fetch -q origin main; then
    GATE_REASONS="could not fetch origin/main, so the diff cannot be verified"
    return 0
  fi
  if [[ "$agy_status" != "-" && "$agy_status" != "SUCCESS" ]]; then
    reasons="agy final status is '$agy_status', not SUCCESS"
  fi
  changed="$({
    git -C "$wt" diff --name-only origin/main
    git -C "$wt" ls-files --others --exclude-standard
  } | sort -u)"
  if [[ -z "$changed" ]]; then
    reasons="${reasons:+$reasons$'\n'}no changes vs origin/main (agy may have reported success without writing anything)"
  fi
  if grep -q '^\.github/workflows/' <<<"$changed"; then
    reasons="${reasons:+$reasons$'\n'}changes under .github/workflows/ — the bot has no workflows permission; move them to an owner PR"
  fi
  prot="$(grep -E "$PROTECTED_RE" <<<"$changed" | grep -v '^\.github/workflows/' | head -n 10 | tr '\n' ' ' || true)"
  if [[ -n "$prot" && "$ALLOW_PROTECTED" != 1 ]]; then
    reasons="${reasons:+$reasons$'\n'}protected harness paths changed (${prot% }); an owner must pass --allow-protected after reviewing them"
  fi
  log="$(mktemp)"
  if ! run_harness_make "$wt" "$log"; then
    reasons="${reasons:+$reasons$'\n'}make lint test failed: $(tail -n 5 "$log" | tr '\n' ' ' | cut -c1-400)"
  fi
  rm -f "$log"
  GATE_REASONS="$reasons"
}

# Commit leftovers (if any) as the bot and push.
# Files an agent must never commit, even if it leaves them in the worktree.
SECRET_FILE_RE='(^|/)(\.env(\..*)?|.*\.(pem|key|p12|pfx)|id_(rsa|ecdsa|ed25519)(\.pub)?|\.netrc|events\.ndjson|credentials(\.json)?)$'

commit_and_push() { # repo wt branch message
  local repo="$1" wt="$2" branch="$3" msg="$4" bad
  run git -C "$wt" add -A
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "+ (commit) refuse staged files matching: $SECRET_FILE_RE"
  else
    bad="$(git -C "$wt" diff --cached --name-only | grep -E "$SECRET_FILE_RE" || true)"
    if [[ -n "$bad" ]]; then
      git -C "$wt" reset -q -- "$bad"
      die "refusing to commit secret-looking files: $(tr '\n' ' ' <<<"$bad")"
    fi
  fi
  if [[ "$DRY_RUN" == 1 ]] || [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
    bot_git "$repo" "$wt" commit -m "$msg"
  fi
  bot_push "$repo" "$wt" "$branch"
}

# ------------------------------------------------------------------- main ---

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

cost_class() {
  case "$1" in
    boost | plain) echo low ;;
    teamwork) echo medium ;;
    swarm) echo high ;;
  esac
}

main() {
  local mode="" plan="" task="" repo="" yes=0
  while (($#)); do
    case "$1" in
      --task) task="${2:?--task needs a value}"; shift 2 ;;
      --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
      --yes) yes=1; shift ;;
      --allow-protected) ALLOW_PROTECTED=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h | --help) usage 0 ;;
      -*) die "unknown option: $1" ;;
      *)
        if [[ -z "$mode" ]]; then mode="$1"
        elif [[ -z "$plan" ]]; then plan="$1"
        else die "unexpected argument: $1"; fi
        shift
        ;;
    esac
  done
  case "$mode" in boost | plain | teamwork | swarm) ;; *) usage 2 ;; esac
  [[ -n "$plan" ]] || usage 2
  [[ -f "$plan" ]] || die "plan not found: $plan"

  local root planabs
  root="$(git rev-parse --show-toplevel)"
  planabs="$(cd "$(dirname "$plan")" && pwd)/$(basename "$plan")"
  local planrel="${planabs#"$root"/}"
  if [[ ! "$planrel" =~ ^intent/([0-9]+)-([a-z0-9-]+)/plan\.md$ ]]; then
    die "plan must be intent/<id>-<slug>/plan.md inside this repo (got: $planrel)"
  fi
  local id="${BASH_REMATCH[1]}" slug="${BASH_REMATCH[2]}"
  local idslug="$id-$slug" intentdir="intent/$id-$slug"
  [[ -n "$repo" ]] || repo="$(repo_from_remote)"

  # 2. cost class / quota warning
  echo "Mode: $mode   cost class: $(cost_class "$mode")"
  if [[ "$mode" == swarm ]]; then
    echo "WARNING: Quota Heavy — /swarm consumes a large share of the Antigravity quota."
    if [[ "$yes" != 1 ]]; then
      echo "Refusing to continue without --yes. Re-run with --yes to confirm." >&2
      exit 3
    fi
  fi

  # 1. branch + worktree
  local branch="agy/$idslug" n=1
  run git -C "$root" fetch origin main
  if [[ "$DRY_RUN" != 1 ]]; then
    while git -C "$root" show-ref --verify --quiet "refs/heads/$branch" ||
      git -C "$root" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; do
      n=$((n + 1))
      branch="agy/$idslug-$n"
    done
  fi
  local wt
  wt="$(dirname "$root")/$(basename "$root").agy/${branch//\//-}"
  run git -C "$root" worktree add -b "$branch" "$wt" origin/main

  # Make sure the accepted intent folder exists in the worktree.
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "+ cp -Rn $root/$intentdir $wt/intent/   # only if missing on origin/main"
  elif [[ ! -f "$wt/$planrel" ]]; then
    mkdir -p "$wt/intent"
    cp -Rn "$root/$intentdir" "$wt/intent/"
  fi

  # 3. initial push + draft PR as the bot
  setup_bot_token "$repo"
  bot_git "$repo" "$wt" add -A
  bot_git "$repo" "$wt" commit --allow-empty -m "chore(agy): start $mode run for $idslug"
  bot_push "$repo" "$wt" "$branch"

  local base="https://github.com/$repo/blob/$branch/$intentdir"
  local body
  body="$(mktemp)"
  cat >"$body" <<EOF
Antigravity \`$mode\` run for **$idslug** (draft until the run passes its verification gate).

- Intent: $base/intent.md
- Spec: $base/spec.md
- Plan: $base/plan.md

Progress is reported on the \`antigravity/$mode\` check run.
EOF
  local prurl pr
  cap prurl "https://github.com/$repo/pull/<PR_NUMBER>" ghb pr create --repo "$repo" --draft \
    --base main --head "$branch" --title "agy($mode): $idslug" --body-file "$body"
  pr="${prurl##*/}"
  rm -f "$body"

  # 4. check run
  local sha
  cap sha "<HEAD_SHA>" git -C "$wt" rev-parse HEAD
  check_create "$repo" "antigravity/$mode" "$sha" "agy $mode: started" \
    "Run started for $idslug. Waiting for the first update."
  local check_id
  check_id="${CHECK_ID:?}"

  local instruction="Implement the accepted plan at $planrel. Follow AGENTS.md and CLAUDE.md. Do not modify anything under .github/workflows/. Do not push; the harness commits and pushes."
  [[ -z "$task" ]] || instruction="$instruction Extra instruction: $task"

  # 5. interactive modes stop here
  if [[ "$mode" == teamwork || "$mode" == swarm ]]; then
    cat <<EOF

Interactive mode: not running agy headless (headless /$mode does not change the workspace).
Draft PR: $prurl    Check run: antigravity/$mode (in_progress)

Next steps:
  1. cd $wt
  2. agy
  3. In agy, type:
       /$mode [skip-interview] $instruction
  4. Have the agent report at milestones:
       scripts/agy-report.sh <start|progress|blocked|done|failed> "<message>"
     (agy-report.sh mints its own short-lived bot token per call; no token is
     exported to your shell or to agy.)
  5. When finished, run: scripts/agy-report.sh done "<summary>"
     Add --allow-protected only after you have reviewed changes to protected paths.
EOF
    return 0
  fi

  # 5. headless boost / plain
  local prompt plan_text
  plan_text="$(cat "$planabs")"
  prompt="$instruction"$'\n\n'"--- plan.md ---"$'\n'"$plan_text"
  [[ "$mode" != boost ]] || prompt="/boost $prompt"
  local timeout="${AGY_TIMEOUT:-45m}" work summary_file cb agy_rc=0
  work="$(mktemp -d)"
  summary_file="$work/summary.json"
  cb="$work/on-progress.sh"
  cat >"$cb" <<'EOF'
#!/usr/bin/env bash
# Generated by agy-run.sh: PATCH the check run output from a summary file.
# Mints its own token per call; the token is never exported.
GH_TOKEN="$("$AGY_TOKEN_SCRIPT" "$AGY_REPO")" gh api -X PATCH "repos/$AGY_REPO/check-runs/$AGY_CHECK_ID" \
  -f "output[title]=agy $AGY_MODE: running" -F "output[summary]=@$1" >/dev/null
EOF
  chmod +x "$cb"

  if [[ "$DRY_RUN" == 1 ]]; then
    run env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
      agy -p "$prompt" --output-format stream-json --sandbox --print-timeout "$timeout"
    echo "+ | AGY_ON_PROGRESS=<patch check run $check_id> scripts/agy-events.sh > summary.json"
  else
    (
      cd "$wt"
      env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
        agy -p "$prompt" --output-format stream-json --sandbox --print-timeout "$timeout"
    ) | tee "$work/events.ndjson" |
      AGY_REPO="$repo" AGY_CHECK_ID="$check_id" AGY_MODE="$mode" \
        AGY_TOKEN_SCRIPT="$(token_script)" \
        AGY_THROTTLE_SECONDS="${AGY_THROTTLE_SECONDS:-60}" \
        AGY_ON_PROGRESS="$cb" AGY_SUMMARY_JSON="$summary_file" "$SCRIPT_DIR/agy-events.sh" ||
      agy_rc=$?
  fi

  local agy_status="NO_RESULT" summary_md="(no summary)"
  if [[ "$DRY_RUN" != 1 && -s "$summary_file" ]]; then
    agy_status="$(jq -r .status "$summary_file")"
    summary_md="$(jq -r '"status \(.status), steps \(.steps), files \(.files_written | length), delegations \(.delegations), errors \(.errors), tokens \(.total_tokens), \(.duration_seconds | floor)s"' "$summary_file")"
  elif [[ "$DRY_RUN" == 1 ]]; then
    agy_status="SUCCESS"
  fi

  # 6. verification gate
  verify_gate "$wt" "$agy_status"
  if [[ "$agy_rc" -ne 0 && "$DRY_RUN" != 1 ]]; then
    GATE_REASONS="${GATE_REASONS:+$GATE_REASONS$'\n'}agy exited with code $agy_rc"
  fi
  if [[ -z "$GATE_REASONS" ]]; then
    commit_and_push "$repo" "$wt" "$branch" "feat($idslug): implement plan via agy $mode"
    local final_sha
    cap final_sha "<FINAL_SHA>" git -C "$wt" rev-parse HEAD
    finalize_check "$repo" "$check_id" "antigravity/$mode" "$sha" "$final_sha" \
      "agy $mode: passed" "Verification gate passed. $summary_md" success
    ghb pr ready "$pr" --repo "$repo"
    rm -rf "$work"
    echo "agy $mode run passed: $prurl"
    return 0
  fi
  local msg bullets
  bullets="- ${GATE_REASONS//$'\n'/$'\n'- }"
  msg="Verification gate FAILED for agy $mode ($summary_md):"$'\n'"$bullets"
  check_update "$repo" "$check_id" "agy $mode: failed" "$msg" failure
  ghb pr comment "$pr" --repo "$repo" --body "$msg"
  echo "$msg" >&2
  echo "work dir kept for inspection: $work (events.ndjson may contain agent text; not uploaded)" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
