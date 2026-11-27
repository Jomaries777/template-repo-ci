#!/usr/bin/env bash
# Tests for scripts/app-manifest.sh (spec 0003 FR-1, C9): the App name rule
# and each App's permissions. Run from the repo root.
set -euo pipefail

src="$PWD"
failures=0
pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}
if ! command -v jq >/dev/null 2>&1; then
  echo "ok - skipped (needs jq)"
  exit 0
fi
am() { bash "$src/scripts/app-manifest.sh" "$@"; }
same() { # same <name> <got> <want>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got [$2], want [$3])"; fi
}

# --- names (C9)
same "name: claude" "$(am --name jomaries777 claude)" jomaries777-claude
same "name: agy" "$(am --name jomaries777 agy)" jomaries777-agy
same "name: ci" "$(am --name jomaries777 ci)" jomaries777-ci
same "name: the login is lower-cased" "$(am --name Jomaries777 claude)" jomaries777-claude

long=abcdefghijklmnopqrstuvwxyz1234 # 30 characters
cut_ok=1
for a in claude agy ci; do
  n="$(am --name "$long" "$a")"
  ((${#n} <= 34)) || cut_ok=0
  [[ "$n" == "abcdefghijklmnopqrstuvwxyz1-$a" ]] || cut_ok=0
done
if ((cut_ok)); then pass "name: a 30-character login is cut to 27, every name fits 34 and shares the prefix"; else fail "name: a 30-character login is cut to 27 (got $(am --name "$long" claude))"; fi
same "name: a 27-character login is kept whole" "$(am --name abcdefghijklmnopqrstuvwxyz1 claude)" abcdefghijklmnopqrstuvwxyz1-claude
same "name: a hyphen left at the end of the cut is dropped" "$(am --name abcdefghijklmnopqrstuvwxyz-ABCD claude)" abcdefghijklmnopqrstuvwxyz-claude

for bad in "" "a b" "has_underscore" "$long$long" "--" "-jomaries777"; do
  rc=0
  am --name "$bad" claude >/dev/null 2>&1 || rc=$?
  same "usage: login [${bad}] is refused" "$rc" 64
done
for bad in antigravity CI "" agent; do
  rc=0
  am jomaries777 "$bad" >/dev/null 2>&1 || rc=$?
  same "usage: agent [${bad}] is refused" "$rc" 64
done
rc=0
am jomaries777 >/dev/null 2>&1 || rc=$?
same "usage: a missing agent is refused" "$rc" 64

# --- manifests (FR-1)
agent_perms='{"actions":"read","checks":"write","contents":"write","issues":"write","metadata":"read","pull_requests":"write"}'
ci_perms='{"contents":"write","metadata":"read","pull_requests":"write"}'
for a in claude agy ci; do
  m="$(am jomaries777 "$a")"
  if jq -e . >/dev/null 2>&1 <<<"$m"; then pass "manifest $a: valid JSON"; else fail "manifest $a: valid JSON"; fi
  same "manifest $a: name matches --name" "$(jq -r .name <<<"$m")" "$(am --name jomaries777 "$a")"
  want="$agent_perms"
  [[ "$a" == ci ]] && want="$ci_perms"
  same "manifest $a: FR-1 permissions" "$(jq -cS .default_permissions <<<"$m")" "$want"
  same "manifest $a: no workflows, administration or secrets" \
    "$(jq '.default_permissions | (has("workflows") or has("administration") or has("secrets"))' <<<"$m")" false
  if jq -e '.description | test("<|>") | not' >/dev/null <<<"$m"; then pass "manifest $a: no placeholder left"; else fail "manifest $a: no placeholder left"; fi
  same "manifest $a: no webhook" "$(jq -c '[.hook_attributes.active, .default_events]' <<<"$m")" '[false,[]]'
done

exit $((failures > 0))
