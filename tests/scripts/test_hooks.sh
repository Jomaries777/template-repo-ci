#!/usr/bin/env bash
# Feeds sample hook JSON to each hook script and asserts exit codes.
set -euo pipefail

# Overrides from the caller's environment (e.g. a session that allows
# workflow edits) must not leak in; cases that need one pass it explicitly.
unset ALLOW_WORKFLOW_EDIT ALLOW_TEST_EDIT

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
expect "protect: workflow blocked" 2 "$p" "$(edit .github/workflows/pr.yml)" A=1
expect "protect: workflow override allowed" 0 "$p" "$(edit .github/workflows/pr.yml)" ALLOW_WORKFLOW_EDIT=1

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
tok="tok""en"
expect "secrets: quoted literal blocked" 2 "$s" "$(edit a.txt "$tok = 'abcd1234efgh'")" A=1
expect "secrets: process.env ref allowed" 0 "$s" "$(edit a.txt "const $tok = process.env.API_VALUE")" A=1
expect "secrets: os.environ ref allowed" 0 "$s" "$(edit a.txt "$tok = os.environ['SOME_VALUE']")" A=1
expect "secrets: shell var ref allowed" 0 "$s" "$(edit a.txt "$tok=\"\${SOME_VALUE_X}\"")" A=1
expect "secrets: cmd subst allowed" 0 "$s" "$(edit a.txt "$tok=\"\$(scripts/bot-token.sh)\"")" A=1
expect "secrets: actions secrets ref allowed" 0 "$s" "$(edit a.txt "$tok: \${{ secrets.SOME_VALUE }}")" A=1
expect "secrets: bash command blocked" 2 "$s" \
  "$(jq -nc --arg c "echo $fake_ghp > f" '{tool_name:"Bash",tool_input:{command:$c}}')" A=1
expect "secrets: bash clean command allowed" 0 "$s" \
  '{"tool_name":"Bash","tool_input":{"command":"make lint test"}}' A=1
expect "secrets: empty allowed" 0 "$s" '{"tool_input":{"file_path":"a"}}' A=1

# test-first: real git path (merge-base + rev-list) in a temp repo
tf_repo="$(mktemp -d)"
trap 'rm -rf "$tf_repo"' EXIT
(
  cd "$tf_repo"
  git init -q -b main
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git checkout -q -b fix/real
) >/dev/null
tf_expect() { # name want
  local got=0
  (cd "$tf_repo" && edit tests/foo.sh | "$hooks/test-first.sh") >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$2" ]]; then echo "ok - $1"; else echo "not ok - $1 (want $2, got $got)"; fail=1; fi
}
tf_expect "test-first (git): fresh fix/ branch allows test edit" 0
git -C "$tf_repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "test: failing"
tf_expect "test-first (git): after first commit blocks test edit" 2

# test-first
t="$hooks/test-first.sh"
fb="TEST_FIRST_BRANCH=fix/bug"
expect "test-first: fresh fix/ branch allows test edit" 0 "$t" "$(edit tests/foo.sh)" "$fb" TEST_FIRST_COMMITS_AHEAD=0
expect "test-first: test after commit blocked" 2 "$t" "$(edit tests/foo.sh)" "$fb" TEST_FIRST_COMMITS_AHEAD=1
expect "test-first: *.test.ts after commit blocked" 2 "$t" "$(edit src/a.test.ts)" "$fb" TEST_FIRST_COMMITS_AHEAD=2
expect "test-first: test_*.py after commit blocked" 2 "$t" "$(edit pkg/test_a.py)" "$fb" TEST_FIRST_COMMITS_AHEAD=1
expect "test-first: src after commit allowed" 0 "$t" "$(edit src/a.ts)" "$fb" TEST_FIRST_COMMITS_AHEAD=1
expect "test-first: override allowed" 0 "$t" "$(edit tests/foo.sh)" "$fb" TEST_FIRST_COMMITS_AHEAD=1 ALLOW_TEST_EDIT=1
expect "test-first: test on feat/ allowed" 0 "$t" "$(edit tests/foo.sh)" TEST_FIRST_BRANCH=feat/x TEST_FIRST_COMMITS_AHEAD=3

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
expect "post-edit: relative path resolved" 2 "$hooks/post-edit.sh" "$(edit f.txt)" PATH="$tmp/bin:$PATH" CLAUDE_PROJECT_DIR="$tmp" STUB_LINT_FAIL=1
expect "post-edit: missing file ignored" 0 "$hooks/post-edit.sh" "$(edit "$tmp/none.txt")" PATH="$tmp/bin:$PATH" CLAUDE_PROJECT_DIR="$tmp"

exit "$fail"
