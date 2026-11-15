#!/usr/bin/env bash
# Shared helpers for the 'none' deploy adapter. Same contract as cloud-run:
# stdout carries only results; DRY-RUN lines and progress go to stderr.
set -euo pipefail

run() {
  if [[ "${DEPLOY_DRY_RUN:-0}" == "1" ]]; then
    {
      printf 'DRY-RUN:'
      printf ' %q' "$@"
      printf '\n'
    } >&2
  else
    "$@" >&2
  fi
}
