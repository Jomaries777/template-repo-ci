#!/usr/bin/env bash
# Shared helper library for the 'none' deploy adapter.
set -euo pipefail

run() {
  if [[ "${DEPLOY_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
