#!/usr/bin/env bash
# Tests for the stacks' smoke suites (spec C9, criterion 5). Run from the repo
# root. release.sh runs `make smoke` for the pre-traffic test and every live
# check, so a smoke run must never retry: a retry can reach an edge still
# serving the old version and turn a failing request into a pass (M3 step 6,
# finding 3). A bootstrapped project keeps one stack; missing stacks are
# skipped.
set -euo pipefail

failures=0
ok() { echo "ok - $1"; }
not_ok() {
  echo "not ok - $1"
  failures=$((failures + 1))
}

# smoke_recipe <stack>: the lines of the stack Makefile's smoke target.
smoke_recipe() {
  awk '/^smoke:/ { on = 1; next } on && /^[^\t]/ { exit } on' "stacks/$1/Makefile"
}

if [[ -f stacks/node/package.json ]]; then
  smoke="$(jq -r '.scripts.smoke // empty' stacks/node/package.json)"
  if [[ "$smoke" == *"--grep @prod-safe"* ]]; then ok "node: smoke runs the @prod-safe tests"; else not_ok "node: smoke runs the @prod-safe tests (got: $smoke)"; fi
  if [[ " $smoke " == *" --retries=0 "* ]]; then ok "node: smoke never retries"; else not_ok "node: smoke never retries (got: $smoke)"; fi
  if smoke_recipe node | grep -q 'npm run smoke'; then ok "node: make smoke uses npm run smoke"; else not_ok "node: make smoke uses npm run smoke"; fi
fi

if [[ -f stacks/python/Makefile ]]; then
  if grep -qiE 'rerun|flaky|retr(y|ies)' stacks/python/requirements-dev.txt stacks/python/pyproject.toml; then
    not_ok "python: no pytest rerun plugin or option"
  else
    ok "python: no pytest rerun plugin or option"
  fi
  if smoke_recipe python | grep -qiE 'rerun|flaky|retr(y|ies)'; then not_ok "python: smoke never retries"; else ok "python: smoke never retries"; fi
fi

if [[ -f stacks/go/Makefile ]]; then
  recipe="$(smoke_recipe go)"
  if grep -q -- '-count=1' <<<"$recipe" && ! grep -qiE -- '-count=([02-9]|1[0-9])|retr(y|ies)|rerun' <<<"$recipe"; then
    ok "go: smoke runs each test once"
  else
    not_ok "go: smoke runs each test once (recipe: $recipe)"
  fi
fi

if ((failures)); then
  echo "test_stacks: $failures failed"
  exit 1
fi
