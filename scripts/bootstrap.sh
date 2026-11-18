#!/usr/bin/env bash
# Turn a fresh copy of the template into a configured project (spec §4.1,
# §4.9, FR-1). Idempotent: a rerun only fills in what is missing. No AI.
#
# Usage: scripts/bootstrap.sh --stack <stack> --target <target>
#                             [--repo owner/name] [--dry-run] [--local-only]
#                             [--skip-bot-key]
#   --dry-run       print the file changes and every remote call; change nothing
#   --local-only    change the files only: no git, GitHub or cloud calls
#   --skip-bot-key  don't set the bot App key secrets (for a machine with no
#                   key source: no Mac Keychain, and a Codespace without the
#                   BOT_APP_KEY_B64 secret); add them later with the commands
#                   bootstrap prints. Only Dependabot auto-merge needs them.
#
# Run it from the new project's clone, logged in with `gh` as the owner.
#
# 1. Files: keep stacks/<stack> and deploy/targets/<target>, delete the other
#    stacks and adapters, the template's intent/ folders, self-test workflow
#    and bootstrap test; write deploy.yml, CODEOWNERS and a README stub.
# 2. Git: commit.
# 3. GitHub: the dev and production Environments (production: the owner as
#    required reviewer, branch main only), secrets and variables.
# 4. Target: the adapter's bootstrap (scripts/deploy.sh bootstrap).
# 5. Git: push to main only while the repo has no ruleset and no branch
#    protection (a brand-new repo, run by its owner: the one exception to
#    "never push to main"), otherwise push a branch and open a PR. The push
#    starts the first deploy, so it waits until 3 and 4 are done.
# 6. GitHub: scripts/gh-settings.sh (repo settings and the ruleset).
#
# Secrets are read from the macOS Keychain or a hidden prompt and piped to
# `gh secret set`; they are never written to disk or printed.
#   CLAUDE_CODE_OAUTH_TOKEN  Keychain service "claude-code-oauth-token"
#   BOT_APP_PRIVATE_KEY      in a Codespace, the Codespaces secret BOT_APP_KEY_B64;
#                            else Keychain service "github-app-private-key"
#                            (both base64; spec 0002 phase 1)
#   BOT_APP_ID               env BOT_APP_ID, else a prompt
# Target settings come from the environment, e.g. for cloud-run:
#   GCP_PROJECT_ID, BILLING_ACCOUNT, GCP_REGION (default us-central1),
#   APP_NAME (default: the repo name).
set -euo pipefail

stack=""
target=""
repo=""
dry_run=0
local_only=0
skip_bot_key=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack) stack="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --local-only) local_only=1; shift ;;
    --skip-bot-key) skip_bot_key=1; shift ;;
    -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "bootstrap: unknown argument: $1" >&2; exit 64 ;;
  esac
done

root="${BOOTSTRAP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root"

die() { echo "bootstrap: $*" >&2; exit 1; }
usage_error() { echo "bootstrap: $*" >&2; exit 64; }
step() { printf '==> %s\n' "$*"; }
run() {
  if ((dry_run)); then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# names <dir>: the subdirectory names of <dir>, space-separated.
names() {
  local d out=""
  for d in "$1"/*/; do [[ -d "$d" ]] && out+="$(basename "$d") "; done
  printf '%s' "$out"
}

# --- validate
[[ "$stack" =~ ^[a-z0-9-]+$ ]] || usage_error "--stack is required (one of: $(names stacks))"
[[ "$target" =~ ^[a-z0-9-]+$ ]] || usage_error "--target is required (one of: $(names deploy/targets))"
[[ -d "stacks/$stack" ]] || usage_error "unknown stack: $stack"
[[ -d "deploy/targets/$target" ]] || usage_error "unknown target: $target"

current_stack="$(sed -n 's/^stack:[[:space:]]*\([a-z0-9-]*\).*/\1/p' deploy.yml 2>/dev/null | head -n 1)"
current_target="$(sed -n 's/^target:[[:space:]]*\([a-z0-9-]*\).*/\1/p' deploy.yml 2>/dev/null | head -n 1)"
if [[ -n "$current_stack" && "$current_stack" != "$stack" ]]; then
  usage_error "already bootstrapped with stack $current_stack; changing the stack is not supported"
fi
if [[ -n "$current_stack" && "$current_target" != "$target" ]]; then
  usage_error "already bootstrapped with target $current_target; to switch, edit target: in deploy.yml and run make bootstrap-target"
fi

if ((local_only)); then
  owner="${BOOTSTRAP_OWNER:-owner}"
else
  if [[ -z "$repo" ]]; then
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die "run inside the new repo's clone, or pass --repo owner/name"
  fi
  owner="${repo%%/*}"
fi
[[ -z "$repo" || "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage_error "invalid --repo: $repo"
[[ "$owner" =~ ^[A-Za-z0-9-]+$ ]] || usage_error "invalid owner: $owner"
name="${repo#*/}"
name="${name:-$(basename "$root")}"

# Bootstrap commits with `git add -A`, so it must start from a clean tree:
# then its commit holds only its own changes, never a stray local file.
if ! ((local_only)) && ! ((dry_run)) && [[ -n "$(git status --porcelain)" ]]; then
  usage_error "the working tree has uncommitted changes; commit or stash them first. If an earlier bootstrap stopped half-way, reset its edits with: git checkout -- . && git clean -fd"
fi

# fs <cmd...>: a file change, printed in dry run.
fs() { run "$@"; }

# --- 1. files
step "Files: stack $stack, target $target"
if [[ -n "$current_stack" ]]; then
  echo "    already bootstrapped; files unchanged"
else
  for d in stacks/*/; do
    d="${d%/}"
    [[ "$d" == "stacks/$stack" ]] || fs rm -rf "$d"
  done
  # Every real adapter stays, so `make bootstrap-target` can switch to it
  # later (criterion 11); test-only adapters (test_only: true) go unless chosen.
  for d in deploy/targets/*/; do
    d="${d%/}"
    if [[ "$d" != "deploy/targets/$target" ]] && grep -qx 'test_only: true' "$d/target.yml" 2>/dev/null; then
      fs rm -rf "$d"
    fi
  done
  # The template's own intent folders and self-test belong to the template.
  for d in intent/*/; do
    [[ -d "$d" ]] && fs rm -rf "${d%/}"
  done
  fs mkdir -p intent
  fs touch intent/.gitkeep
  fs rm -f .github/workflows/template-selftest.yml
  # Tests the template-to-project step itself, which only the template has.
  fs rm -f tests/scripts/test_bootstrap.sh
  # One bot token broker serves every project (spec 0002). It stays in the
  # template, so new projects don't carry its code or tests.
  for d in broker tests/broker; do
    if [[ -d "$d" ]]; then fs rm -r "$d"; fi
  done

  template_repo="${TEMPLATE_REPO:-Jomaries777/template-repo-ci}"
  [[ "$template_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage_error "invalid TEMPLATE_REPO: $template_repo"
  deploy_yml="target: $target
stack: $stack
environments:
  dev:        { enabled: true }
  production: { approval: required }
smoke:
  live_checks: 3
  interval_seconds: 60
"
  codeowners="# Every path is owned by the repo owner (spec §4.6).
* @$owner
"
  readme="# $name

Made from [$template_repo](https://github.com/$template_repo).
Stack: \`$stack\` (\`stacks/$stack/\`). Deploy target: \`$target\` (\`deploy.yml\`).

## Work

Every change starts as \`intent/<id>-<slug>/intent.md\` (run \`/intent\` in Claude
Code), then \`spec.md\` and \`plan.md\`, then a PR. Only \`ci-ok\` is required to
merge; the owner approves.

## Commands

| Command | What it does |
|---|---|
| \`make lint\` / \`make fmt\` | Repo and stack linters / formatters |
| \`make test\` | Script tests and the stack's unit tests |
| \`make typecheck\` / \`make build\` | Type-check / build the deploy artifact |
| \`make acceptance\` | Acceptance suite against a local container |
| \`make smoke URL=<url>\` | \`prod-safe\` smoke tests against a URL |
| \`make doctor\` | Check repo settings, secrets and the deploy target |
"
  # Dependabot covers the stack's ecosystems too (FR-7): every stack ships
  # the entries to add to the `updates:` list.
  dependabot_fragment="stacks/$stack/dependabot-updates.yml"
  [[ -f "$dependabot_fragment" ]] || die "$dependabot_fragment is missing; every stack ships its Dependabot updates"
  # CodeQL scans the stack's language too (pr.yml's codeql matrix starts with
  # the workflows only): add the stack's entry after the actions one.
  case "$stack" in
    node) codeql_language=javascript-typescript codeql_build=none ;;
    python) codeql_language=python codeql_build=none ;;
    go) codeql_language=go codeql_build=autobuild ;;
    *) codeql_language="" codeql_build="" ;;
  esac
  if ((dry_run)); then
    if [[ -n "$codeql_language" ]]; then
      echo "DRY-RUN: add codeql language $codeql_language (build-mode $codeql_build) to .github/workflows/pr.yml"
    fi
    echo "DRY-RUN: write deploy.yml (target: $target, stack: $stack)"
    echo "DRY-RUN: write .github/CODEOWNERS (* @$owner)"
    echo "DRY-RUN: write README.md (project stub)"
    echo "DRY-RUN: append $dependabot_fragment to .github/dependabot.yml"
  else
    printf '%s' "$deploy_yml" >deploy.yml
    printf '%s' "$codeowners" >.github/CODEOWNERS
    printf '%s' "$readme" >README.md
    cat "$dependabot_fragment" >>.github/dependabot.yml
    rm -f "$dependabot_fragment"
    if [[ -n "$codeql_language" ]] && ! grep -qE "^[[:space:]]+- language: $codeql_language\$" .github/workflows/pr.yml; then
      # Insert after the "- language: actions" item and its build-mode line,
      # with the same indentation; fail if pr.yml no longer has that item.
      awk -v lang="$codeql_language" -v mode="$codeql_build" '
        { print }
        # Only the line right after the actions item may be its build-mode.
        pending == 2 { pending = 0 }
        pending == 1 && /^[[:space:]]+build-mode:/ {
          print indent "- language: " lang; print indent "  build-mode: " mode; pending = 0; done = 1
        }
        pending == 1 { pending = 2 }
        /^[[:space:]]+- language: actions$/ { indent = $0; sub(/-.*/, "", indent); pending = 1; next }
        END { if (!done) exit 1 }
      ' .github/workflows/pr.yml >.github/workflows/pr.yml.new ||
        die "pr.yml has no codeql '- language: actions' entry to add $codeql_language after"
      mv .github/workflows/pr.yml.new .github/workflows/pr.yml
    fi
  fi
fi

if ((local_only)); then
  step "Local only: files changed; commit them and rerun without --local-only"
  exit 0
fi

# --- 2. git: commit now; push in step 5, once the first deploy has all it needs
step "Git: commit"
if ((dry_run)) || [[ -n "$(git status --porcelain)" ]]; then
  run git add -A
  run git commit -q -m "chore: bootstrap $stack on $target"
else
  echo "    nothing to commit"
fi
# --- 3. GitHub
step "GitHub: Environments dev and production"
# The production reviewer must be a user. An organization owner names one
# with BOOTSTRAP_REVIEWER.
reviewer="${BOOTSTRAP_REVIEWER:-$owner}"
[[ "$reviewer" =~ ^[A-Za-z0-9-]+$ ]] || usage_error "invalid BOOTSTRAP_REVIEWER: $reviewer"
owner_id=0
if ! ((dry_run)); then
  account="$(gh api "users/$reviewer")" || die "cannot read GitHub account $reviewer"
  [[ "$(jq -r .type <<<"$account")" == User ]] ||
    die "$reviewer is an organization; set BOOTSTRAP_REVIEWER to the user who approves production"
  owner_id="$(jq -r .id <<<"$account")"
fi
run gh api -X PUT "repos/$repo/environments/dev" --silent
# PUT sets the whole Environment config: a rerun resets anything changed by
# hand (e.g. a wait timer) to these rules.
run gh api -X PUT "repos/$repo/environments/production" --silent --input - <<JSON
{"reviewers":[{"type":"User","id":$owner_id}],
 "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
has_main_policy=""
((dry_run)) || has_main_policy="$(gh api "repos/$repo/environments/production/deployment-branch-policies" \
  --jq '.branch_policies[] | select(.name=="main") | .id' 2>/dev/null || true)"
if [[ -z "$has_main_policy" ]]; then
  run gh api -X POST "repos/$repo/environments/production/deployment-branch-policies" --silent \
    -f name=main -f type=branch
fi

step "GitHub: secrets and variables"
names_actions=""
names_dependabot=""
if ! ((dry_run)); then
  names_actions="$(gh secret list --repo "$repo" --json name -q '.[].name' || true)"
  names_dependabot="$(gh secret list --repo "$repo" --app dependabot --json name -q '.[].name' || true)"
fi
# ask <var> <prompt> [-s]: read a line from the terminal into <var>. The
# prompt goes straight to /dev/tty (read -p would print it on stderr, which
# the failure redirect hides). Fails if there is no terminal.
ask() {
  local __var="$1" __prompt="$2" __silent="${3:-}" __v=""
  { printf '%s' "$__prompt" >/dev/tty; } 2>/dev/null || return 1
  if [[ "$__silent" == -s ]]; then
    IFS= read -r -s __v </dev/tty || return 1
    printf '\n' >/dev/tty
  else
    IFS= read -r __v </dev/tty || return 1
  fi
  printf -v "$__var" '%s' "$__v"
}
# keychain <service>: print a Keychain item, or nothing.
keychain() {
  command -v security >/dev/null 2>&1 || return 0
  security find-generic-password -s "$1" -w 2>/dev/null || true
}
# set_secret <name> <app> <producer...>: pipe the producer's output to gh.
set_secret() {
  local secret="$1" app="$2" list
  shift 2
  list="$names_actions"
  [[ "$app" == dependabot ]] && list="$names_dependabot"
  if grep -qx "$secret" <<<"$list"; then
    echo "    $secret ($app): already set"
    return 0
  fi
  if ((dry_run)); then
    echo "DRY-RUN: <$secret from Keychain or prompt> | gh secret set $secret --repo $repo --app $app"
    return 0
  fi
  # Capture first: a producer that dies inside a pipeline would only end its
  # subshell, and gh would store an empty secret. The value stays in memory
  # and reaches gh on stdin, never on disk or in an argument.
  local value
  value="$("$@")" || die "could not read $secret"
  [[ -n "$value" ]] || die "$secret is empty; not setting it"
  printf '%s' "$value" | gh secret set "$secret" --repo "$repo" --app "$app"
}
claude_token() {
  local v
  v="$(keychain claude-code-oauth-token)"
  if [[ -z "$v" ]]; then
    ask v "CLAUDE_CODE_OAUTH_TOKEN (from claude setup-token): " -s ||
      die "no terminal to prompt for CLAUDE_CODE_OAUTH_TOKEN; store it in the Keychain (service claude-code-oauth-token)"
  fi
  printf '%s' "${v//[[:space:]]/}"
}
# bot_key: the decoded App key. BOT_APP_KEY_B64 counts only in a Codespace,
# so the key isn't encouraged into ordinary env files (same rule as
# bot-token.sh). The value is checked but never printed.
bot_key() {
  local v pem
  if [[ "${CODESPACES:-}" == "true" && -n "${BOT_APP_KEY_B64:-}" ]]; then
    v="$BOT_APP_KEY_B64"
  else
    v="$(keychain github-app-private-key)"
  fi
  [[ -n "$v" ]] || die "bot App key not found. In a Codespace: add the Codespaces secret BOT_APP_KEY_B64 (github.com/settings/codespaces) and restart it. On a Mac: store it in the Keychain (service github-app-private-key). Or rerun with --skip-bot-key"
  pem="$(base64 -d <<<"$v" 2>/dev/null)" || die "the bot App key isn't valid base64"
  [[ "$pem" == -----BEGIN* ]] || die "the bot App key isn't a PEM private key"
  printf '%s' "$pem"
}
set_secret CLAUDE_CODE_OAUTH_TOKEN actions claude_token
# broker_signed_in: this device signed in with scripts/bot-login.sh (spec 0002
# phase 2). Then the broker sets the bot key secrets and the key never comes
# here; a broker refusal stops bootstrap rather than fall back to a phase-1 key.
broker_signed_in() {
  local cfg="${BOT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-bot}"
  [[ -s "$cfg/identity" ]] && [[ -n "${BOT_BROKER_URL:-}" || -s "$cfg/broker_url" ]]
}
if ((skip_bot_key)); then
  echo "    BOT_APP_PRIVATE_KEY: skipped (--skip-bot-key); add it later from a device signed in to the broker with:"
  echo "      scripts/bot-secrets.sh $repo"
  echo "    or from a Mac with:"
  for app in actions dependabot; do
    echo "      security find-generic-password -s github-app-private-key -w | base64 -d | gh secret set BOT_APP_PRIVATE_KEY --repo $repo --app $app"
  done
  echo "    or from a Codespace with the BOT_APP_KEY_B64 secret:"
  for app in actions dependabot; do
    # shellcheck disable=SC2016 # printed for the user to run, not expanded here
    echo '      printf %s "$BOT_APP_KEY_B64" | base64 -d | gh secret set BOT_APP_PRIVATE_KEY'" --repo $repo --app $app"
  done
elif broker_signed_in; then
  missing=()
  grep -qx BOT_APP_PRIVATE_KEY <<<"$names_actions" && echo "    BOT_APP_PRIVATE_KEY (actions): already set" || missing+=(actions)
  grep -qx BOT_APP_PRIVATE_KEY <<<"$names_dependabot" && echo "    BOT_APP_PRIVATE_KEY (dependabot): already set" || missing+=(dependabot)
  if ((${#missing[@]})); then
    apps="$(IFS=,; echo "${missing[*]}")"
    if ((dry_run)); then
      echo "DRY-RUN: scripts/bot-secrets.sh --apps $apps $repo (the broker seals and sets BOT_APP_PRIVATE_KEY)"
    else
      "$(dirname "${BASH_SOURCE[0]}")/bot-secrets.sh" --apps "$apps" "$repo" || die "the broker didn't set BOT_APP_PRIVATE_KEY (see above)"
    fi
  fi
else
  set_secret BOT_APP_PRIVATE_KEY actions bot_key
  set_secret BOT_APP_PRIVATE_KEY dependabot bot_key
fi
app_id="${BOT_APP_ID:-}"
if [[ -z "$app_id" ]] && ! ((dry_run)); then
  app_id="$(gh variable get BOT_APP_ID --repo "$repo" 2>/dev/null || true)"
  if [[ -z "$app_id" ]]; then
    ask app_id "Bot App ID (github.com/settings/apps): " ||
      die "no terminal to prompt for the bot App ID; set BOT_APP_ID"
  fi
fi
if ((dry_run)); then
  [[ -z "$app_id" || "$app_id" =~ ^[0-9]+$ ]] || usage_error "BOT_APP_ID must be a number"
else
  [[ "$app_id" =~ ^[0-9]+$ ]] || usage_error "BOT_APP_ID must be a number, got: ${app_id:-<empty>}"
fi
run gh variable set BOT_APP_ID --repo "$repo" --body "${app_id:-<id>}"

# --- 4. target: the same script that switches targets later (criterion 11).
step "Target: $target"
target_args=(--target "$target" --stack "$stack" --repo "$repo")
((dry_run)) && target_args+=(--dry-run)
"$root/scripts/bootstrap-target.sh" "${target_args[@]}"

# --- 5. push. Pushing main starts the first deploy, so this comes after the
# Environments (production's reviewer), secrets and the target's resources and
# variables; a step that fails above leaves the commit local for a rerun.
step "Git: push"
# Push whenever the commit isn't on origin/main yet, so a rerun retries a
# push that failed or was interrupted after the commit.
need_push=1
if ! ((dry_run)) && git fetch -q origin main 2>/dev/null && git merge-base --is-ancestor HEAD origin/main; then
  need_push=0
fi
if ((need_push)); then
  # Fail closed: if the rulesets can't be read, never push to main.
  # "Protected" means any ruleset at all, or classic protection on main; only
  # a repo with neither (a new one) takes the direct push.
  protected=""
  if ! ((dry_run)); then
    # includes_parents: rulesets inherited from an organization count too.
    rulesets="$(gh api "repos/$repo/rulesets?includes_parents=true")" || die "cannot read the rulesets of $repo; not pushing"
    branch="$(gh api "repos/$repo/branches/main")" || die "cannot read the main branch of $repo; not pushing"
    if [[ "$(jq 'length' <<<"$rulesets")" != 0 || "$(jq -r '.protected' <<<"$branch")" == true ]]; then
      protected=1
    fi
  fi
  if [[ -z "$protected" ]]; then
    # A new repo: main is not protected yet; gh-settings.sh protects it next.
    run git push origin HEAD:main
  else
    run git push -u origin HEAD:refs/heads/chore/bootstrap
    open_prs=""
    ((dry_run)) || open_prs="$(gh pr list --repo "$repo" --head chore/bootstrap --json number -q length)"
    if [[ "${open_prs:-0}" == 0 ]]; then
      run gh pr create --repo "$repo" --head chore/bootstrap --base main \
        --title "chore: bootstrap $stack on $target" --body "Files written by scripts/bootstrap.sh."
    else
      echo "    PR from chore/bootstrap already open"
    fi
  fi
else
  echo "    already pushed"
fi

# --- 6. GitHub: protect main. After the push: the ruleset blocks direct
# pushes to main.
step "GitHub: repo settings and ruleset"
settings_args=(--repo "$repo")
((dry_run)) && settings_args+=(--dry-run)
# gh-settings.sh prints its own DRY-RUN lines, so it is called directly.
"$root/scripts/gh-settings.sh" "${settings_args[@]}"

step "Done. Next: install the bot App on $repo, then run make doctor."
