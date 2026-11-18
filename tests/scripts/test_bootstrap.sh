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

# Every stack ships the Dependabot updates that bootstrap appends (FR-7).
missing=""
for d in "$src"/stacks/*/; do
  [[ -f "$d/dependabot-updates.yml" ]] || missing+=" $(basename "$d")"
done
check "every stack ships dependabot-updates.yml" '[[ -z "$missing" ]] || { echo "missing:$missing"; false; }'

# --- local-only: node on cloud-run
a="$tmp/a"
copy "$a"
rc=0
out="$(BOOTSTRAP_OWNER=acme "$a/scripts/bootstrap.sh" --stack node --target cloud-run --local-only 2>&1)" || rc=$?
check "local-only: exits 0" '[[ $rc == 0 ]] || { echo "$out"; false; }'
check "keeps only the chosen stack" '[[ "$(ls "$a/stacks")" == node ]]'
# Every real adapter stays, so `make bootstrap-target` can switch to it later
# (criterion 11); only test-only adapters (target.yml test_only: true) go.
real_adapters=""
for d in "$src"/deploy/targets/*/; do
  grep -qx 'test_only: true' "$d/target.yml" 2>/dev/null || real_adapters+="$(basename "$d") "
done
check "keeps every real adapter for later switches" '[[ "$(ls "$a/deploy/targets" | tr "\n" " ")" == "$real_adapters" && "$real_adapters" == *"cloud-run "* ]]'
check "removes test-only adapters" '[[ ! -e "$a/deploy/targets/local" ]]'
check "deploy.yml names target and stack" 'grep -qx "target: cloud-run" "$a/deploy.yml" && grep -qx "stack: node" "$a/deploy.yml"'
check "deploy.yml keeps environments and smoke" 'grep -q "dev:        { enabled: true }" "$a/deploy.yml" && grep -q "live_checks: 3" "$a/deploy.yml"'
check "removes the template self-test" '[[ ! -e "$a/.github/workflows/template-selftest.yml" ]]'
check "keeps the other workflows" '[[ -f "$a/.github/workflows/pr.yml" ]]'
check "removes the broker (one serves every project)" '[[ ! -e "$a/broker" && ! -e "$a/tests/broker" ]]'
check "removes the template-only bootstrap test" '[[ ! -e "$a/tests/scripts/test_bootstrap.sh" && -f "$a/tests/scripts/test_deploy.sh" ]]'
check "removes the template intent folders" '[[ -z "$(find "$a/intent" -mindepth 1 -type d)" && -f "$a/intent/.gitkeep" ]]'
check "CODEOWNERS names the new owner" 'grep -qx "\* @acme" "$a/.github/CODEOWNERS" && ! grep -q Jomaries777 "$a/.github/CODEOWNERS"'
check "README stub names the stack and target" 'grep -q "Stack: \`node\`" "$a/README.md" && grep -q "Deploy target: \`cloud-run\`" "$a/README.md"'
check "root make delegates to the stack" 'make -C "$a" -n typecheck 2>/dev/null | grep -q "stacks/node"'
check "deploy.sh reads the new target" '[[ "$(APP_NAME=hello DEPLOY_DRY_RUN=1 "$a/scripts/deploy.sh" url dev 2>/dev/null)" == https://hello-dev-dryrun.a.run.app ]]'
# Dependabot covers the stack's ecosystems too (FR-7): bootstrap appends the
# stack's fragment to .github/dependabot.yml.
dbot="$a/.github/dependabot.yml"
check "dependabot: keeps github-actions" 'grep -q "package-ecosystem: github-actions" "$dbot"'
check "dependabot: adds the stack's npm packages" 'grep -q "package-ecosystem: npm" "$dbot" && grep -q "directory: /stacks/node" "$dbot"'
check "dependabot: adds the stack's Docker image" 'grep -q "package-ecosystem: docker" "$dbot"'
check "dependabot: npm patch updates are their own group" 'grep -A2 "npm-patch:" "$dbot" | grep -q "update-types:" && grep -A3 "npm-patch:" "$dbot" | grep -q -- "- patch"'
check "dependabot: the stack fragment is removed" '[[ ! -e "$a/stacks/node/dependabot-updates.yml" ]]'
if python3 -c 'import yaml' 2>/dev/null; then
  check "dependabot: valid YAML with three update entries" '[[ "$(python3 -c "import sys,yaml; print(len(yaml.safe_load(open(sys.argv[1]))[\"updates\"]))" "$dbot")" == 3 ]]'
else
  check "dependabot: three update entries" '[[ "$(grep -c "package-ecosystem:" "$dbot")" == 3 ]]'
fi

# CodeQL scans the stack's language too, not only the workflows (M3 step 7):
# bootstrap adds the stack's entry to pr.yml's codeql matrix.
prw="$a/.github/workflows/pr.yml"
check "codeql: adds the node stack's language" 'grep -A1 -E "^[[:space:]]+- language: javascript-typescript$" "$prw" | grep -qE "^[[:space:]]+build-mode: none$"'
check "codeql: keeps the actions entry" 'grep -qE "^[[:space:]]+- language: actions$" "$prw"'
if command -v actionlint >/dev/null 2>&1; then
  check "codeql: pr.yml is still a valid workflow" 'actionlint "$prw"'
fi

# If the actions item has no build-mode line right after it, bootstrap must
# stop rather than insert the stack's entry somewhere else.
cqb="$tmp/cqb"
copy "$cqb"
sed -i '/^[[:space:]]*- language: actions$/{n;d}' "$cqb/.github/workflows/pr.yml"
rc=0
out="$(BOOTSTRAP_OWNER=acme "$cqb/scripts/bootstrap.sh" --stack node --target none --local-only 2>&1)" || rc=$?
check "codeql: an actions item without build-mode stops bootstrap" '[[ $rc != 0 ]] && grep -q "codeql" <<<"$out"'

# --- local-only: go (M3). Same shape as node: only its stack stays, and its
# gomod and Docker updates are appended.
gop="$tmp/gop"
copy "$gop"
rc=0
out="$(BOOTSTRAP_OWNER=acme "$gop/scripts/bootstrap.sh" --stack go --target cloud-run --local-only 2>&1)" || rc=$?
check "go local-only: exits 0" '[[ $rc == 0 ]] || { echo "$out"; false; }'
check "go: keeps only the go stack" '[[ "$(ls "$gop/stacks")" == go ]]'
check "go: deploy.yml names the stack" 'grep -qx "stack: go" "$gop/deploy.yml"'
check "go: README stub names the stack" 'grep -q "Stack: \`go\`" "$gop/README.md"'
check "go: dependabot adds gomod for the stack" 'grep -q "package-ecosystem: gomod" "$gop/.github/dependabot.yml" && grep -q "directory: /stacks/go" "$gop/.github/dependabot.yml"'
check "go: dependabot adds the stack's Docker image" 'grep -q "package-ecosystem: docker" "$gop/.github/dependabot.yml"'
check "go: the stack fragment is removed" '[[ ! -e "$gop/stacks/go/dependabot-updates.yml" ]]'
check "go: the root Makefile delegates to stacks/go" '[[ "$(make -s -C "$gop" -p -n help 2>/dev/null | sed -n "s/^STACK_DIR := //p" | head -n 1)" == stacks/go ]]'
check "go: ships the make targets the pipeline calls" '( for t in lint typecheck test build build-static acceptance smoke; do grep -q "^$t:" "$gop/stacks/go/Makefile" || { echo "missing $t"; exit 1; }; done )'
check "go: codeql scans go" 'grep -A1 -E "^[[:space:]]+- language: go$" "$gop/.github/workflows/pr.yml" | grep -qE "^[[:space:]]+build-mode: autobuild$"'

# --- local-only: python (M3). Same shape as node: only its stack stays, and
# its pip and Docker updates are appended.
py="$tmp/py"
copy "$py"
rc=0
out="$(BOOTSTRAP_OWNER=acme "$py/scripts/bootstrap.sh" --stack python --target cloud-run --local-only 2>&1)" || rc=$?
check "python local-only: exits 0" '[[ $rc == 0 ]] || { echo "$out"; false; }'
check "python: keeps only the python stack" '[[ "$(ls "$py/stacks")" == python ]]'
check "python: deploy.yml names the stack" 'grep -qx "stack: python" "$py/deploy.yml"'
check "python: README stub names the stack" 'grep -q "Stack: \`python\`" "$py/README.md"'
check "python: dependabot adds pip for the stack" 'grep -q "package-ecosystem: pip" "$py/.github/dependabot.yml" && grep -q "directory: /stacks/python" "$py/.github/dependabot.yml"'
check "python: dependabot adds the stack's Docker image" 'grep -q "package-ecosystem: docker" "$py/.github/dependabot.yml"'
check "python: the stack fragment is removed" '[[ ! -e "$py/stacks/python/dependabot-updates.yml" ]]'
check "python: the root Makefile delegates to stacks/python" '[[ "$(make -s -C "$py" -p -n help 2>/dev/null | sed -n "s/^STACK_DIR := //p" | head -n 1)" == stacks/python ]]'
check "python: ships the make targets the pipeline calls" '( for t in lint typecheck test build build-static acceptance smoke; do grep -q "^$t:" "$py/stacks/python/Makefile" || { echo "missing $t"; exit 1; }; done )'
check "python: codeql scans python" 'grep -A1 -E "^[[:space:]]+- language: python$" "$py/.github/workflows/pr.yml" | grep -qE "^[[:space:]]+build-mode: none$"'

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
out="$("$a/scripts/bootstrap.sh" --stack node --target none --local-only 2>&1 || true)"
check "rerun with another target points to make bootstrap-target" 'grep -q "make bootstrap-target" <<<"$out"'

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
has "dry run: deletes the test-only adapter" "DRY-RUN: rm -rf deploy/targets/local"
if grep -qF "DRY-RUN: rm -rf deploy/targets/none" <<<"$out"; then fail "dry run: keeps the real adapters"; else pass "dry run: keeps the real adapters"; fi
has "dry run: pushes to main before the ruleset exists" "DRY-RUN: git push origin HEAD:main"
has "dry run: applies repo settings" "DRY-RUN: gh repo edit acme/hello"
has "dry run: creates dev" "DRY-RUN: gh api -X PUT repos/acme/hello/environments/dev"
has "dry run: production with a required reviewer" "DRY-RUN: gh api -X PUT repos/acme/hello/environments/production"
has "dry run: production limited to main" "deployment-branch-policies --silent -f name=main -f type=branch"
has "dry run: Claude token secret" "gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo acme/hello --app actions"
has "dry run: bot key mirrored to Dependabot" "gh secret set BOT_APP_PRIVATE_KEY --repo acme/hello --app dependabot"
has "dry run: BOT_APP_ID variable" "DRY-RUN: gh variable set BOT_APP_ID --repo acme/hello --body 123"
has "dry run: adds the stack's CodeQL language" "DRY-RUN: add codeql language javascript-typescript (build-mode none) to .github/workflows/pr.yml"
has "dry run: appends the stack's Dependabot updates" "DRY-RUN: append stacks/node/dependabot-updates.yml to .github/dependabot.yml"
has "dry run: runs the adapter bootstrap" "DRY-RUN: gh variable set APP_NAME --repo acme/hello --body hello"
has "dry run: adapter uses the repo for WIF" "assertion.repository==\\'acme/hello\\'"
# The push to main starts the first deploy, so everything that deploy needs
# (Environments, secrets, the target's resources and variables) comes first;
# the ruleset comes after, since it blocks direct pushes to main.
line_of() { grep -nF -- "$1" <<<"$out" | head -1 | cut -d: -f1; }
o_env="$(line_of "environments/production")"
o_secret="$(line_of "gh secret set CLAUDE_CODE_OAUTH_TOKEN")"
o_target="$(line_of "gh variable set APP_NAME")"
o_push="$(line_of "DRY-RUN: git push origin HEAD:main")"
o_rules="$(line_of "DRY-RUN: gh repo edit acme/hello")"
check "dry run: Environments, secrets and target come before the push" \
  '[[ -n "$o_push" && "$o_env" -lt "$o_push" && "$o_secret" -lt "$o_push" && "$o_target" -lt "$o_push" ]]'
check "dry run: repo settings and ruleset come after the push" '[[ -n "$o_rules" && "$o_push" -lt "$o_rules" ]]'
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
check "skip-bot-key: prints the Codespace commands too" 'grep -qF "printf %s \"\$BOT_APP_KEY_B64\" | base64 -d | gh secret set BOT_APP_PRIVATE_KEY --repo acme/hello --app actions" <<<"$out"'
check "skip-bot-key: still sets the Claude token and BOT_APP_ID" 'grep -q "gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo acme/hello" <<<"$out" && grep -q "gh variable set BOT_APP_ID --repo acme/hello --body 123" <<<"$out"'
check "skip-bot-key: still creates production with a reviewer" 'grep -q "environments/production" <<<"$out"'

# --- fail closed: if the rulesets can't be read, bootstrap must not push
d="$tmp/d"
copy "$d"
(cd "$d" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
# Setup before the push succeeds; only reading the rulesets fails.
mkdir -p "$tmp/bind"
cat >"$tmp/bind/gh" <<EOFD
#!/usr/bin/env bash
echo "gh \$*" >>"$tmp/callsd"
case "\$*" in
  *rulesets*) exit 1 ;;
  "api users/acme") echo '{"type":"User","id":1}' ;;
  "secret set"*) cat >/dev/null ;;
esac
exit 0
EOFD
printf '#!/usr/bin/env bash\necho sk-test-claude\n' >"$tmp/bind/security"
chmod +x "$tmp/bind/gh" "$tmp/bind/security"
dpath="$tmp/bind:$PATH"
: >"$tmp/callsd"
rc=0
out="$(cd "$d" && PATH="$dpath" BOT_APP_ID=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  "$d/scripts/bootstrap.sh" --stack node --target none --repo acme/hello --skip-bot-key </dev/null 2>&1)" || rc=$?
check "unreadable rulesets: stops with an error" '[[ $rc == 1 ]] && grep -q "not pushing" <<<"$out" || { echo "$out" | tail -3; false; }'
# The copy has no remote, so any git push would print "fatal: ... origin".
check "unreadable rulesets: never pushes" '! grep -q "fatal:" <<<"$out" && [[ "$(tail -n 1 "$tmp/callsd")" == "gh api repos/acme/hello/rulesets?includes_parents=true" ]]'
check "unreadable rulesets: no ruleset applied" '! grep -q "gh repo edit" "$tmp/callsd"'
check "unreadable rulesets: the commit stays local" '[[ "$(cd "$d" && git log --oneline | wc -l)" -eq 2 ]]'
# A rerun must retry the push, not stop at "nothing to commit".
rc=0
out="$(cd "$d" && PATH="$dpath" BOT_APP_ID=1 "$d/scripts/bootstrap.sh" --stack node --target none --repo acme/hello --skip-bot-key </dev/null 2>&1)" || rc=$?
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

# --- real mode against a new repo: a failed setup step pushes nothing, and never stores an empty
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
check "real mode: no Keychain and no terminal stops bootstrap" '[[ $rc == 1 ]] && grep -q "CLAUDE_CODE_OAUTH_TOKEN" <<<"$out"'
check "real mode: a failed setup step pushes nothing (no early deploy)" '[[ "$(git -C "$tmp/origin.git" log --oneline main | wc -l)" -eq 1 ]]'
check "real mode: an empty secret is never set" '! grep -q "gh secret set" "$tmp/calls3"'

# --- real mode in a Codespace (spec 0002 phase 1): the bot key comes from the
# BOT_APP_KEY_B64 Codespaces secret, never from the Keychain, and reaches gh
# on stdin for both Actions and Dependabot.
h="$tmp/h"
copy "$h"
git init -q --bare "$tmp/origin4.git"
(cd "$h" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init &&
  git remote add origin "$tmp/origin4.git" && git push -q origin main)
mkdir -p "$tmp/bin4" "$tmp/sec4"
cat >"$tmp/bin4/gh" <<EOF4
#!/usr/bin/env bash
echo "gh \$*" >>"$tmp/calls4"
case "\$1 \$2" in
  "api repos/acme/hello/rulesets?includes_parents=true") echo '[]' ;;
  "api repos/acme/hello/branches/main") echo '{"protected":false}' ;;
  "api users/acme") echo '{"type":"User","id":1}' ;;
  "secret set") cat >"$tmp/sec4/\$3_\${7:-actions}" ;;
esac
exit 0
EOF4
# The Keychain holds only the Claude token; asking it for the bot key is logged.
cat >"$tmp/bin4/security" <<EOF4
#!/usr/bin/env bash
echo "security \$*" >>"$tmp/calls4"
case "\$*" in
  *claude-code-oauth-token*) echo "sk-test-claude" ;;
  *) exit 44 ;;
esac
EOF4
chmod +x "$tmp/bin4/gh" "$tmp/bin4/security"
pem="-----BEGIN TEST KEY-----
abc
-----END TEST KEY-----"
: >"$tmp/calls4"
rc=0
out="$(cd "$h" && PATH="$tmp/bin4:$PATH" CODESPACES=true BOT_APP_KEY_B64="$(printf '%s' "$pem" | base64 | tr -d '\n')" BOT_APP_ID=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  "$h/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "codespace: bot key set for Actions from BOT_APP_KEY_B64" '[[ "$(cat "$tmp/sec4/BOT_APP_PRIVATE_KEY_actions" 2>/dev/null)" == "$pem" ]]'
check "codespace: bot key set for Dependabot from BOT_APP_KEY_B64" '[[ "$(cat "$tmp/sec4/BOT_APP_PRIVATE_KEY_dependabot" 2>/dev/null)" == "$pem" ]]'
check "codespace: Keychain never asked for the bot key" '! grep -q "github-app-private-key" "$tmp/calls4"'
check "codespace: the key is never printed" '! grep -q "TEST KEY" <<<"$out"'
check "real mode: a complete run pushes to main" '[[ $rc == 0 && "$(git -C "$tmp/origin4.git" log --oneline main | wc -l)" -eq 2 ]] || { echo "$out" | tail -3; false; }'
check "real mode: the ruleset is applied after the push" '[[ "$(grep -n "gh repo edit" "$tmp/calls4" | head -1 | cut -d: -f1)" -gt "$(grep -n "rulesets?includes_parents" "$tmp/calls4" | head -1 | cut -d: -f1)" ]]'

# A Codespaces secret that isn't a PEM key stops bootstrap before gh sees it.
h2="$tmp/h2"
copy "$h2"
git init -q --bare "$tmp/origin5.git"
(cd "$h2" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init &&
  git remote add origin "$tmp/origin5.git" && git push -q origin main)
rm -f "$tmp/sec4"/*
: >"$tmp/calls4"
rc=0
out="$(cd "$h2" && PATH="$tmp/bin4:$PATH" CODESPACES=true BOT_APP_KEY_B64="$(printf 'junk-value' | base64)" BOT_APP_ID=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  "$h2/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "codespace: a non-PEM secret stops bootstrap" '[[ $rc != 0 ]] && grep -q "PEM" <<<"$out"'
check "codespace: a non-PEM secret is never stored" '[[ ! -e "$tmp/sec4/BOT_APP_PRIVATE_KEY_actions" ]] && ! grep -q "junk-value" <<<"$out"'

# --- signed in to the broker (spec 0002 phase 2): the broker sets the bot key;
# the key never comes to this device, and a refusal stops bootstrap instead of
# falling back to a phase 1 key.
mkdir -p "$tmp/botcfg"
printf 'x' >"$tmp/botcfg/identity"
printf 'https://broker.test\n' >"$tmp/botcfg/broker_url"
b="$tmp/b"
copy "$b"
rc=0
out="$(BOT_APP_ID=123 BOT_CONFIG_DIR="$tmp/botcfg" "$b/scripts/bootstrap.sh" --stack node --target none --repo acme/hello --dry-run 2>&1)" || rc=$?
check "broker: dry run exits 0" '[[ $rc == 0 ]]'
check "broker: dry run uses bot-secrets.sh for both apps" 'grep -qF "DRY-RUN: scripts/bot-secrets.sh --apps actions,dependabot acme/hello" <<<"$out"'
check "broker: no local key source is asked" '! grep -q "DRY-RUN: <BOT_APP_PRIVATE_KEY" <<<"$out"'
h3="$tmp/h3"
copy "$h3"
printf '#!/usr/bin/env bash\necho "bot-secrets $*" >>%q\necho "bot-secrets: the broker refused acme/hello: github_denied (HTTP 403)" >&2\nexit 1\n' "$tmp/calls4" >"$h3/scripts/bot-secrets.sh"
git init -q --bare "$tmp/origin6.git"
(cd "$h3" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init &&
  git remote add origin "$tmp/origin6.git" && git push -q origin main)
rm -f "$tmp/sec4"/*
: >"$tmp/calls4"
rc=0
out="$(cd "$h3" && PATH="$tmp/bin4:$PATH" CODESPACES=true BOT_APP_KEY_B64="$(printf '%s' "$pem" | base64 | tr -d '\n')" BOT_APP_ID=1 BOT_CONFIG_DIR="$tmp/botcfg" \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  "$h3/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "broker: bot-secrets.sh called for both apps" 'grep -q "bot-secrets --apps actions,dependabot acme/hello" "$tmp/calls4"'
check "broker: a refusal stops bootstrap" '[[ $rc != 0 ]] && grep -q "github_denied" <<<"$out"'
check "broker: no fallback to the phase 1 key" '[[ ! -e "$tmp/sec4/BOT_APP_PRIVATE_KEY_actions" ]]'

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
