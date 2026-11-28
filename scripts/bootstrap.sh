#!/usr/bin/env bash
# Turn a fresh copy of the template into a configured project (spec §4.1,
# §4.9, FR-1). Idempotent: a rerun only fills in what is missing. No AI.
#
# Usage: scripts/bootstrap.sh --stack <stack> --target <target>
#                             [--repo owner/name] [--dry-run] [--local-only]
#                             [--skip-bot-key]
#   --dry-run       print the file changes and every remote call; change nothing
#   --local-only    change the files only: no git, GitHub or cloud calls
#   --skip-bot-key  don't set the App key secrets (for a machine not signed in
#                   to the broker); add them later with the commands bootstrap
#                   prints.
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
# 6. GitHub: scripts/gh-settings.sh (repo settings and rulesets).
#
# Secrets are read from the macOS Keychain or a hidden prompt and piped to
# `gh secret set`; they are never written to disk or printed.
#   CLAUDE_CODE_OAUTH_TOKEN  Keychain service "claude-code-oauth-token"
#   CLAUDE_APP_PRIVATE_KEY   set via scripts/bot-secrets.sh --key claude
#   CI_APP_PRIVATE_KEY       set via scripts/bot-secrets.sh --key ci
#   CLAUDE_APP_ID, CI_APP_ID env first, else repo variable, else a prompt
#   CLAUDE_APP_SLUG          computed via scripts/app-manifest.sh --name
# Prompts go to the terminal named by BOOTSTRAP_TTY (default /dev/tty); the
# tests point it at nothing, so a test run never prompts whoever runs it.
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
    --stack)
      [[ $# -ge 2 ]] || { echo "bootstrap: missing argument for $1" >&2; exit 64; }
      stack="$2"; shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || { echo "bootstrap: missing argument for $1" >&2; exit 64; }
      target="$2"; shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "bootstrap: missing argument for $1" >&2; exit 64; }
      repo="$2"; shift 2
      ;;
    --dry-run) dry_run=1; shift ;;
    --local-only) local_only=1; shift ;;
    --skip-bot-key) skip_bot_key=1; shift ;;
    -h | --help) sed -n '2,40p' "$0"; exit 0 ;;
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
# Refuse a stack the target doesn't support (target.yml `stacks:`) before any
# file changes; bootstrap-target.sh checks it again for later switches.
supported="$(scripts/target-stacks.sh "deploy/targets/$target/target.yml")"
if [[ -n "$supported" && " $supported " != *" $stack "* ]]; then
  usage_error "$target doesn't support the $stack stack (supported: $supported)"
fi

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
[[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || usage_error "invalid owner: $owner"
name="${repo#*/}"
name="${name:-$(basename "$root")}"

# Never bootstrap the template itself: its push is stopped by the ruleset, but
# the local checkout would be rewritten first (M3 step 6, finding 6). GitHub
# names are case-insensitive.
template_repo="${TEMPLATE_REPO:-Jomaries777/template-repo-ci}"
[[ "$template_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage_error "invalid TEMPLATE_REPO: $template_repo"
# tr, not ${x,,}: macOS ships bash 3.2.
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
# --local-only has no repo, so check the checkout's origin (any GitHub URL
# form: https://github.com/o/r(.git), git@github.com:o/r(.git)).
guard_repo="$repo"
if [[ -z "$guard_repo" ]]; then
  origin_url="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  if [[ "$origin_url" =~ github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]]; then
    guard_repo="${BASH_REMATCH[1]%.git}"
  fi
fi
if [[ -n "$guard_repo" && "$(lower "$guard_repo")" == "$(lower "$template_repo")" ]]; then
  usage_error "$guard_repo is the template itself: create a new repo from it (README, \"Start a new project\") and run bootstrap in that clone"
fi

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
  # The template's playbook deviations record its own history (sandbox PRs,
  # intent 0001); a project starts its own if it needs one.
  fs rm -f docs/playbook-deviations.md
  if [[ -d docs ]] && [[ -z "$(ls -A docs)" ]]; then fs rmdir docs; fi
  # Tests the template-to-project step itself, which only the template has.
  fs rm -f tests/scripts/test_bootstrap.sh
  # One bot token broker serves every project (spec 0002). It stays in the
  # template, so new projects don't carry its code or tests, including the
  # owner-script tests (spec 0004 FR-6).
  for d in broker tests/broker; do
    if [[ -d "$d" ]]; then fs rm -r "$d"; fi
  done
  for f in tests/scripts/test_broker_*.sh; do
    if [[ -f "$f" ]]; then fs rm -f "$f"; fi
  done

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
  # An adapter with its own dependencies (cloudflare-workers pins wrangler)
  # ships entries too; only the chosen target's are added. Its fragment stays,
  # so a later switch to that target can add them by hand.
  target_fragment="deploy/targets/$target/dependabot-updates.yml"
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
    [[ ! -f "$target_fragment" ]] || echo "DRY-RUN: append $target_fragment to .github/dependabot.yml"
  else
    printf '%s' "$deploy_yml" >deploy.yml
    printf '%s' "$codeowners" >.github/CODEOWNERS
    printf '%s' "$readme" >README.md
    cat "$dependabot_fragment" >>.github/dependabot.yml
    rm -f "$dependabot_fragment"
    [[ ! -f "$target_fragment" ]] || cat "$target_fragment" >>.github/dependabot.yml
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
# prompt goes straight to the terminal, $BOOTSTRAP_TTY or /dev/tty (read -p
# would print it on stderr, which the failure redirect hides). Fails if there
# is no terminal, or if $BOOTSTRAP_TTY isn't a character device: writing to
# a missing path would create it as a file and read the prompt back.
ask() {
  local __var="$1" __prompt="$2" __silent="${3:-}" __v="" __tty="${BOOTSTRAP_TTY:-/dev/tty}"
  [[ -c "$__tty" ]] || return 1
  { printf '%s' "$__prompt" >"$__tty"; } 2>/dev/null || return 1
  if [[ "$__silent" == -s ]]; then
    IFS= read -r -s __v <"$__tty" || return 1
    printf '\n' >"$__tty"
  else
    IFS= read -r __v <"$__tty" || return 1
  fi
  printf -v "$__var" '%s' "$__v"
}
# keychain <service>: print a Keychain item, or nothing.
keychain() {
  command -v security >/dev/null 2>&1 || return 0
  security find-generic-password -s "$1" -w 2>/dev/null || true
}
# set_secret <name> <app> <producer...>: pipe the producer's output to gh.
# Sets secret_written=1 when it writes (or, in dry run, would write) it.
secret_written=0
set_secret() {
  local secret="$1" app="$2" list
  shift 2
  secret_written=0
  list="$names_actions"
  [[ "$app" == dependabot ]] && list="$names_dependabot"
  if grep -qx "$secret" <<<"$list"; then
    echo "    $secret ($app): already set"
    return 0
  fi
  if ((dry_run)); then
    echo "DRY-RUN: <$secret from Keychain or prompt> | gh secret set $secret --repo $repo --app $app"
    secret_written=1
    return 0
  fi
  # Capture first: a producer that dies inside a pipeline would only end its
  # subshell, and gh would store an empty secret. The value stays in memory
  # and reaches gh on stdin, never on disk or in an argument.
  local value
  value="$("$@")" || die "could not read $secret"
  [[ -n "$value" ]] || die "$secret is empty; not setting it"
  printf '%s' "$value" | gh secret set "$secret" --repo "$repo" --app "$app"
  secret_written=1
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
# App keys come only from the broker via scripts/bot-secrets.sh (spec 0003
# FR-9, D6); no local key files, Keychain entries or Codespaces env vars.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_app_slug="$("$script_dir/app-manifest.sh" --name "$owner" claude)"
agy_app_slug="$("$script_dir/app-manifest.sh" --name "$owner" agy)"
ci_app_slug="$("$script_dir/app-manifest.sh" --name "$owner" ci)"

set_secret CLAUDE_CODE_OAUTH_TOKEN actions claude_token
# Record when the token was set, for the renewal check in sdlc-metrics.sh
# (spec §4.12). Only when it was written: a rerun keeps the original date.
if ((secret_written)); then
  run gh variable set CLAUDE_CODE_OAUTH_TOKEN_SET_AT --repo "$repo" --body "$(date -u +%Y-%m-%d)"
fi
if ((skip_bot_key)); then
  echo "    CLAUDE_APP_PRIVATE_KEY, CI_APP_PRIVATE_KEY: skipped (--skip-bot-key); add them later from a device signed in to the broker with:"
  echo "      scripts/bot-secrets.sh --key claude $repo"
  echo "      scripts/bot-secrets.sh --key ci $repo"
else
  if grep -qx CLAUDE_APP_PRIVATE_KEY <<<"$names_actions"; then
    echo "    CLAUDE_APP_PRIVATE_KEY (actions): already set"
  elif ((dry_run)); then
    echo "DRY-RUN: scripts/bot-secrets.sh --key claude $repo"
  else
    "$script_dir/bot-secrets.sh" --key claude "$repo" ||
      die "the broker didn't set CLAUDE_APP_PRIVATE_KEY (see above; or rerun with --skip-bot-key)"
  fi
  if grep -qx CI_APP_PRIVATE_KEY <<<"$names_dependabot"; then
    echo "    CI_APP_PRIVATE_KEY (dependabot): already set"
  elif ((dry_run)); then
    echo "DRY-RUN: scripts/bot-secrets.sh --key ci $repo"
  else
    "$script_dir/bot-secrets.sh" --key ci "$repo" ||
      die "the broker didn't set CI_APP_PRIVATE_KEY (see above; or rerun with --skip-bot-key)"
  fi
fi
resolve_app_id() {
  local var_name="$1" out_var="$2" val="$3" prompt="$4"
  if [[ -z "$val" ]] && ! ((dry_run)); then
    val="$(gh variable get "$var_name" --repo "$repo" 2>/dev/null || true)"
    if [[ -z "$val" ]]; then
      ask val "$prompt" ||
        die "no terminal to prompt for $var_name; set $var_name"
    fi
  fi
  if ((dry_run)); then
    [[ -z "$val" || "$val" =~ ^[1-9][0-9]*$ ]] || usage_error "$var_name must be a number"
  else
    [[ "$val" =~ ^[1-9][0-9]*$ ]] || usage_error "$var_name must be a number, got: ${val:-<empty>}"
  fi
  printf -v "$out_var" '%s' "$val"
}
claude_app_id=""
ci_app_id=""
resolve_app_id CLAUDE_APP_ID claude_app_id "${CLAUDE_APP_ID:-}" "Claude App ID ($claude_app_slug, github.com/settings/apps): "
resolve_app_id CI_APP_ID ci_app_id "${CI_APP_ID:-}" "CI App ID ($ci_app_slug, github.com/settings/apps): "
run gh variable set CLAUDE_APP_ID --repo "$repo" --body "${claude_app_id:-<id>}"
run gh variable set CLAUDE_APP_SLUG --repo "$repo" --body "$claude_app_slug"
run gh variable set CI_APP_ID --repo "$repo" --body "${ci_app_id:-<id>}"

# --- 4. target: the same script that switches targets later (criterion 11).
# bootstrap-target.sh prints the "==> Target:" header itself. BOOTSTRAP_FIRST
# drops its "commit deploy.yml's target in a PR" hint: this commit has it.
target_args=(--target "$target" --stack "$stack" --repo "$repo")
((dry_run)) && target_args+=(--dry-run)
BOOTSTRAP_FIRST=1 "$root/scripts/bootstrap-target.sh" "${target_args[@]}"

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

# --- 6. GitHub: protect main. After the push: the rulesets block direct
# pushes to main.
step "GitHub: repo settings and rulesets"
settings_args=(--repo "$repo")
((dry_run)) && settings_args+=(--dry-run)
# gh-settings.sh prints its own DRY-RUN lines, so it is called directly.
CI_APP_ID="$ci_app_id" "$root/scripts/gh-settings.sh" "${settings_args[@]}"

step "Done. Next: add $repo to the installations of $claude_app_slug, $agy_app_slug and $ci_app_slug at https://github.com/settings/installations, then run make doctor."
