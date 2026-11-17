#!/usr/bin/env bash
# Send this branch's changes to the bot token broker, which commits them as
# the bot and can open a draft PR (spec 0002 FR-6, C3). For callers that can't
# push as the bot themselves, such as cloud Claude Code sessions.
#
# Usage:  scripts/bot-relay.sh [--pr "title"] [--pr-body "text"] [-m "message"] [--base main]
#
# Run it on a committed feat/ fix/ docs/ chore/ test/ or ci/ branch. The
# changes since the parent (origin/<branch> if it exists, else origin/<base>)
# become ONE bot commit; local history isn't kept. Afterwards the local branch
# is reset (soft) onto the bot's commit, so the next relay is a fast-forward.
#
# Broker URL: BOT_BROKER_URL, else ~/.config/agent-bot/broker_url (https only).
# Identity: ~/.config/agent-bot/identity on a signed-in device (bot-login.sh),
# sent in a header read from a pipe. In a cloud session there is no file: the
# environment's network proxy adds the Authorization header itself.
set -euo pipefail

config_dir="${BOT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-bot}"
max_bytes=$((1024 * 1024)) # the broker's /relay cap
branch_re='^(feat|fix|docs|chore|test|ci)/[a-z0-9._/-]{1,80}$'

die() {
  echo "bot-relay: $*" >&2
  exit 1
}
usage() {
  echo "usage: scripts/bot-relay.sh [--pr \"title\"] [--pr-body \"text\"] [-m \"message\"] [--base main]" >&2
  exit 64
}

pr_title="" pr_body="" message="" base="main"
while (($#)); do
  case "$1" in
    --pr) [[ $# -ge 2 ]] || usage; pr_title="$2"; shift 2 ;;
    --pr-body) [[ $# -ge 2 ]] || usage; pr_body="$2"; shift 2 ;;
    -m) [[ $# -ge 2 ]] || usage; message="$2"; shift 2 ;;
    --base) [[ $# -ge 2 ]] || usage; base="$2"; shift 2 ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

broker_url="${BOT_BROKER_URL:-$(cat "$config_dir/broker_url" 2>/dev/null || true)}"
[[ -n "$broker_url" ]] || die "no broker URL: set BOT_BROKER_URL or run scripts/bot-login.sh --broker <url>"
[[ "$broker_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] ||
  die "the broker URL must be https://host, not $broker_url"

branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch"
[[ "$branch" =~ $branch_re && "$branch" != *..* && "$branch" != *//* && "$branch" != */ ]] ||
  die "branch $branch can't be relayed: use feat/, fix/, docs/, chore/, test/ or ci/ plus lowercase a-z 0-9 . _ / -"
[[ -z "$(git status --porcelain)" ]] || die "commit or stash your changes first; only committed work is relayed"

# The parent: the branch on origin if it exists, else the base.
git fetch --quiet origin "$base" || die "can't fetch origin/$base"
if git fetch --quiet origin "$branch" 2>/dev/null; then
  parent="$(git rev-parse "origin/$branch")"
  git merge-base --is-ancestor "$parent" HEAD ||
    die "origin/$branch has commits you don't have: pull (git pull --rebase origin $branch) first"
else
  parent="$(git rev-parse "origin/$base")"
  git merge-base --is-ancestor "$parent" HEAD ||
    die "your branch is behind origin/$base: rebase on it first (git rebase origin/$base)"
fi
[[ "$(git rev-parse HEAD)" != "$parent" ]] || die "nothing to relay: HEAD is already $parent"

if [[ -z "$message" ]]; then
  count="$(git rev-list --count "$parent..HEAD")"
  [[ "$count" == 1 ]] || die "$count local commits become one bot commit: give its message with -m"
  message="$(git log -1 --format=%B HEAD)"
fi
((${#message} <= 5000)) || die "the commit message is ${#message} characters; the relay takes at most 5000"

# Build the payload in a temp dir, one file entry at a time.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: >"$work/files.jsonl"
# -z: paths come raw (no quoting of non-ASCII, tabs or quotes), NUL-separated.
while IFS= read -r -d '' status && IFS= read -r -d '' path; do
  [[ "$path" != *$'\n'* && "$path" != *$'\t'* ]] || die "a path with a tab or newline can't be relayed"
  lower="$(tr '[:upper:]' '[:lower:]' <<<"$path")"
  if [[ "$lower" == .github/workflows || "$lower" == .github/workflows/* || "/$lower/" == */.git/* || "/$path/" == */../* || "$path" == /* ]]; then
    die "$path can't be relayed (workflows, .git and .. paths are refused; the bot has no workflows permission)"
  fi
  if [[ "$status" == D ]]; then
    jq -nc --arg p "$path" '{path: $p, delete: true}' >>"$work/files.jsonl"
    continue
  fi
  mode="$(git --literal-pathspecs ls-tree HEAD -- "$path" | cut -d' ' -f1)"
  case "$mode" in
    100644 | 100755) ;;
    *) die "$path has mode $mode; the relay only takes regular files (100644, 100755)" ;;
  esac
  git cat-file blob "HEAD:$path" | base64 | tr -d '\n' >"$work/content"
  jq -nc --arg p "$path" --arg m "$mode" --rawfile c "$work/content" \
    '{path: $p, mode: $m, content_b64: $c}' >>"$work/files.jsonl"
done < <(git diff -z --name-status --no-renames "$parent" HEAD)

# owner/name: the last two parts of the origin URL (https, ssh or a proxy).
origin_url="$(git remote get-url origin)"
origin_url="${origin_url%.git}"
origin_url="${origin_url%/}"
repo="$(tr ':' '/' <<<"$origin_url" | awk -F/ '{ print $(NF - 1) "/" $NF }')"
[[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "can't tell owner/name from the origin URL"

jq -nc \
  --arg repo "$repo" \
  --arg branch "$branch" --arg base "$base" --arg parent "$parent" --arg message "$message" \
  --arg title "$pr_title" --arg body "$pr_body" \
  --slurpfile files "$work/files.jsonl" \
  '{repo: $repo, branch: $branch, base: $base, parent: $parent, message: $message, files: $files}
   + (if $title == "" then {} else {pr: {title: $title, body: $body}} end)' >"$work/payload.json"
size="$(wc -c <"$work/payload.json")"
((size <= max_bytes)) || die "the change is $size bytes; the relay takes at most $max_bytes. Split it into smaller relays"

# Send it. A signed-in device sends its identity; a cloud session's proxy
# adds it on the way.
send() {
  if [[ -s "$config_dir/identity" ]]; then
    curl -sS --max-time 60 -X POST -H 'Content-Type: application/json' \
      -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$config_dir/identity")") \
      --data @"$work/payload.json" -w '\n%{http_code}' "${broker_url%/}/relay/"
  else
    curl -sS --max-time 60 -X POST -H 'Content-Type: application/json' \
      --data @"$work/payload.json" -w '\n%{http_code}' "${broker_url%/}/relay/"
  fi
}
code=""
if reply="$(send)"; then
  code="${reply##*$'\n'}"
  body="${reply%$'\n'*}"
fi
if [[ "$code" != 200 ]]; then
  error="$(jq -r '.error // "unknown"' <<<"${body:-}" 2>/dev/null || echo unknown)"
  case "$error" in
    stale_parent) hint="the branch moved on GitHub; pull it and try again" ;;
    not_bot_branch) hint="the branch's last commit isn't the bot's; relay to a new branch" ;;
    path_denied) hint="a path is refused (workflows, .git, ..)" ;;
    no_token | bad_token) hint="no valid identity: sign in with scripts/bot-login.sh, or add the broker credential to this cloud environment" ;;
    *) hint="" ;;
  esac
  die "the broker refused: $error (HTTP ${code:-no answer})${hint:+; $hint}"
fi

commit="$(jq -r .commit <<<"$body")"
pr_url="$(jq -r '.pr_url // empty' <<<"$body")"
echo "bot-relay: committed $commit to $branch as the bot${pr_url:+; PR: $pr_url}"

# Match the local branch to the bot's commit, keeping the working tree.
git fetch --quiet origin "$branch"
git reset --quiet --soft "origin/$branch"
if ! git diff --cached --quiet; then
  echo "bot-relay: warning: the bot's commit differs from your local tree; see git diff --cached" >&2
fi
