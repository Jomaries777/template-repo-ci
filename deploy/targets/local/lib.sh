#!/usr/bin/env bash
# Shared helpers for the `local` deploy adapter: a TEST-ONLY target that runs
# each version as a Docker container on the machine running the job (the
# GitHub Actions runner). It exercises deploy.yml and release.sh end to end
# with no cloud account. Nothing outlives the job: every deploy job starts
# empty, so `current` first starts the parent commit as the "previous"
# version, giving release.sh a real revert target.
#
# Same contract as the other adapters: stdout carries only results (URL or
# revision); progress goes to stderr. DEPLOY_DRY_RUN=1 prints commands and
# answers queries from fixtures.
# Variables set here are read by the verbs.
# shellcheck disable=SC2034
set -euo pipefail

DRY_RUN="${DEPLOY_DRY_RUN:-0}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

die() {
  echo "local: $*" >&2
  exit 1
}
usage_error() {
  echo "local: $*" >&2
  exit 64
}

# run <cmd...>: run a command (its output to stderr), or print it in dry run.
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

# env_vars <env>: sets ENV_NAME, STATE (state dir) and APP.
env_vars() {
  case "${1:-}" in
    dev | production) ENV_NAME="$1" ;;
    *) usage_error "environment must be dev or production, got: ${1:-<empty>}" ;;
  esac
  APP="${APP_NAME:-app}"
  [[ "$APP" =~ ^[a-z][a-z0-9-]{0,39}$ ]] || usage_error "invalid APP_NAME: $APP"
  STATE="${LOCAL_DEPLOY_STATE:-${RUNNER_TEMP:-/tmp}/deploy-local}/$ENV_NAME"
  [[ "$DRY_RUN" == "1" ]] || mkdir -p "$STATE"
}

# sha_vars <sha>: sets SHA and REV (the container name for that version).
sha_vars() {
  [[ "${1:-}" =~ ^[0-9a-f]{7,40}$ ]] || usage_error "invalid commit sha: ${1:-<empty>}"
  SHA="$1"
  REV="${APP}-${ENV_NAME}-c${SHA:0:7}"
}

# Port for a revision: a free one is picked at start and stored in STATE.
port_of() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo 18080
    return
  fi
  cat "$STATE/$1.port" 2>/dev/null || true
}

# live: the revision that serves the environment (the state file "live").
live() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "${DRY_RUN_LIVE:-${APP}-${ENV_NAME}-c0000000}"
    return
  fi
  cat "$STATE/live" 2>/dev/null || true
}

set_live() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: live <- $1" >&2
  else
    printf '%s\n' "$1" >"$STATE/live"
  fi
}

# stack_dir: the stack folder deploy.yml names (bootstrap writes `stack:`).
stack_dir() {
  local stack config="${DEPLOY_CONFIG:-$root/deploy.yml}"
  stack="$(sed -n 's/^stack:[[:space:]]*\([a-z0-9-]*\).*/\1/p' "$config" 2>/dev/null | head -n 1)"
  [[ -n "$stack" ]] || die "$config names no stack; run make bootstrap"
  [[ "$DRY_RUN" == "1" || -d "$root/stacks/$stack" ]] || die "stacks/$stack doesn't exist"
  echo "stacks/$stack"
}

# start_rev <rev> <build context> <version>: build the image and run it on a
# free localhost port, then wait up to 60s for /health. Prints nothing;
# fails if the container never becomes healthy.
start_rev() {
  local rev="$1" ctx="$2" version="$3" port
  run docker build -q -t "local/$rev" "$ctx"
  if [[ "$DRY_RUN" == "1" ]]; then
    port=18080
  else
    # Free now; another process could take it before docker binds it, in
    # which case docker run fails loudly. Fine on a single-job runner.
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    echo "$port" >"$STATE/$rev.port"
  fi
  # Remove a leftover container of the same name, if any (quietly: usually
  # there is none, and docker's "No such container" read as an error in logs).
  # Dry run skips the check so its output still shows the `docker rm` line.
  if [[ "$DRY_RUN" == "1" ]] || docker container inspect "$rev" >/dev/null 2>&1; then
    run docker rm -f "$rev" || true
  fi
  run docker run -d --name "$rev" -p "127.0.0.1:$port:8080" -e "APP_VERSION=$version" "local/$rev"
  [[ "$DRY_RUN" == "1" ]] && return 0
  local i
  for ((i = 0; i < 60; i++)); do
    curl -fsS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null && return 0
    sleep 1
  done
  echo "local: $rev did not become healthy in 60s" >&2
  return 1
}
