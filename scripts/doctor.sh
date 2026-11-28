#!/usr/bin/env bash
# Read-only check that a project matches the spec (FR-15, spec §4.9; spec 0003
# FR-10). No AI; changes no settings, secrets or resources. The claude and agy
# App checks mint short-lived installation tokens via the broker (a POST to
# GitHub) because only each App's token can see its installation; the -ci App
# installation is checked via GET /user/installations. Prints PASS / FAIL /
# WARN / SKIP per check, with a fix hint for every FAIL, and exits 1 if
# anything failed.
#
# Usage: scripts/doctor.sh [--repo owner/name]
set -euo pipefail

repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || {
        echo "doctor: missing argument for --repo" >&2
        exit 64
      }
      repo="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "doctor: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n      fix: %s\n' "$1" "$2"
  fails=$((fails + 1))
}
skip() { printf 'SKIP  %s (%s)\n' "$1" "$2"; }
warn() { printf 'WARN  %s (%s)\n' "$1" "$2"; }
# expect <name> <fix> <condition...>: PASS if the condition command succeeds.
expect() {
  local name="$1" fix="$2"
  shift 2
  if "$@"; then pass "$name"; else fail "$name" "$fix"; fi
}
# quiet <cmd...>: run a check command with its output hidden.
quiet() { "$@" >/dev/null 2>&1; }
# api <path>: GET a GitHub API path as JSON. On error print nothing and
# remember the path, so the summary reports the read error itself instead of
# a misleading settings FAIL.
# api() runs inside $(...), a subshell, so failures go to a file, not an array.
tmp_dir="$(mktemp -d)"
api_errors="$tmp_dir/api_errors"
: >"$api_errors"
trap 'rm -rf "$tmp_dir"' EXIT
api() {
  gh api "$@" 2>/dev/null || {
    echo "$1" >>"$api_errors"
    true
  }
}
# jqt <json> <filter>: true if the jq filter is true for the JSON.
jqt() { [[ -n "$1" ]] && jq -e "$2" >/dev/null 2>&1 <<<"$1"; }

# --- tools
for tool in gh jq git; do
  expect "tool: $tool" "install $tool (see the machine setup)" quiet command -v "$tool"
done
if ! quiet command -v gh || ! quiet command -v jq; then
  echo "doctor: gh and jq are needed for the remaining checks" >&2
  exit 1
fi
expect "gh is logged in" "gh auth login" quiet gh auth status
if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
[[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]+$ ]] || {
  fail "repository" "run inside the project's clone, or pass --repo owner/name"
  exit 1
}
owner="${repo%%/*}"
claude_slug="$("$root/scripts/app-manifest.sh" --name "$owner" claude)"
agy_slug="$("$root/scripts/app-manifest.sh" --name "$owner" agy)"
ci_slug="$("$root/scripts/app-manifest.sh" --name "$owner" ci)"

echo "doctor: $repo"
settings="scripts/gh-settings.sh --repo $repo"

# --- repo settings
r="$(api "repos/$repo")"
expect "merge: squash only" "$settings" \
  jqt "$r" '.allow_squash_merge and (.allow_merge_commit | not) and (.allow_rebase_merge | not)'
expect "merge: delete branch on merge" "$settings" jqt "$r" '.delete_branch_on_merge'
expect "merge: auto-merge allowed" "$settings" jqt "$r" '.allow_auto_merge'
expect "security: secret scanning + push protection" "$settings" \
  jqt "$r" '.security_and_analysis.secret_scanning.status == "enabled" and .security_and_analysis.secret_scanning_push_protection.status == "enabled"'

# Fetch variables early so main-review can verify its -ci Integration actor_id
# against CI_APP_ID. 30 is the API's maximum page size for variables.
variables="$(api "repos/$repo/actions/variables?per_page=30")"
ci_app_id="$(jq -r '[.variables[]? | select(.name == "CI_APP_ID") | .value] | first // empty' <<<"$variables" 2>/dev/null || true)"

# --- rulesets (spec 0003 FR-7)
rulesets="$(api "repos/$repo/rulesets")"
rs_main_id="$(jq -r '[.[]? | select(.name == "main") | .id] | first // empty' <<<"$rulesets" 2>/dev/null || true)"
if [[ -n "$rs_main_id" ]]; then
  rs_main="$(api "repos/$repo/rulesets/$rs_main_id")"
  expect "ruleset main: active" "$settings" jqt "$rs_main" '.enforcement == "active"'
  expect "ruleset main: requires ci-ok" "$settings" \
    jqt "$rs_main" '[.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] | index("ci-ok") != null'
  expect "ruleset main: no Integration bypass" "$settings" \
    jqt "$rs_main" '[.bypass_actors[]? | select(.actor_type == "Integration")] | length == 0'
else
  fail "ruleset main" "$settings"
fi

rs_rev_id="$(jq -r '[.[]? | select(.name == "main-review") | .id] | first // empty' <<<"$rulesets" 2>/dev/null || true)"
if [[ -n "$rs_rev_id" ]]; then
  rs_rev="$(api "repos/$repo/rulesets/$rs_rev_id")"
  expect "ruleset main-review: active" "$settings" jqt "$rs_rev" '.enforcement == "active"'
  expect "ruleset main-review: requires a pull request with code owner review" "$settings" \
    jqt "$rs_rev" '[.rules[]? | select(.type == "pull_request" and .parameters.require_code_owner_review == true)] | length > 0'
  has_ci_bypass() {
    [[ -n "$rs_rev" ]] || return 1
    if [[ "$ci_app_id" =~ ^[1-9][0-9]*$ ]]; then
      jq -e --argjson id "$ci_app_id" \
        '[.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $id and .bypass_mode == "pull_request")] | length > 0' \
        >/dev/null 2>&1 <<<"$rs_rev"
    else
      jq -e \
        '[.bypass_actors[]? | select(.actor_type == "Integration" and (.actor_id | type == "number") and .bypass_mode == "pull_request")] | length > 0' \
        >/dev/null 2>&1 <<<"$rs_rev"
    fi
  }
  expect "ruleset main-review: -ci Integration bypass" "$settings" has_ci_bypass
else
  fail "ruleset main-review" "$settings"
fi

# --- environments
envs="$(api "repos/$repo/environments")"
expect "environment: dev" "make bootstrap (creates the Environments)" \
  jqt "$envs" '[.environments[]?.name] | index("dev") != null'
expect "environment: production has a required reviewer" "make bootstrap" \
  jqt "$envs" '[.environments[]? | select(.name == "production") | .protection_rules[]? | select(.type == "required_reviewers")] | length > 0'
policies=""
# Read the policies only if production exists: a 404 would add a misleading
# API FAIL on top of the Environment FAILs below.
if jqt "$envs" '[.environments[]?.name] | index("production") != null'; then
  policies="$(api "repos/$repo/environments/production/deployment-branch-policies")"
fi
expect "environment: production deploys from main only" "make bootstrap" \
  jqt "$envs" '[.environments[]? | select(.name == "production") | .deployment_branch_policy.custom_branch_policies] | index(true) != null'
expect "environment: production branch policy is main" "make bootstrap" \
  jqt "$policies" '[.branch_policies[]? | select(.name == "main")] | length > 0'

# --- secrets and variables (names only; values are never readable)
secrets="$(api "repos/$repo/actions/secrets?per_page=100")"
dependabot="$(api "repos/$repo/dependabot/secrets?per_page=100")"
has_name() { jqt "$1" "[.$2[]?.name] | index(\"$3\") != null"; }
lacks_name() { jqt "$1" "[.$2[]?.name] | index(\"$3\") == null"; }
has_num_var() { jqt "$1" "[.variables[]? | select(.name == \"$2\" and (.value | strings | test(\"^[1-9][0-9]*$\")))] | length > 0"; }

expect "secret: CLAUDE_CODE_OAUTH_TOKEN" "make bootstrap (or: claude setup-token | gh secret set CLAUDE_CODE_OAUTH_TOKEN)" \
  has_name "$secrets" secrets CLAUDE_CODE_OAUTH_TOKEN
expect "secret: CLAUDE_APP_PRIVATE_KEY" "scripts/bot-secrets.sh --key claude $repo" \
  has_name "$secrets" secrets CLAUDE_APP_PRIVATE_KEY
expect "Dependabot secret: CI_APP_PRIVATE_KEY" "scripts/bot-secrets.sh --key ci $repo" \
  has_name "$dependabot" secrets CI_APP_PRIVATE_KEY

expect "variable: CLAUDE_APP_ID" "make bootstrap" has_num_var "$variables" CLAUDE_APP_ID
expect "variable: CLAUDE_APP_SLUG" "make bootstrap" has_name "$variables" variables CLAUDE_APP_SLUG
expect "variable: CI_APP_ID" "make bootstrap" has_num_var "$variables" CI_APP_ID

# Wrong-scope secrets must never exist (FR-10, C2, C12).
expect "no Actions secret: CI_APP_PRIVATE_KEY" \
  "gh secret delete CI_APP_PRIVATE_KEY --repo $repo --app actions" \
  lacks_name "$secrets" secrets CI_APP_PRIVATE_KEY
expect "no Dependabot secret: CLAUDE_APP_PRIVATE_KEY" \
  "gh secret delete CLAUDE_APP_PRIVATE_KEY --repo $repo --app dependabot" \
  lacks_name "$dependabot" secrets CLAUDE_APP_PRIVATE_KEY

# Leftovers from before intent 0003 (FR-10).
if has_name "$variables" variables BOT_APP_ID; then
  warn "leftover variable: BOT_APP_ID" "gh variable delete BOT_APP_ID --repo $repo"
fi
if has_name "$secrets" secrets BOT_APP_PRIVATE_KEY; then
  warn "leftover Actions secret: BOT_APP_PRIVATE_KEY" "gh secret delete BOT_APP_PRIVATE_KEY --repo $repo --app actions"
fi
if has_name "$dependabot" secrets BOT_APP_PRIVATE_KEY; then
  warn "leftover Dependabot secret: BOT_APP_PRIVATE_KEY" "gh secret delete BOT_APP_PRIVATE_KEY --repo $repo --app dependabot"
fi
in_codespace=0
[[ "${CODESPACES:-}" == "true" ]] && in_codespace=1
if ((in_codespace)) && [[ -n "${BOT_APP_KEY_B64:-}" ]]; then
  warn "leftover Codespaces secret: BOT_APP_KEY_B64" "delete BOT_APP_KEY_B64 at https://github.com/settings/codespaces"
fi
# Check Keychain metadata only (no -w), so the key value is never read.
if quiet command -v security && quiet security find-generic-password -s github-app-private-key; then
  warn "leftover Keychain item: github-app-private-key" "security delete-generic-password -s github-app-private-key"
fi

# --- bot Apps and broker (FR-10, D6)
# DOCTOR_BOT_CHECK overrides scripts/bot-token.sh in tests.
bot_check="${DOCTOR_BOT_CHECK:-$root/scripts/bot-token.sh}"
broker=0
bot_cfg="${BOT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-bot}"
broker_url="${BOT_BROKER_URL:-$(cat "$bot_cfg/broker_url" 2>/dev/null || true)}"
if [[ -s "$bot_cfg/identity" && -n "$broker_url" ]]; then
  broker=1
fi
# FR-9: the broker answers and its kill switch is off. DOCTOR_HEALTHZ
# overrides the command that prints /healthz (tests).
broker_enabled() {
  local out
  if [[ -n "${DOCTOR_HEALTHZ:-}" ]]; then out="$("$DOCTOR_HEALTHZ")"; else out="$(curl -fsS --max-time 10 "${broker_url%/}/healthz")"; fi
  jq -e '.enabled == true' <<<"$out" >/dev/null
}
if ((broker)); then
  expect "bot token broker answers and is enabled" \
    "check ${broker_url%/}/healthz; the kill switch is BROKER_ENABLED in broker/wrangler.toml (broker/README.md)" \
    quiet broker_enabled
fi
if ((broker)) && [[ -x "$bot_check" ]]; then
  expect "bot App installed (claude: $claude_slug) on $repo" \
    "add $repo to $claude_slug at https://github.com/settings/installations" \
    quiet "$bot_check" --agent claude "$repo"
  expect "bot App installed (agy: $agy_slug) on $repo" \
    "add $repo to $agy_slug at https://github.com/settings/installations" \
    quiet "$bot_check" --agent agy "$repo"
else
  skip "bot Apps installed (claude, agy)" \
    "sign in to the broker with scripts/bot-login.sh, or check https://github.com/settings/installations"
fi

# -ci installation check via owner's gh (GET only, paginated).
jq_has_repo() {
  [[ -n "$1" ]] && jq -se --arg repo "$2" \
    '[.[].repositories[]?.full_name | strings | ascii_downcase] | index($repo | ascii_downcase) != null' \
    >/dev/null 2>&1 <<<"$1"
}
inst_err="$tmp_dir/inst_err"
inst_rc=0
inst_json="$(gh api "user/installations?per_page=100" --paginate 2>"$inst_err")" || inst_rc=$?
if [[ "$inst_rc" -ne 0 ]]; then
  if grep -qi 'authorized to a GitHub App' "$inst_err" || grep -qi 'authorized to a GitHub App' <<<"$inst_json"; then
    skip "bot App installed (ci: $ci_slug) on $repo" \
      "gh login cannot read /user/installations (403); verify $repo is in $ci_slug at https://github.com/settings/installations"
  else
    echo "user/installations?per_page=100" >>"$api_errors"
    fail "bot App installed (ci: $ci_slug) on $repo" \
      "add $repo to $ci_slug at https://github.com/settings/installations"
  fi
else
  ci_inst_id="$(jq -sr --arg slug "$ci_slug" \
    '[.[].installations[]? | select((.app_slug // "" | ascii_downcase) == ($slug | ascii_downcase)) | .id] | first // empty' \
    <<<"$inst_json" 2>/dev/null || true)"
  if [[ -n "$ci_inst_id" && "$ci_inst_id" =~ ^[0-9]+$ ]]; then
    ci_repos="$(api "user/installations/$ci_inst_id/repositories?per_page=100" --paginate)"
    expect "bot App installed (ci: $ci_slug) on $repo" \
      "add $repo to $ci_slug at https://github.com/settings/installations" \
      jq_has_repo "$ci_repos" "$repo"
  else
    fail "bot App installed (ci: $ci_slug) on $repo" \
      "install $ci_slug and add $repo at https://github.com/settings/installations"
  fi
fi

# --- deploy target
target="$(sed -n 's/^target:[[:space:]]*\([a-z0-9-]*\).*/\1/p' "$root/deploy.yml" 2>/dev/null | head -n 1)"
if [[ -z "$target" || ! -d "$root/deploy/targets/$target" ]]; then
  fail "deploy.yml target" "set target: in deploy.yml to one of deploy/targets/*"
elif [[ "$target" == none ]]; then
  pass "deploy target: none (nothing to check)"
else
  pass "deploy target: $target"
  # Every repo variable the adapter's target.yml requires.
  while read -r var; do
    [[ -n "$var" ]] || continue
    expect "variable: $var ($target)" "make bootstrap-target" has_name "$variables" variables "$var"
  done < <(sed -n '/^required_variables:/,/^[^[:space:]-]/s/^[[:space:]]*-[[:space:]]*\([A-Z0-9_]*\).*/\1/p' \
    "$root/deploy/targets/$target/target.yml")
  if [[ "$target" == cloud-run ]]; then
    if quiet command -v gcloud && [[ -n "$(gcloud auth list --filter status:ACTIVE --format 'value(account)' 2>/dev/null)" ]]; then
      vals="$(jq -r '.variables[]? | "\(.name)=\(.value)"' <<<"$variables" 2>/dev/null || true)"
      project="$(sed -n 's/^GCP_PROJECT_ID=//p' <<<"$vals")"
      region="$(sed -n 's/^GCP_REGION=//p' <<<"$vals")"
      app="$(sed -n 's/^APP_NAME=//p' <<<"$vals")"
      if [[ -z "$project" || -z "$app" ]]; then
        skip "cloud-run: services exist" "GCP_PROJECT_ID or APP_NAME is not set (see above)"
      else
        for svc in "$app-dev" "$app-prod"; do
          expect "cloud-run: $svc exists" "make bootstrap-target" \
            quiet gcloud run services describe "$svc" --project "$project" --region "${region:-us-central1}" --format 'value(metadata.name)'
        done
      fi
    else
      skip "cloud-run: services exist" "gcloud is not installed or not logged in"
    fi
  fi
fi

if [[ -s "$api_errors" ]]; then
  fail "GitHub API reads ($(wc -l <"$api_errors" | tr -d ' ') failed: $(sort -u "$api_errors" | tr '\n' ' ' | sed 's/ $//'))" \
    "check gh auth status and its scopes (gh auth refresh -s repo); the checks above may be wrong"
fi

echo
if ((fails)); then
  echo "doctor: $fails check(s) failed"
  exit 1
fi
echo "doctor: all checks passed"
