#!/usr/bin/env bash
# Classify a change as docs | config | code (spec §4.2). No AI, no network.
#
# Usage:  scripts/classify.sh <base> <head>
#         CLASSIFY_FILES=$'a.md\nb.sh' scripts/classify.sh   # tests: skip git
#
# Reads `git diff --name-only <base>...<head>` (or CLASSIFY_FILES, one path per
# line) and prints exactly one word on stdout.
#
# Rules, per file (first match wins):
#   1. docs   .github/pull_request_template.md, .github/ISSUE_TEMPLATE/**
#   2. config CLAUDE.md, REVIEW.md, AGENTS.md (any directory), .github/**,
#             .claude/**, root Makefile, lint/format configs
#   3. docs   *.md, docs/**, intent/**, LICENSE
#   4. code   anything else
# Agent instruction files are config, not docs: changing them changes
# behaviour. Config is checked before docs so that .md files under .claude/
# (commands, skills, agents) count as config.
#
# The change class is the highest file class: code > config > docs.
# An empty change list prints `code`, so an unexpected input runs every check.
set -euo pipefail

classify_file() {
  local path="$1"
  local base="${path##*/}"

  case "$path" in
    .github/pull_request_template.md | .github/ISSUE_TEMPLATE/*)
      echo docs
      return
      ;;
  esac

  case "$base" in
    CLAUDE.md | REVIEW.md | AGENTS.md)
      echo config
      return
      ;;
  esac

  case "$path" in
    .github/* | .claude/* | Makefile)
      echo config
      return
      ;;
  esac

  # Lint and format configs, at any depth.
  case "$base" in
    .markdownlint* | .editorconfig | .gitignore | .gitattributes | \
      .shellcheckrc | .yamllint | .yamllint.y*ml | .lycheeignore | lychee.toml | \
      .gitleaks.toml | gitleaks.toml | .pre-commit-config.y*ml | \
      .prettierrc* | prettier.config.* | .prettierignore | \
      .eslintrc* | eslint.config.* | .eslintignore | \
      .stylelintrc* | biome.json | biome.jsonc | \
      ruff.toml | .ruff.toml | .flake8 | mypy.ini | .golangci.y*ml)
      echo config
      return
      ;;
  esac

  case "$path" in
    *.md | docs/* | intent/* | LICENSE | LICENSE.*)
      echo docs
      return
      ;;
  esac

  echo code
}

main() {
  local files
  if [[ -n "${CLASSIFY_FILES+set}" ]]; then
    files="$CLASSIFY_FILES"
  else
    if [[ $# -ne 2 ]]; then
      echo "usage: $0 <base> <head>" >&2
      exit 2
    fi
    files="$(git diff --name-only "$1...$2")"
  fi

  local seen_config=0 seen_docs=0 any=0 path class
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    any=1
    class="$(classify_file "$path")"
    case "$class" in
      code)
        echo code
        return
        ;;
      config) seen_config=1 ;;
      docs) seen_docs=1 ;;
    esac
  done <<<"$files"

  if [[ $any -eq 0 ]]; then
    echo code
  elif [[ $seen_config -eq 1 ]]; then
    echo config
  elif [[ $seen_docs -eq 1 ]]; then
    echo docs
  fi
}

main "$@"
