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
# No broker sign-in: an empty BOT_CONFIG_DIR, so a signed-in machine's real
# ~/.config/agent-bot never sends bootstrap down the broker path (the broker
# cases set their own), and no BOT_BROKER_URL (cloud sessions export one).
mkdir -p "$tmp/no-botcfg"
unset BOT_BROKER_URL CLAUDE_APP_ID CI_APP_ID CODESPACES BOT_APP_KEY_B64
export BOT_CONFIG_DIR="$tmp/no-botcfg"
# No terminal: bootstrap prompts $BOOTSTRAP_TTY, so point it at nothing. A run
# under an agent's pty or make test in Terminal then never prompts, and never
# waits on, whoever runs it. The pty prompt tests below set /dev/tty back.
export BOOTSTRAP_TTY="$tmp/no-tty"

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
check "removes the template's playbook deviations (its own history)" '[[ -f "$src/docs/playbook-deviations.md" && ! -e "$a/docs/playbook-deviations.md" ]]'
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
check "dependabot: no wrangler entry for another target" '! grep -q "directory: /deploy/targets/cloudflare-workers" "$dbot"'

# --- local-only: node on cloudflare-workers adds the adapter's wrangler entry
cw="$tmp/cw"
copy "$cw"
rc=0
out="$(BOOTSTRAP_OWNER=acme "$cw/scripts/bootstrap.sh" --stack node --target cloudflare-workers --local-only 2>&1)" || rc=$?
check "cloudflare-workers: local-only exits 0" '[[ $rc == 0 ]] || { echo "$out"; false; }'
check "cloudflare-workers: dependabot watches the adapter's wrangler" 'grep -q "directory: /deploy/targets/cloudflare-workers" "$cw/.github/dependabot.yml"'
check "cloudflare-workers: four update entries" '[[ "$(grep -c "package-ecosystem:" "$cw/.github/dependabot.yml")" == 4 ]]'
check "cloudflare-workers: the adapter fragment stays for later switches" '[[ -f "$cw/deploy/targets/cloudflare-workers/dependabot-updates.yml" ]]'

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
# Portable for GNU and BSD sed: no bare -i, and ';' before '}'.
sed '/^[[:space:]]*- language: actions$/{n;d;}' "$cqb/.github/workflows/pr.yml" >"$cqb/pr.yml.new"
mv "$cqb/pr.yml.new" "$cqb/.github/workflows/pr.yml"
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
  "--stack node --target heroku --local-only" "--stack ../x --target none --local-only" "--bogus" \
  "--stack python --target cloudflare-workers --local-only" "--stack go --target cloudflare-workers --local-only"; do
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
out="$(CLAUDE_APP_ID=111 CI_APP_ID=222 GCP_PROJECT_ID=hello-proj-1 BILLING_ACCOUNT=0A1B2C-3D4E5F-6A7B8C \
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
has "dry run: records when the Claude token was set" "gh variable set CLAUDE_CODE_OAUTH_TOKEN_SET_AT --repo acme/hello --body $(date -u +%Y-%m-%d)"
has "dry run: sets Claude App key via bot-secrets.sh --key claude" "DRY-RUN: scripts/bot-secrets.sh --key claude acme/hello"
has "dry run: sets CI App key via bot-secrets.sh --key ci" "DRY-RUN: scripts/bot-secrets.sh --key ci acme/hello"
has "dry run: CLAUDE_APP_ID variable" "DRY-RUN: gh variable set CLAUDE_APP_ID --repo acme/hello --body 111"
has "dry run: CLAUDE_APP_SLUG variable" "DRY-RUN: gh variable set CLAUDE_APP_SLUG --repo acme/hello --body acme-claude"
has "dry run: CI_APP_ID variable" "DRY-RUN: gh variable set CI_APP_ID --repo acme/hello --body 222"
check "dry run: never sets BOT_APP_ID or BOT_APP_PRIVATE_KEY" '! grep -qE "BOT_APP_ID|BOT_APP_PRIVATE_KEY" <<<"$out"'
has "dry run: main-review ruleset gets CI_APP_ID" "Ruleset 'main-review' from .github/rulesets/main-review.json (CI_APP_ID=222)"
has "dry run: prints manual installation step for all three Apps" "add acme/hello to the installations of acme-claude, acme-agy and acme-ci at https://github.com/settings/installations"
has "dry run: adds the stack's CodeQL language" "DRY-RUN: add codeql language javascript-typescript (build-mode none) to .github/workflows/pr.yml"
has "dry run: appends the stack's Dependabot updates" "DRY-RUN: append stacks/node/dependabot-updates.yml to .github/dependabot.yml"
has "dry run: runs the adapter bootstrap" "DRY-RUN: gh variable set APP_NAME --repo acme/hello --body hello"
has "dry run: adapter uses the repo for WIF" "assertion.repository==\\'acme/hello\\'"
# The push to main starts the first deploy, so everything that deploy needs
# (Environments, secrets, the target's resources and variables) comes first;
# the rulesets come after, since they block direct pushes to main.
line_of() { grep -nF -- "$1" <<<"$out" | head -1 | cut -d: -f1; }
o_env="$(line_of "environments/production")"
o_secret="$(line_of "gh secret set CLAUDE_CODE_OAUTH_TOKEN")"
o_ci_var="$(line_of "gh variable set CI_APP_ID")"
o_target="$(line_of "gh variable set APP_NAME")"
o_push="$(line_of "DRY-RUN: git push origin HEAD:main")"
o_rules="$(line_of "DRY-RUN: gh repo edit acme/hello")"
check "dry run: Environments, secrets, variables and target come before the push" \
  '[[ -n "$o_push" && "$o_env" -lt "$o_push" && "$o_secret" -lt "$o_push" && "$o_ci_var" -lt "$o_push" && "$o_target" -lt "$o_push" ]]'
check "dry run: repo settings and rulesets come after the push" '[[ -n "$o_rules" && "$o_push" -lt "$o_rules" ]]'
if [[ -s "$tmp/calls" ]]; then
  fail "no real gh or Keychain call (called: $(tr '\n' ';' <"$tmp/calls"))"
else
  pass "no real gh or Keychain call"
fi
# README quick-start gaps (M3 step 6, finding 6): one target header, and no
# "commit deploy.yml's target in a PR" hint, which only fits a later switch.
check "dry run: prints the Target header once" '[[ "$(grep -c "^==> Target:" <<<"$out")" == 1 ]]'
check "dry run: no switch-target hint on a first bootstrap" '! grep -q "Commit deploy.yml" <<<"$out"'

# C9 long login (>27 chars): bootstrap uses app-manifest.sh --name so App names
# share the truncated prefix and fit GitHub's 34-character limit.
out_long="$(CLAUDE_APP_ID=111 CI_APP_ID=222 \
  "$c/scripts/bootstrap.sh" --stack node --target none --repo abcdefghijklmnopqrstuvwxyz1234/hello --dry-run 2>&1)"
check "dry run: C9 truncation applied to CLAUDE_APP_SLUG" 'grep -qF "gh variable set CLAUDE_APP_SLUG --repo abcdefghijklmnopqrstuvwxyz1234/hello --body abcdefghijklmnopqrstuvwxyz1-claude" <<<"$out_long"'
check "dry run: C9 truncation applied to manual installation step" 'grep -qF "installations of abcdefghijklmnopqrstuvwxyz1-claude, abcdefghijklmnopqrstuvwxyz1-agy and abcdefghijklmnopqrstuvwxyz1-ci at https://github.com/settings/installations" <<<"$out_long"'

# Mixed-case owner is lowercased by app-manifest.sh --name, and --dry-run works
# even without CLAUDE_APP_ID / CI_APP_ID set in env.
rc=0
out_unset="$(env -u CLAUDE_APP_ID -u CI_APP_ID \
  "$c/scripts/bootstrap.sh" --stack node --target none --repo Jomaries777/hello --dry-run 2>&1)" || rc=$?
check "dry run without App IDs: exits 0" '[[ $rc == 0 ]]'
check "dry run without App IDs: prints <id> placeholders and <CI_APP_ID> for main-review" \
  'grep -qF "gh variable set CLAUDE_APP_ID --repo Jomaries777/hello --body \<id\>" <<<"$out_unset" && grep -qF "gh variable set CI_APP_ID --repo Jomaries777/hello --body \<id\>" <<<"$out_unset" && grep -qF "(CI_APP_ID=<CI_APP_ID>)" <<<"$out_unset"'
check "dry run mixed-case owner: App slugs are lowercased" \
  'grep -qF "gh variable set CLAUDE_APP_SLUG --repo Jomaries777/hello --body jomaries777-claude" <<<"$out_unset" && grep -qF "installations of jomaries777-claude, jomaries777-agy and jomaries777-ci at https://github.com/settings/installations" <<<"$out_unset"'
check "bootstrap --help includes secrets and variables list" '"$c/scripts/bootstrap.sh" --help | grep -q "CLAUDE_APP_SLUG"'
rc=0
"$c/scripts/bootstrap.sh" --repo >/dev/null 2>&1 || rc=$?
check "bootstrap missing --repo value exits 64" '[[ $rc == 64 ]]'

# --- refuses to run against the template repo itself, before any change
g="$tmp/g"
copy "$g"
list_before="$(cd "$g" && find . | sort)"
for args in "--repo Jomaries777/template-repo-ci --dry-run" "--repo jomaries777/Template-Repo-CI"; do
  : >"$tmp/calls"
  rc=0
  # shellcheck disable=SC2086 # split the arguments on purpose
  out="$(CLAUDE_APP_ID=111 CI_APP_ID=222 "$g/scripts/bootstrap.sh" --stack node --target none $args 2>&1)" || rc=$?
  check "template guard: '$args' is refused with 64" '[[ $rc == 64 ]] && grep -q "is the template itself" <<<"$out"'
  check "template guard: '$args' calls no gh" '[[ ! -s "$tmp/calls" ]]'
done
list_after="$(cd "$g" && find . | sort)"
check "template guard: changes no file" '[[ "$list_before" == "$list_after" ]]'
# --local-only has no repo: the guard reads origin instead (review of #65).
# The other local-only runs here are in copies with no .git, so they pass.
for url in https://github.com/Jomaries777/template-repo-ci.git git@github.com:jomaries777/Template-Repo-CI; do
  t="$tmp/t"
  rm -rf "$t"
  copy "$t"
  git -C "$t" init -q && git -C "$t" remote add origin "$url"
  list_before="$(cd "$t" && find . -path ./.git -prune -o -print | sort)"
  rc=0
  out="$(BOOTSTRAP_OWNER=acme "$t/scripts/bootstrap.sh" --stack node --target none --local-only 2>&1)" || rc=$?
  list_after="$(cd "$t" && find . -path ./.git -prune -o -print | sort)"
  check "template guard, local-only, origin $url: refused with 64, no file changed" '[[ $rc == 64 && "$list_before" == "$list_after" ]] && grep -q "is the template itself" <<<"$out"'
done

# --- --skip-bot-key: everything else still happens; both App keys left for later
k="$tmp/k"
copy "$k"
rc=0
out="$(CLAUDE_APP_ID=111 CI_APP_ID=222 "$k/scripts/bootstrap.sh" --stack node --target none --repo acme/hello --dry-run --skip-bot-key 2>&1)" || rc=$?
check "skip-bot-key: exits 0" '[[ $rc == 0 ]]'
check "skip-bot-key: never calls bot-secrets.sh" '! grep -q "DRY-RUN: scripts/bot-secrets.sh" <<<"$out" && grep -q "CLAUDE_APP_PRIVATE_KEY, CI_APP_PRIVATE_KEY: skipped" <<<"$out"'
check "skip-bot-key: prints both bot-secrets.sh commands for later" \
  'grep -qF "scripts/bot-secrets.sh --key claude acme/hello" <<<"$out" && grep -qF "scripts/bot-secrets.sh --key ci acme/hello" <<<"$out"'
check "skip-bot-key: no local key commands printed" '! grep -qE "github-app-private-key|BOT_APP_KEY_B64" <<<"$out"'
check "skip-bot-key: still sets the Claude token and App variables" \
  'grep -q "gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo acme/hello" <<<"$out" && grep -q "gh variable set CLAUDE_APP_ID --repo acme/hello --body 111" <<<"$out" && grep -q "gh variable set CI_APP_ID --repo acme/hello --body 222" <<<"$out"'
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
out="$(cd "$d" && PATH="$dpath" CLAUDE_APP_ID=111 CI_APP_ID=222 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  "$d/scripts/bootstrap.sh" --stack node --target none --repo acme/hello --skip-bot-key </dev/null 2>&1)" || rc=$?
check "unreadable rulesets: stops with an error" '[[ $rc == 1 ]] && grep -q "not pushing" <<<"$out" || { echo "$out" | tail -3; false; }'
# The copy has no remote, so any git push would print "fatal: ... origin".
check "unreadable rulesets: never pushes" '! grep -q "fatal:" <<<"$out" && [[ "$(tail -n 1 "$tmp/callsd")" == "gh api repos/acme/hello/rulesets?includes_parents=true" ]]'
check "unreadable rulesets: no ruleset applied" '! grep -q "gh repo edit" "$tmp/callsd"'
check "unreadable rulesets: the commit stays local" '[[ "$(cd "$d" && git log --oneline | wc -l)" -eq 2 ]]'
# A rerun must retry the push, not stop at "nothing to commit".
rc=0
out="$(cd "$d" && PATH="$dpath" CLAUDE_APP_ID=111 CI_APP_ID=222 "$d/scripts/bootstrap.sh" --stack node --target none --repo acme/hello --skip-bot-key </dev/null 2>&1)" || rc=$?
check "rerun after a failed push: tries to push again" '[[ $rc == 1 ]] && grep -q "not pushing" <<<"$out"'
check "rerun after a failed push: no second commit" '[[ "$(cd "$d" && git log --oneline | wc -l)" -eq 2 ]]'

# A dirty tree is refused before anything changes.
e="$tmp/e"
copy "$e"
(cd "$e" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init && echo stray >stray.txt)
rc=0
out="$(cd "$e" && "$e/scripts/bootstrap.sh" --stack node --target none --repo acme/hello 2>&1)" || rc=$?
check "dirty tree: refused with 64" '[[ $rc == 64 ]] && grep -q "uncommitted changes" <<<"$out"'
# The template ships its own README, so check git: only the stray file differs.
check "dirty tree: nothing changed" '[[ "$(cd "$e" && git status --porcelain)" == "?? stray.txt" && -d "$e/deploy/targets/cloud-run" ]]'

# A repo name that starts with a digit gets a letter prefix for Cloud Run.
f="$tmp/f"
copy "$f"
rc=0
out="$(CLAUDE_APP_ID=111 CI_APP_ID=222 GCP_PROJECT_ID=hello-proj-1 BILLING_ACCOUNT=0A1B2C-3D4E5F-6A7B8C \
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

# --- real mode complete run via the broker (spec 0003 FR-9, D6, C6):
# bot-secrets.sh sets both keys, variables are set before gh-settings.sh,
# main-review gets CI_APP_ID, and no PUT /user/installations API is called.
h="$tmp/h"
copy "$h"
printf '#!/usr/bin/env bash\necho "bot-secrets $*" >>%q\nexit 0\n' "$tmp/calls4" >"$h/scripts/bot-secrets.sh"
chmod +x "$h/scripts/bot-secrets.sh"
git init -q --bare "$tmp/origin4.git"
(cd "$h" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init &&
  git remote add origin "$tmp/origin4.git" && git push -q origin main)
mkdir -p "$tmp/bin4" "$tmp/sec4"
cat >"$tmp/bin4/gh" <<EOF4
#!/usr/bin/env bash
echo "gh \$*" >>"$tmp/calls4"
case "\$*" in
  "secret list --repo acme/hello --json name -q .[].name")
    printf '%s\n' \${FAKE_ACTIONS_SECRETS:-}
    ;;
  "secret list --repo acme/hello --app dependabot --json name -q .[].name")
    printf '%s\n' \${FAKE_DEPENDABOT_SECRETS:-}
    ;;
  "variable get CLAUDE_APP_ID --repo acme/hello")
    [[ -n "\${FAKE_VAR_CLAUDE_APP_ID:-}" ]] && echo "\$FAKE_VAR_CLAUDE_APP_ID" && exit 0
    exit 1
    ;;
  "variable get CI_APP_ID --repo acme/hello")
    [[ -n "\${FAKE_VAR_CI_APP_ID:-}" ]] && echo "\$FAKE_VAR_CI_APP_ID" && exit 0
    exit 1
    ;;
  "api repos/acme/hello/rulesets?includes_parents=true") echo '[]' ;;
  "api repos/acme/hello/rulesets") echo '[]' ;;
  "api repos/acme/hello/branches/main") echo '{"protected":false}' ;;
  "api users/acme") echo '{"type":"User","id":1}' ;;
  "secret set"*) cat >"$tmp/sec4/\$3_\${7:-actions}" ;;
  *"repos/acme/hello/rulesets"*"--input -"*) cat >"$tmp/review4.json" ;;
  *"--input -"*) cat >/dev/null ;;
esac
exit 0
EOF4
# The Keychain holds only the Claude OAuth token; asking for anything else is logged.
cat >"$tmp/bin4/security" <<EOF4
#!/usr/bin/env bash
echo "security \$*" >>"$tmp/calls4"
case "\$*" in
  *claude-code-oauth-token*) echo "sk-test-claude" ;;
  *) exit 44 ;;
esac
EOF4
chmod +x "$tmp/bin4/gh" "$tmp/bin4/security"
: >"$tmp/calls4"
rm -f "$tmp/review4.json"
rc=0
out="$(cd "$h" && PATH="$tmp/bin4:$PATH" CLAUDE_APP_ID=111 CI_APP_ID=222 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  "$h/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "real mode: a complete run exits 0 and pushes to main" '[[ $rc == 0 && "$(git -C "$tmp/origin4.git" log --oneline main | wc -l)" -eq 2 ]] || { echo "$out" | tail -5; false; }'
check "real mode: calls bot-secrets.sh --key claude and --key ci" \
  'grep -qx "bot-secrets --key claude acme/hello" "$tmp/calls4" && grep -qx "bot-secrets --key ci acme/hello" "$tmp/calls4"'
check "real mode: Keychain never asked for github-app-private-key" '! grep -q "github-app-private-key" "$tmp/calls4"'
check "real mode: sets CLAUDE_APP_ID, CLAUDE_APP_SLUG and CI_APP_ID" \
  'grep -qx "gh variable set CLAUDE_APP_ID --repo acme/hello --body 111" "$tmp/calls4" && grep -qx "gh variable set CLAUDE_APP_SLUG --repo acme/hello --body acme-claude" "$tmp/calls4" && grep -qx "gh variable set CI_APP_ID --repo acme/hello --body 222" "$tmp/calls4"'
check "real mode: never sets BOT_APP_ID" '! grep -q "BOT_APP_ID" "$tmp/calls4"'
check "real mode: never calls PUT /user/installations (S2)" '! grep -q "user/installations" "$tmp/calls4"'
check "real mode: the rulesets are applied after the push" '[[ "$(grep -n "gh repo edit" "$tmp/calls4" | head -1 | cut -d: -f1)" -gt "$(grep -n "rulesets?includes_parents" "$tmp/calls4" | head -1 | cut -d: -f1)" ]]'
check "real mode: main-review ruleset gets CI_APP_ID as a number" 'jq -e "[.bypass_actors[] | select(.actor_type == \"Integration\" and .actor_id == 222)] | length == 1" "$tmp/review4.json" >/dev/null'
check "real mode: prints manual installation step" 'grep -qF "add acme/hello to the installations of acme-claude, acme-agy and acme-ci at https://github.com/settings/installations" <<<"$out"'

# Skipping a secret that is already set: if CLAUDE_APP_PRIVATE_KEY is already
# set in Actions, only --key ci is called; if both are set, neither is called.
: >"$tmp/calls4"
rc=0
out="$(cd "$h" && PATH="$tmp/bin4:$PATH" FAKE_ACTIONS_SECRETS="CLAUDE_CODE_OAUTH_TOKEN CLAUDE_APP_PRIVATE_KEY" \
  CLAUDE_APP_ID=111 CI_APP_ID=222 \
  "$h/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "already set: skips --key claude and still calls --key ci" \
  '[[ $rc == 0 ]] && ! grep -q "bot-secrets --key claude" "$tmp/calls4" && grep -qx "bot-secrets --key ci acme/hello" "$tmp/calls4"'

: >"$tmp/calls4"
rc=0
out="$(cd "$h" && PATH="$tmp/bin4:$PATH" FAKE_ACTIONS_SECRETS="CLAUDE_CODE_OAUTH_TOKEN CLAUDE_APP_PRIVATE_KEY" \
  FAKE_DEPENDABOT_SECRETS="CI_APP_PRIVATE_KEY" CLAUDE_APP_ID=111 CI_APP_ID=222 \
  "$h/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "already set: skips both keys when both are already set" \
  '[[ $rc == 0 ]] && ! grep -q "bot-secrets" "$tmp/calls4"'

# Reading existing CLAUDE_APP_ID and CI_APP_ID from repo variables when env is unset.
: >"$tmp/calls4"
rm -f "$tmp/review4.json"
rc=0
out="$(cd "$h" && env -u CLAUDE_APP_ID -u CI_APP_ID PATH="$tmp/bin4:$PATH" \
  FAKE_ACTIONS_SECRETS="CLAUDE_CODE_OAUTH_TOKEN CLAUDE_APP_PRIVATE_KEY" \
  FAKE_DEPENDABOT_SECRETS="CI_APP_PRIVATE_KEY" \
  FAKE_VAR_CLAUDE_APP_ID=333 FAKE_VAR_CI_APP_ID=444 \
  "$h/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "existing repo variables: reads CLAUDE_APP_ID and CI_APP_ID without env" \
  '[[ $rc == 0 ]] && grep -qx "gh variable get CLAUDE_APP_ID --repo acme/hello" "$tmp/calls4" && grep -qx "gh variable get CI_APP_ID --repo acme/hello" "$tmp/calls4"'
check "existing repo variables: passes CI_APP_ID to main-review ruleset" \
  'jq -e "[.bypass_actors[] | select(.actor_type == \"Integration\" and .actor_id == 444)] | length == 1" "$tmp/review4.json" >/dev/null'

# Missing or non-numeric CLAUDE_APP_ID / CI_APP_ID fails cleanly.
rc=0
out="$(cd "$h" && env -u CLAUDE_APP_ID -u CI_APP_ID PATH="$tmp/bin4:$PATH" FAKE_ACTIONS_SECRETS="CLAUDE_CODE_OAUTH_TOKEN CLAUDE_APP_PRIVATE_KEY" \
  FAKE_DEPENDABOT_SECRETS="CI_APP_PRIVATE_KEY" CLAUDE_APP_ID=111 \
  "$h/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "missing CI_APP_ID without tty: stops with clear error" '[[ $rc == 1 ]] && grep -q "CI_APP_ID" <<<"$out"'
rc=0
out="$(cd "$h" && env -u CLAUDE_APP_ID -u CI_APP_ID PATH="$tmp/bin4:$PATH" FAKE_ACTIONS_SECRETS="CLAUDE_CODE_OAUTH_TOKEN CLAUDE_APP_PRIVATE_KEY" \
  FAKE_DEPENDABOT_SECRETS="CI_APP_PRIVATE_KEY" CI_APP_ID=222 \
  "$h/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "missing CLAUDE_APP_ID without tty: stops with clear error" '[[ $rc == 1 ]] && grep -q "CLAUDE_APP_ID" <<<"$out"'
rc=0
out="$(CLAUDE_APP_ID=abc CI_APP_ID=222 "$c/scripts/bootstrap.sh" --stack node --target none --repo acme/hello --dry-run 2>&1)" || rc=$?
check "non-numeric CLAUDE_APP_ID: rejected with 64" '[[ $rc == 64 ]] && grep -q "CLAUDE_APP_ID must be a number" <<<"$out"'
rc=0
out="$(CLAUDE_APP_ID=111 CI_APP_ID=0 "$c/scripts/bootstrap.sh" --stack node --target none --repo acme/hello --dry-run 2>&1)" || rc=$?
check "zero CI_APP_ID: rejected with 64" '[[ $rc == 64 ]] && grep -q "CI_APP_ID must be a number" <<<"$out"'

# Broker refusal stops bootstrap, with no fallback to local keys even when
# CODESPACES and BOT_APP_KEY_B64 are set (D6).
h3="$tmp/h3"
copy "$h3"
printf '#!/usr/bin/env bash\necho "bot-secrets $*" >>%q\necho "bot-secrets: the broker refused acme/hello: github_denied (HTTP 403)" >&2\nexit 1\n' "$tmp/calls4" >"$h3/scripts/bot-secrets.sh"
chmod +x "$h3/scripts/bot-secrets.sh"
git init -q --bare "$tmp/origin6.git"
(cd "$h3" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init &&
  git remote add origin "$tmp/origin6.git" && git push -q origin main)
rm -f "$tmp/sec4"/*
: >"$tmp/calls4"
pem="-----BEGIN TEST KEY-----
abc
-----END TEST KEY-----"
rc=0
out="$(cd "$h3" && PATH="$tmp/bin4:$PATH" CODESPACES=true BOT_APP_KEY_B64="$(printf '%s' "$pem" | base64 | tr -d '\n')" CLAUDE_APP_ID=111 CI_APP_ID=222 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  "$h3/scripts/bootstrap.sh" --stack node --target none --repo acme/hello </dev/null 2>&1)" || rc=$?
check "broker: bot-secrets.sh --key claude called" 'grep -qx "bot-secrets --key claude acme/hello" "$tmp/calls4"'
check "broker: a refusal stops bootstrap" '[[ $rc != 0 ]] && grep -q "github_denied" <<<"$out"'
check "broker: no fallback to local keys" '! grep -q "github-app-private-key" "$tmp/calls4" && [[ ! -e "$tmp/sec4/CLAUDE_APP_PRIVATE_KEY_actions" && ! -e "$tmp/sec4/BOT_APP_PRIVATE_KEY_actions" ]]'

# No local App key paths remain in bootstrap.sh (D6).
check "bootstrap.sh has no local App key paths" '! grep -qE "BOT_APP_ID|BOT_APP_PRIVATE_KEY|BOT_APP_KEY_B64|github-app-private-key" "$src/scripts/bootstrap.sh"'

# --- ask() uses only a terminal (review of #99). A BOOTSTRAP_TTY that isn't
# one must fail: `>` would create a missing path as a file, and a prompt that
# ends in a newline would then read its own text back as the answer.
sed -n '/^ask() {$/,/^}$/p' "$src/scripts/bootstrap.sh" >"$tmp/ask_nl.sh"
cat >"$tmp/ask_nl_run.sh" <<'EOF_NL'
source "$1"
if ask v $'Bot App ID:\n'; then echo "got=[$v]"; else echo no-terminal; fi
EOF_NL
nl_out="$(BOOTSTRAP_TTY="$tmp/not-a-tty" bash "$tmp/ask_nl_run.sh" "$tmp/ask_nl.sh" 2>&1)"
check "prompt: a BOOTSTRAP_TTY that isn't a terminal fails, even for a prompt ending in a newline" 'grep -q "no-terminal" <<<"$nl_out" && ! grep -q "got=" <<<"$nl_out"'
check "prompt: a missing BOOTSTRAP_TTY is never created" '[[ ! -e "$tmp/not-a-tty" ]]'

# --- prompts are visible on a terminal (a pty from util-linux `script`)
# Only util-linux's: BSD/macOS script has no -c, and under set -e it would end
# this test silently.
if script --version 2>/dev/null | grep -q util-linux; then
  sed -n '/^ask() {$/,/^}$/p' "$src/scripts/bootstrap.sh" >"$tmp/ask.sh"
  printf 'source %q\nask v "Bot App ID: " && echo "got=[$v]"\n' "$tmp/ask.sh" >"$tmp/ask_run.sh"
  pty_out="$(printf '12345\n' | PATH="$ORIG_PATH" BOOTSTRAP_TTY=/dev/tty script -qec "bash $tmp/ask_run.sh" /dev/null 2>&1 | tr -d '\r')"
  check "prompt: shown on the terminal" 'grep -q "Bot App ID: " <<<"$pty_out"'
  check "prompt: reads the answer" 'grep -q "got=\[12345\]" <<<"$pty_out"'
  # BOOTSTRAP_TTY names the terminal to prompt. Pointed at nothing, ask()
  # must fail even with a real terminal attached, so a test run never waits
  # on whoever runs it (an agent's pty, or make test in Terminal).
  pty_off="$(printf '12345\n' | PATH="$ORIG_PATH" BOOTSTRAP_TTY="$tmp/no-tty" script -qec "bash $tmp/ask_run.sh || echo no-terminal" /dev/null 2>&1 | tr -d '\r')"
  check "prompt: BOOTSTRAP_TTY without a terminal never reads the real one" 'grep -q "no-terminal" <<<"$pty_off" && ! grep -q "got=" <<<"$pty_off"'
  # The real-mode run above covers the no-terminal path for bootstrap itself:
  # with BOOTSTRAP_TTY pointed at nothing for this whole file, it fails the
  # same way with or without a real terminal attached.
else
  echo "ok - prompt tests skipped: no util-linux script"
fi

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
