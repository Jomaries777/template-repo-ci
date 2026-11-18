#!/usr/bin/env bash
# Shared helpers for the github-pages deploy adapter (spec §4.11, C9). Sourced
# by every verb. Contract: a verb prints only its result (a URL or version)
# on stdout; progress, git and gh output and DRY-RUN lines go to stderr.
#
# How it deploys: Pages serves the `gh-pages` branch. A version is a commit
# on that branch. `promote` commits the stack's static export
# (`make build-static`) for one source commit and pushes it as a fast-forward;
# `revert` adds a commit that restores an earlier version's files. Nothing is
# force-pushed, so the branch history records every deploy and revert. There
# is no dark deploy: `preview` serves the export on localhost for the
# pre-traffic test, and `discard` stops it.
#
# DEPLOY_DRY_RUN=1 prints mutating commands instead of running them and
# answers read-only queries from fixtures, so every verb runs with no git
# push, gh or network.
# shellcheck disable=SC2034
set -euo pipefail

DRY_RUN="${DEPLOY_DRY_RUN:-0}"
BRANCH=gh-pages

die() {
  echo "github-pages: $*" >&2
  exit 1
}

usage_error() {
  echo "github-pages: $*" >&2
  exit 64
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    {
      printf 'DRY-RUN:'
      printf ' %q' "$@"
      printf '\n'
    } >&2
  else
    "$@" >&2
  fi
}

# query <fixture> <cmd...>: a read-only command's stdout, or the fixture in dry run.
query() {
  local fixture="$1"
  shift
  if [[ "$DRY_RUN" == "1" ]]; then
    {
      printf 'DRY-RUN:'
      printf ' %q' "$@"
      printf '\n'
    } >&2
    printf '%s\n' "$fixture"
  else
    "$@"
  fi
}

# init_common: ROOT, REPO, STACK_DIR and STATE (where the preview's pid lives).
init_common() {
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  REPO="${GITHUB_REPOSITORY:-}"
  if [[ -z "$REPO" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then REPO="owner/repo"; else REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"; fi
  fi
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository: $REPO"
  local stack
  stack="$(sed -n 's/^stack:[[:space:]]*\([a-z0-9-]*\).*/\1/p' "${DEPLOY_CONFIG:-$ROOT/deploy.yml}" 2>/dev/null | head -n 1)"
  if [[ -z "$stack" && "$DRY_RUN" == "1" ]]; then stack=node; fi
  [[ -n "$stack" ]] || die "deploy.yml names no stack (run make bootstrap)"
  STACK_DIR="$ROOT/stacks/$stack"
  STATE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/github-pages-${REPO//\//-}"
  mkdir -p "$STATE"
}

# env_check <env>: Pages has one site, so only production exists.
env_check() {
  case "${1:-}" in
    production) ;;
    dev) usage_error "github-pages has one site and no dev environment (target.yml lists production only)" ;;
    *) usage_error "environment must be production, got: ${1:-<empty>}" ;;
  esac
}

sha_check() {
  [[ "${1:-}" =~ ^[0-9a-f]{7,40}$ ]] || usage_error "invalid commit sha: ${1:-<empty>}"
}

# export_for <sha>: the stack's static export of the checked-out commit, built
# once per job (a stamp records which commit it was built for). Prints its dir.
export_for() {
  local sha="$1" dir="$STACK_DIR/dist/static" stamp="$STATE/export.sha"
  if [[ "$DRY_RUN" != "1" ]]; then
    local head
    head="$(git -C "$ROOT" rev-parse HEAD)"
    [[ "$head" == "$sha"* ]] || die "the checkout is at ${head:0:7}, not $sha: the export must come from the commit being deployed"
  fi
  if [[ "$DRY_RUN" != "1" && -f "$stamp" && "$(cat "$stamp")" == "$sha" && -f "$dir/index.html" ]]; then
    printf '%s\n' "$dir"
    return
  fi
  # Remove any earlier export first, so a build that writes nothing fails
  # here instead of publishing stale files.
  [[ "$DRY_RUN" == "1" ]] || rm -rf "$dir"
  APP_VERSION="$sha" run make -C "$STACK_DIR" build-static
  [[ "$DRY_RUN" == "1" || -f "$dir/index.html" ]] || die "make build-static wrote no $dir/index.html"
  [[ "$DRY_RUN" == "1" ]] || printf '%s\n' "$sha" >"$stamp"
  printf '%s\n' "$dir"
}

# git_pages <args...>: git authenticated with GH_TOKEN (the job's GITHUB_TOKEN,
# exported by the target-auth action). The token is read from the environment
# by a credential helper, so it never appears in an argument.
git_pages() {
  # shellcheck disable=SC2016 # the helper reads $GH_TOKEN when git runs it
  git -c credential.helper= \
    -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' \
    -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" "$@"
}

# remote_url: the repository to push to. PAGES_REMOTE is a test hook (a local
# bare repository); in CI it is always GitHub.
remote_url() { printf '%s\n' "${PAGES_REMOTE:-https://github.com/$REPO.git}"; }

# checkout_branch: a shallow clone of gh-pages in $STATE/site. Prints its path.
checkout_branch() {
  local site="$STATE/site"
  if [[ "$DRY_RUN" == "1" ]]; then
    run git clone --depth 20 --branch "$BRANCH" "$(remote_url)" "$site"
    printf '%s\n' "$site"
    return
  fi
  [[ -n "${GH_TOKEN:-}" || -n "${PAGES_REMOTE:-}" ]] || die "GH_TOKEN is not set (the target-auth action exports the job token)"
  rm -rf "$site"
  git_pages clone -q --depth 20 --branch "$BRANCH" "$(remote_url)" "$site" >&2 ||
    die "cannot clone the $BRANCH branch (run make bootstrap, which creates it)"
  printf '%s\n' "$site"
}

# commit_and_push <site> <src dir or empty> <message>: replace the site's files
# with <src>'s (plus .nojekyll), commit, push as a fast-forward and print the
# new commit. An empty <src> means "the files are already in place".
commit_and_push() {
  local site="$1" src="$2" message="$3"
  if [[ "$DRY_RUN" == "1" ]]; then
    run git -C "$site" commit -m "$message"
    run git -C "$site" push origin "HEAD:$BRANCH"
    printf '%s\n' "0000000000000000000000000000000000000000"
    return
  fi
  if [[ -n "$src" ]]; then
    find "$site" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    cp -R "$src/." "$site/"
  fi
  touch "$site/.nojekyll"
  git -C "$site" add -A
  git_pages -C "$site" commit -q --allow-empty -m "$message" >&2
  git_pages -C "$site" push -q origin "HEAD:$BRANCH" >&2
  git -C "$site" rev-parse HEAD
}

# wait_live <commit>: ask Pages to build, then wait (up to 5 min) until the
# latest build is <commit> and built.
wait_live() {
  local commit="$1" deadline=$((SECONDS + ${PAGES_WAIT_SECONDS:-300})) build status
  # A refused request (e.g. a job without pages: write) would otherwise only
  # show up as the timeout below: say so now, then still wait, since Pages
  # also builds on its own after a push.
  run gh api -X POST "repos/$REPO/pages/builds" --silent ||
    echo "github-pages: warning: could not request a Pages build (does the job have pages: write?); waiting for the push to trigger one" >&2
  [[ "$DRY_RUN" == "1" ]] && return 0
  while ((SECONDS < deadline)); do
    build="$(gh api "repos/$REPO/pages/builds/latest" 2>/dev/null || true)"
    status="$(jq -r '.status // empty' <<<"$build" 2>/dev/null || true)"
    if [[ "$(jq -r '.commit // empty' <<<"$build" 2>/dev/null)" == "$commit" ]]; then
      case "$status" in
        built) return 0 ;;
        errored) die "Pages build of ${commit:0:7} failed: $(jq -r '.error.message // "no message"' <<<"$build")" ;;
      esac
    fi
    sleep 5
  done
  die "Pages did not publish ${commit:0:7} within ${PAGES_WAIT_SECONDS:-300}s (last status: ${status:-none})"
}
