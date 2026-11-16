#!/usr/bin/env bash
# Tests for scripts/bootstrap.sh (spec §4.1, §4.9, FR-1). Runs bootstrap in
# throwaway copies of the working tree; fake gh/git/security fail loudly if a
# local-only or dry run ever calls them. Run from the repo root.
# check() takes its condition as a single-quoted string that it evals later,
# so SC2016 (no expansion in single quotes) and SC2034 (set but "unused") are
# expected here.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

src="$PWD"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
for cli in gh security; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/calls"\nexit 99\n' "$cli" "$tmp" >"$tmp/bin/$cli"
  chmod +x "$tmp/bin/$cli"
done
ORIG_PATH="$PATH"
export PATH="$tmp/bin:$PATH"

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# copy <dir>: the current working tree (tracked + untracked, not ignored).
copy() {
  mkdir -p "$1"
  (cd "$src" && git ls-files -co --exclude-standard -z | tar --null -cf - -T -) | tar -xf - -C "$1"
}

# --- local-only: node on cloud-run
a="$tmp/a"
copy "$a"
rc=0
out="$(BOOTSTRAP_OWNER=acme "$a/scripts/bootstrap.sh" --stack node --target cloud-run --local-only 2>&1)" || rc=$?
check "local-only: exits 0" '[[ $rc == 0 ]] || { echo "$out"; false; }'
check "keeps only the chosen stack" '[[ "$(ls "$a/stacks")" == node ]]'
check "keeps only the chosen adapter" '[[ "$(ls "$a/deploy/targets")" == cloud-run ]]'
check "deploy.yml names target and stack" 'grep -qx "target: cloud-run" "$a/deploy.yml" && grep -qx "stack: node" "$a/deploy.yml"'
check "deploy.yml keeps environments and smoke" 'grep -q "dev:        { enabled: true }" "$a/deploy.yml" && grep -q "live_checks: 3" "$a/deploy.yml"'
check "removes the template self-test" '[[ ! -e "$a/.github/workflows/template-selftest.yml" ]]'
check "keeps the other workflows" '[[ -f "$a/.github/workflows/pr.yml" ]]'
check "removes the template-only bootstrap test" '[[ ! -e "$a/tests/scripts/test_bootstrap.sh" && -f "$a/tests/scripts/test_deploy.sh" ]]'
check "removes the template intent folders" '[[ -z "$(find "$a/intent" -mindepth 1 -type d)" && -f "$a/intent/.gitkeep" ]]'
check "CODEOWNERS names the new owner" 'grep -qx "\* @acme" "$a/.github/CODEOWNERS" && ! grep -q Jomaries777 "$a/.github/CODEOWNERS"'
check "README stub names the stack and target" 'grep -q "Stack: \`node\`" "$a/README.md" && grep -q "Deploy target: \`cloud-run\`" "$a/README.md"'
check "root make delegates to the stack" 'make -C "$a" -n typecheck 2>/dev/null | grep -q "stacks/node"'
check "deploy.sh reads the new target" '[[ "$(APP_NAME=hello DEPLOY_DRY_RUN=1 "$a/scripts/deploy.sh" url dev 2>/dev/null)" == https://hello-dev-dryrun.a.run.app ]]'

# The bootstrapped project's own script tests must pass (they ship with it).
# Stack tests need npm and are run by its CI; these need only bash and git.
(cd "$a" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm boot)
proj_fail=""
for t in "$a"/tests/scripts/test_*.sh; do
  [[ -x "$t" ]] || continue
  (cd "$a" && env -u ALLOW_WORKFLOW_EDIT -u ALLOW_TEST_EDIT PATH="$ORIG_PATH" "$t") >/dev/null 2>&1 || proj_fail+=" $(basename "$t")"
done
check "bootstrapped project: its script tests pass" '[[ -z "$proj_fail" ]] || { echo "failed:$proj_fail"; false; }'
rm -rf "$a/.git"

before="$(cd "$a" && find . -type f | sort | xargs cksum)"
rc=0
out="$(BOOTSTRAP_OWNER=acme "$a/scripts/bootstrap.sh" --stack node --target cloud-run --local-only 2>&1)" || rc=$?
after="$(cd "$a" && find . -type f | sort | xargs cksum)"
check "rerun: exits 0 and says already bootstrapped" '[[ $rc == 0 ]] && grep -q "already bootstrapped" <<<"$out"'
check "rerun: changes no file" '[[ "$before" == "$after" ]]'

rc=0
"$a/scripts/bootstrap.sh" --stack node --target none --local-only >/dev/null 2>&1 || rc=$?
check "rerun with another target exits 64" '[[ $rc == 64 ]]'

# --- argument errors (fresh copy)
b="$tmp/b"
copy "$b"
for args in "--target none --local-only" "--stack node --local-only" "--stack cobol --target none --local-only" \
  "--stack node --target heroku --local-only" "--stack ../x --target none --local-only" "--bogus"; do
  rc=0
  # shellcheck disable=SC2086 # split on purpose
  "$b/scripts/bootstrap.sh" $args >/dev/null 2>&1 || rc=$?
  check "rejects '$args' with 64" '[[ $rc == 64 ]]'
done
check "rejected runs change nothing" '[[ -d "$b/deploy/targets/none" && -f "$b/.github/workflows/template-selftest.yml" ]]'

# --- dry run: prints every change and remote call, performs none
c="$tmp/c"
copy "$c"
list_before="$(cd "$c" && find . | sort)"
rc=0
out="$(BOT_APP_ID=123 GCP_PROJECT_ID=hello-proj-1 BILLING_ACCOUNT=0A1B2C-3D4E5F-6A7B8C \
  "$c/scripts/bootstrap.sh" --stack node --target cloud-run --repo acme/hello --dry-run 2>&1)" || rc=$?
list_after="$(cd "$c" && find . | sort)"
check "dry run: exits 0" '[[ $rc == 0 ]] || { echo "$out" | tail -5; false; }'
check "dry run: changes no file" '[[ "$list_before" == "$list_after" ]]'
has() { if grep -qF -- "$2" <<<"$out"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
has "dry run: deletes the unused adapter" "DRY-RUN: rm -rf deploy/targets/none"
has "dry run: pushes to main before the ruleset exists" "DRY-RUN: git push origin HEAD:main"
has "dry run: applies repo settings" "DRY-RUN: gh repo edit acme/hello"
has "dry run: creates dev" "DRY-RUN: gh api -X PUT repos/acme/hello/environments/dev"
has "dry run: production with a required reviewer" "DRY-RUN: gh api -X PUT repos/acme/hello/environments/production"
has "dry run: production limited to main" "deployment-branch-policies --silent -f name=main -f type=branch"
has "dry run: Claude token secret" "gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo acme/hello --app actions"
has "dry run: bot key mirrored to Dependabot" "gh secret set BOT_APP_PRIVATE_KEY --repo acme/hello --app dependabot"
has "dry run: BOT_APP_ID variable" "DRY-RUN: gh variable set BOT_APP_ID --repo acme/hello --body 123"
has "dry run: runs the adapter bootstrap" "DRY-RUN: gh variable set APP_NAME --repo acme/hello --body hello"
has "dry run: adapter uses the repo for WIF" "assertion.repository==\\'acme/hello\\'"
if [[ -s "$tmp/calls" ]]; then
  fail "no real gh or Keychain call (called: $(tr '\n' ';' <"$tmp/calls"))"
else
  pass "no real gh or Keychain call"
fi

# --- --skip-bot-key: everything else still happens; the key is left for later
k="$tmp/k"
copy "$k"
rc=0
out="$(BOT_APP_ID=123 "$k/scripts/bootstrap.sh" --stack node --target none --repo acme/hello --dry-run --skip-bot-key 2>&1)" || rc=$?
check "skip-bot-key: exits 0" '[[ $rc == 0 ]]'
# set_secret's dry-run line is the only way the key would be set.
check "skip-bot-key: never sets the bot key" '! grep -q "DRY-RUN: <BOT_APP_PRIVATE_KEY" <<<"$out" && grep -q "BOT_APP_PRIVATE_KEY: skipped" <<<"$out"'
check "skip-bot-key: prints the Mac commands for later" 'grep -q "security find-generic-password -s github-app-private-key -w | base64 -d | gh secret set BOT_APP_PRIVATE_KEY --repo acme/hello --app dependabot" <<<"$out"'
check "skip-bot-key: still sets the Claude token and BOT_APP_ID" 'grep -q "gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo acme/hello" <<<"$out" && grep -q "gh variable set BOT_APP_ID --repo acme/hello --body 123" <<<"$out"'
check "skip-bot-key: still creates production with a reviewer" 'grep -q "environments/production" <<<"$out"'

# --- fail closed: if the rulesets can't be read, bootstrap must not push
d="$tmp/d"
copy "$d"
(cd "$d" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
: >"$tmp/calls"
rc=0
out="$(cd "$d" && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  "$d/scripts/bootstrap.sh" --stack node --target none --repo acme/hello 2>&1)" || rc=$?
check "unreadable rulesets: stops with an error" '[[ $rc == 1 ]] && grep -q "not pushing" <<<"$out"'
# The copy has no remote, so any git push would print "fatal: ... origin".
check "unreadable rulesets: never pushes" '! grep -q "fatal:" <<<"$out" && [[ "$(cat "$tmp/calls")" == "gh api repos/acme/hello/rulesets?includes_parents=true" ]]'
check "unreadable rulesets: the commit stays local" '[[ "$(cd "$d" && git log --oneline | wc -l)" -eq 2 ]]'
# A rerun must retry the push, not stop at "nothing to commit".
rc=0
out="$(cd "$d" && "$d/scripts/bootstrap.sh" --stack node --target none --repo acme/hello 2>&1)" || rc=$?
check "rerun after a failed push: tries to push again" '[[ $rc == 1 ]] && grep -q "not pushing" <<<"$out"'
check "rerun after a failed push: no second commit" '[[ "$(cd "$d" && git log --oneline | wc -l)" -eq 2 ]]'

# A dirty tree is refused before anything changes.
e="$tmp/e"
copy "$e"
(cd "$e" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init && echo stray >stray.txt)
rc=0
out="$(cd "$e" && "$e/scripts/bootstrap.sh" --stack node --target none --repo acme/hello 2>&1)" || rc=$?
check "dirty tree: refused with 64" '[[ $rc == 64 ]] && grep -q "uncommitted changes" <<<"$out"'
check "dirty tree: nothing changed" '[[ -d "$e/deploy/targets/cloud-run" && ! -f "$e/README.md" ]]'

# A repo name that starts with a digit gets a letter prefix for Cloud Run.
f="$tmp/f"
copy "$f"
rc=0
out="$(BOT_APP_ID=1 GCP_PROJECT_ID=hello-proj-1 BILLING_ACCOUNT=0A1B2C-3D4E5F-6A7B8C \
  "$f/scripts/bootstrap.sh" --stack node --target cloud-run --repo acme/9lives --dry-run 2>&1)" || rc=$?
check "digit-leading repo: APP_NAME gets app- prefix" 'grep -q "gh variable set APP_NAME --repo acme/9lives --body app-9lives" <<<"$out"'
: >"$tmp/calls"

# --- real mode against a new repo: pushes to main, and never stores an empty
# secret when the Keychain and the terminal are both unavailable.
g="$tmp/g"
copy "$g"
git init -q --bare "$tmp/origin.git"
(cd "$g" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init &&
  git remote add origin "$tmp/origin.git" && git push -q origin main)
mkdir -p "$tmp/bin3"
cat >"$tmp/bin3/gh" <<EOF3
#!/usr/bin/env bash
echo "gh \$*" >>"$tmp/calls3"
case "\$1 \$2" in
  "api repos/acme/hello/rulesets?includes_parents=true") echo '[]' ;;
  "api repos/acme/hello/branches/main") echo '{"protected":false}' ;;
  "api users/acme") echo '{"type":"User","id":1}' ;;
  "secret set"*) cat >/dev/null ;;
esac
exit 0
EOF3
chmod +x "$tmp/bin3/gh"
: >"$tmp/calls3"
rc=0
out="$(cd "$g" && PATH="$tmp/bin3:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  "$g/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "real mode: new repo is pushed to main" '[[ "$(git -C "$tmp/origin.git" log --oneline main | wc -l)" -eq 2 ]]'
check "real mode: no Keychain and no terminal stops bootstrap" '[[ $rc == 1 ]] && grep -q "CLAUDE_CODE_OAUTH_TOKEN" <<<"$out"'
check "real mode: an empty secret is never set" '! grep -q "gh secret set" "$tmp/calls3"'

# --- prompts are visible on a terminal (a pty from util-linux `script`)
if command -v script >/dev/null 2>&1; then
  sed -n '/^ask() {$/,/^}$/p' "$src/scripts/bootstrap.sh" >"$tmp/ask.sh"
  printf 'source %q\nask v "Bot App ID: " && echo "got=[$v]"\n' "$tmp/ask.sh" >"$tmp/ask_run.sh"
  pty_out="$(printf '12345\n' | PATH="$ORIG_PATH" script -qec "bash $tmp/ask_run.sh" /dev/null 2>&1 | tr -d '\r')"
  check "prompt: shown on the terminal" 'grep -q "Bot App ID: " <<<"$pty_out"'
  check "prompt: reads the answer" 'grep -q "got=\[12345\]" <<<"$pty_out"'
  # No "fails without a terminal" case here: run from a real terminal it would
  # prompt that terminal. The real-mode run above covers the no-terminal path.
else
  echo "ok - prompt tests skipped: no util-linux script"
fi

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
