#!/usr/bin/env bash
# Feeds sample hook JSON to each hook script and asserts exit codes.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
hooks="$root/scripts/hooks"
fail=0

# expect <name> <want-exit> <script> <json> [env assignments...]
expect() {
  local name="$1" want="$2" script="$3" json="$4"
  shift 4
  local got=0
  printf '%s' "$json" | env "$@" "$script" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    echo "ok - $name"
  else
    echo "not ok - $name (want $want, got $got)"
    fail=1
  fi
}

edit() { jq -nc --arg p "$1" --arg c "${2:-x}" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}'; }

# protect-paths
p="$hooks/protect-paths.sh"
expect "protect: ruleset blocked" 2 "$p" "$(edit .github/rulesets/main.json)" A=1
expect "protect: lockfile blocked" 2 "$p" "$(edit package-lock.json)" A=1
expect "protect: go.sum blocked" 2 "$p" "$(edit sub/go.sum)" A=1
expect "protect: dist blocked" 2 "$p" "$(edit app/dist/bundle.js)" A=1
expect "protect: src allowed" 0 "$p" "$(edit src/app.ts)" A=1
expect "protect: workflow file allowed" 0 "$p" "$(edit .github/workflows/pr.yml)" A=1

# no-secrets (fake values assembled at runtime so this file holds no literal secret)
s="$hooks/no-secrets.sh"
fake_key="-----BEGIN RSA ""PRIVATE KEY-----"
fake_ghp="ghp_""abcdefghijklmnopqrstuvwxyz0123456789"
fake_aws="AKIA""ABCDEFGHIJKLMNOP"
expect "secrets: private key blocked" 2 "$s" "$(edit a.txt "$fake_key")" A=1
expect "secrets: ghp token blocked" 2 "$s" "$(edit a.txt "t=$fake_ghp")" A=1
expect "secrets: aws key blocked" 2 "$s" "$(edit a.txt "$fake_aws")" A=1
fake_pw="pass""word = \"hunter2hunter2\""
expect "secrets: password literal blocked" 2 "$s" "$(edit a.txt "$fake_pw")" A=1
expect "secrets: new_string blocked" 2 "$s" \
  "$(jq -nc --arg c "$fake_ghp" '{tool_input:{file_path:"a",new_string:$c}}')" A=1
expect "secrets: plain code allowed" 0 "$s" "$(edit a.txt 'const x = process.env.TOKEN')" A=1
expect "secrets: empty allowed" 0 "$s" '{"tool_input":{"file_path":"a"}}' A=1

# test-first
t="$hooks/test-first.sh"
expect "test-first: test on fix/ blocked" 2 "$t" "$(edit tests/foo.sh)" TEST_FIRST_BRANCH=fix/bug
expect "test-first: *.test.ts on fix/ blocked" 2 "$t" "$(edit src/a.test.ts)" TEST_FIRST_BRANCH=fix/bug
expect "test-first: test_*.py on fix/ blocked" 2 "$t" "$(edit pkg/test_a.py)" TEST_FIRST_BRANCH=fix/bug
expect "test-first: src on fix/ allowed" 0 "$t" "$(edit src/a.ts)" TEST_FIRST_BRANCH=fix/bug
expect "test-first: override allowed" 0 "$t" "$(edit tests/foo.sh)" TEST_FIRST_BRANCH=fix/bug ALLOW_TEST_EDIT=1
expect "test-first: test on feat/ allowed" 0 "$t" "$(edit tests/foo.sh)" TEST_FIRST_BRANCH=feat/x

# post-edit with a stubbed make
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/make" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == lint && -n "${STUB_LINT_FAIL:-}" ]]; then
  echo "lint error"
  exit 1
fi
exit 0
SH
chmod +x "$tmp/bin/make"
touch "$tmp/f.txt"
j="$(edit "$tmp/f.txt")"
expect "post-edit: lint ok" 0 "$hooks/post-edit.sh" "$j" PATH="$tmp/bin:$PATH" CLAUDE_PROJECT_DIR="$tmp"
expect "post-edit: lint failure exits 2" 2 "$hooks/post-edit.sh" "$j" PATH="$tmp/bin:$PATH" CLAUDE_PROJECT_DIR="$tmp" STUB_LINT_FAIL=1
expect "post-edit: missing file ignored" 0 "$hooks/post-edit.sh" "$(edit "$tmp/none.txt")" PATH="$tmp/bin:$PATH" CLAUDE_PROJECT_DIR="$tmp"

exit "$fail"
