#!/usr/bin/env bash
# Tests for scripts/deploy-base.sh (spec §4.10). A fake gh serves deployment
# fixtures; a throwaway git repo provides real ancestry. Run from the repo root.
set -euo pipefail

base_sh="$PWD/scripts/deploy-base.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}

# A repo with commits A <- B <- C, and an unrelated commit X.
repo="$tmp/repo"
git init -q "$repo"
g() { git -C "$repo" -c user.email=t@t -c user.name=t "$@"; }
for n in A B C; do g commit -q --allow-empty -m "$n"; done
A="$(g rev-parse HEAD~2)" B="$(g rev-parse HEAD~1)" C="$(g rev-parse HEAD)"
main="$(g symbolic-ref --short HEAD)"
g checkout -q --orphan other
g commit -q --allow-empty -m X
X="$(g rev-parse HEAD)"
g checkout -q "$main"

# Fake gh: deployments from $FIX/deployments.json; each status from
# $FIX/status_<id>, or exits 1 if $FIX/fail exists.
mkdir -p "$tmp/bin" "$tmp/fix"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ -e "$FIX/fail" ]] && exit 1
path="$2"
case "$path" in
  */deployments\?*) cat "$FIX/deployments.json" ;;
  */statuses\?*)
    id="${path#*/deployments/}"; id="${id%%/*}"
    cat "$FIX/status_$id" 2>/dev/null || echo '[]' ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" FIX="$tmp/fix" GITHUB_REPOSITORY=acme/hello

# run <name> <expected stdout> <expected rc>
run() {
  local name="$1" want="$2" want_rc="$3" out rc=0
  out="$(cd "$repo" && "$base_sh" "$C" 2>/dev/null)" || rc=$?
  if [[ "$rc" == "$want_rc" && "$out" == "$want" ]]; then pass "$name"; else fail "$name (rc $rc, out [$out])"; fi
}
deployments() { printf '%s\n' "$1" >"$FIX/deployments.json"; }
# status <id> <state>: the statuses API returns newest first; "" means none.
status() {
  if [[ -n "$2" ]]; then printf '[{"state":"%s"}]\n' "$2" >"$FIX/status_$1"; else echo '[]' >"$FIX/status_$1"; fi
}

deployments "[{\"id\":3,\"sha\":\"$B\"},{\"id\":2,\"sha\":\"$A\"}]"
status 3 success
status 2 success
run "newest successful production deployment is the base" "$B" 0

status 3 failure
run "a failed deployment is skipped" "$A" 0

status 3 ""
status 2 in_progress
run "no successful deployment: nothing (classify as code)" "" 0

deployments "[]"
run "never deployed: nothing" "" 0

deployments "[{\"id\":5,\"sha\":\"$X\"}]"
status 5 success
run "a base that isn't an ancestor: nothing" "" 0

: >"$FIX/fail"
run "unreadable deployments fail closed" "" 1
rm -f "$FIX/fail"

rc=0
"$base_sh" not-a-sha >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 64 ]]; then pass "rejects a bad head sha"; else fail "bad head sha rc $rc"; fi

# The push that creates main (a repo just made from the template) has nothing
# to classify yet, so deploy.yml's classify job, and every job after it, is
# skipped for it.
classify_job="$(awk '/^  classify:$/ {on = 1; next} on && /^  [a-z]/ {exit} on' .github/workflows/deploy.yml)"
if grep -qE '^    if: \$\{\{ !github\.event\.created \}\}$' <<<"$classify_job"; then
  pass "deploy.yml skips classify on the push that creates main"
else
  fail "deploy.yml's classify job doesn't skip the push that creates main"
fi

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
