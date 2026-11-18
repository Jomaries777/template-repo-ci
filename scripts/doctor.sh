#!/usr/bin/env bash
# Read-only check that a project matches the spec (FR-15, spec §4.9). No AI;
# changes no settings, secrets or resources. The bot App check mints a
# short-lived installation token (a POST to GitHub) because only the App's own
# token can see its installation. Prints PASS / FAIL / SKIP per check, with a
# fix hint for every FAIL, and exits 1 if anything failed.
#
# Usage: scripts/doctor.sh [--repo owner/name]
set -euo pipefail

repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    -h | --help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "doctor: unknown argument: $1" >&2; exit 64 ;;
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
api_errors="$(mktemp)"
trap 'rm -f "$api_errors"' EXIT
api() {
  gh api "$1" 2>/dev/null || {
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
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  fail "repository" "run inside the project's clone, or pass --repo owner/name"
  exit 1
}
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

# --- ruleset
rs_id="$(jq -r '.[]? | select(.name == "main") | .id' <<<"$(api "repos/$repo/rulesets")" 2>/dev/null || true)"
if [[ -n "$rs_id" ]]; then
  rs="$(api "repos/$repo/rulesets/$rs_id")"
  expect "ruleset main: active" "$settings" jqt "$rs" '.enforcement == "active"'
  expect "ruleset main: requires ci-ok" "$settings" \
    jqt "$rs" '[.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] | index("ci-ok") != null'
  expect "ruleset main: requires a pull request" "$settings" jqt "$rs" '[.rules[]?.type] | index("pull_request") != null'
else
  fail "ruleset main" "$settings"
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
# 30 is the API's maximum page size for variables.
variables="$(api "repos/$repo/actions/variables?per_page=30")"
has_name() { jqt "$1" "[.$2[]?.name] | index(\"$3\") != null"; }
expect "secret: CLAUDE_CODE_OAUTH_TOKEN" "make bootstrap (or: claude setup-token | gh secret set CLAUDE_CODE_OAUTH_TOKEN)" \
  has_name "$secrets" secrets CLAUDE_CODE_OAUTH_TOKEN
# The bot key comes from a Mac Keychain or, in a Codespace, the Codespaces
# secret BOT_APP_KEY_B64 (spec 0002 phase 1); bootstrap --skip-bot-key leaves
# it out. bot_key_fix <app>: both ways to set it.
bot_key_fix() {
  # shellcheck disable=SC2016 # a command for the user to run, not expanded here
  printf '%s' "on a Mac: security find-generic-password -s github-app-private-key -w | base64 -d | gh secret set BOT_APP_PRIVATE_KEY --repo $repo --app $1" \
    '; in a Codespace with the BOT_APP_KEY_B64 secret: printf %s "$BOT_APP_KEY_B64" | base64 -d | gh secret set BOT_APP_PRIVATE_KEY'" --repo $repo --app $1"
}
expect "secret: BOT_APP_PRIVATE_KEY" "$(bot_key_fix actions)" has_name "$secrets" secrets BOT_APP_PRIVATE_KEY
expect "Dependabot secret: BOT_APP_PRIVATE_KEY" "$(bot_key_fix dependabot)" has_name "$dependabot" secrets BOT_APP_PRIVATE_KEY
expect "variable: BOT_APP_ID" "make bootstrap" has_name "$variables" variables BOT_APP_ID

# --- bot App installation: only the App's own token can see it. Minting one
# (bot-token.sh) is a POST to GitHub but changes no repo state.
# DOCTOR_BOT_CHECK overrides the command (tests point it at nothing).
bot_check="${DOCTOR_BOT_CHECK:-$root/scripts/bot-token.sh}"
in_codespace=0
[[ "${CODESPACES:-}" == "true" ]] && in_codespace=1
have_key=0 broker=0
bot_cfg="${BOT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-bot}"
broker_url="${BOT_BROKER_URL:-$(cat "$bot_cfg/broker_url" 2>/dev/null || true)}"
if [[ -s "$bot_cfg/identity" && -n "$broker_url" ]]; then
  have_key=1 broker=1 # the broker (bot-login.sh), spec 0002 phase 2
elif ((in_codespace)) && [[ -n "${BOT_APP_KEY_B64:-}" ]]; then
  have_key=1
elif quiet command -v security; then
  have_key=1
fi
# FR-9: the broker answers and its kill switch is off. DOCTOR_HEALTHZ
# overrides the command that prints /healthz (tests).
broker_enabled() {
  local out
  if [[ -n "${DOCTOR_HEALTHZ:-}" ]]; then out="$("$DOCTOR_HEALTHZ")"; else out="$(curl -fsS --max-time 10 "${broker_url%/}/healthz")"; fi
  jq -e '.enabled == true' <<<"$out" >/dev/null
}
if ((broker)); then
  expect "bot token broker answers and is enabled" "check ${broker_url%/}/healthz; the kill switch is BROKER_ENABLED in broker/wrangler.toml (broker/README.md)" \
    quiet broker_enabled
  # Phase 1 is retired once the broker is live (spec 0002 C5).
  if ((in_codespace)) && [[ -n "${BOT_APP_KEY_B64:-}" ]]; then
    warn "phase 1 bot key still in this Codespace" "delete the Codespaces secret BOT_APP_KEY_B64 at github.com/settings/codespaces and rotate the App key (broker/README.md)"
  fi
elif ((in_codespace)) && [[ -z "${BOT_APP_KEY_B64:-}" ]]; then
  skip "bot key in this Codespace" "sign in to the broker with scripts/bot-login.sh, or add the Codespaces secret BOT_APP_KEY_B64 at github.com/settings/codespaces with access to $repo, then restart the Codespace"
fi
if [[ -x "$bot_check" ]] && ((have_key)); then
  expect "bot App installed on $repo" "install the bot App on $repo (github.com/settings/apps)" \
    quiet "$bot_check"
else
  skip "bot App installed" "needs scripts/bot-login.sh, the Mac Keychain key, or BOT_APP_KEY_B64 in a Codespace; check github.com/settings/installations"
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
