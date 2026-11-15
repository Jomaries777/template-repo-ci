#!/usr/bin/env bash
# Tests for scripts/classify.sh (spec §4.2). Run from the repo root.
set -euo pipefail

classify="$PWD/scripts/classify.sh"
failures=0

# check <case name> <expected class> <file>...
check() {
  local name="$1" expected="$2"
  shift 2
  local files actual
  files="$(printf '%s\n' "$@")"
  actual="$(CLASSIFY_FILES="$files" "$classify")"
  if [[ "$actual" == "$expected" ]]; then
    echo "ok - $name"
  else
    echo "not ok - $name (expected $expected, got $actual)"
    failures=$((failures + 1))
  fi
}

# docs
check "readme only is docs" docs README.md
check "nested markdown is docs" docs stacks/node/README.md
check "docs dir is docs" docs docs/guide.md docs/diagram.png
check "intent dir is docs" docs intent/0002-x/intent.md intent/0002-x/spikes/out.ndjson
check "LICENSE is docs" docs LICENSE
check "PR template is docs" docs .github/pull_request_template.md
check "issue templates are docs" docs .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/config.yml

# config
check "workflow is config" config .github/workflows/pr.yml
check "dependabot and CODEOWNERS are config" config .github/dependabot.yml .github/CODEOWNERS
check "claude settings are config" config .claude/settings.json
check "markdown under .claude is config" config .claude/commands/intent.md .claude/skills/write-spec/SKILL.md
check "markdown under .github is config" config .github/copilot-instructions.md
check "root Makefile is config" config Makefile
check "lint configs are config" config .markdownlint-cli2.jsonc .editorconfig .gitignore stacks/node/eslint.config.js

# agent instruction files are config, not docs
check "CLAUDE.md is config" config CLAUDE.md
check "REVIEW.md is config" config REVIEW.md
check "AGENTS.md is config" config AGENTS.md
check "nested CLAUDE.md is config" config stacks/node/CLAUDE.md
check "CLAUDE.md with docs is config" config CLAUDE.md README.md intent/0001-x/plan.md

# code
check "shell script is code" code scripts/classify.sh
check "source file is code" code stacks/node/src/index.ts
check "stack Makefile is code" code stacks/node/Makefile
check "dependency manifest is code" code package.json
check "lookalike name is code" code CLAUDE.md.bak

# mixes and precedence
check "docs plus config is config" config README.md .github/workflows/pr.yml
check "docs plus code is code" code README.md scripts/deploy.sh
check "config plus code is code" code .github/workflows/pr.yml scripts/deploy.sh
check "all three is code" code README.md AGENTS.md tests/scripts/test_classify.sh
check "code first then docs is code" code src/main.go docs/a.md

# edge cases
check "path with spaces" docs "docs/my notes.md"
check "empty change list runs everything" code ""

# git mode: real diff between two commits
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(
  cd "$tmp"
  git init -q
  git config user.email test@example.invalid
  git config user.name test
  git config commit.gpgsign false
  echo a >README.md
  git add README.md
  git commit -qm base
  git tag base
  echo b >>README.md
  mkdir -p .github/workflows
  echo 'name: x' >.github/workflows/x.yml
  git add -A
  git commit -qm head
) >/dev/null
actual="$(cd "$tmp" && "$classify" base HEAD)"
if [[ "$actual" == config ]]; then
  echo "ok - git diff mode"
else
  echo "not ok - git diff mode (expected config, got $actual)"
  failures=$((failures + 1))
fi

if (cd "$tmp" && "$classify" base) >/dev/null 2>&1; then
  echo "not ok - missing head argument is an error"
  failures=$((failures + 1))
else
  echo "ok - missing head argument is an error"
fi

if [[ $failures -gt 0 ]]; then
  echo "$failures test(s) failed"
  exit 1
fi
