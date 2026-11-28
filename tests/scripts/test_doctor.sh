#!/usr/bin/env bash
# Tests for scripts/doctor.sh (FR-15; spec 0003 FR-10, acceptance criterion 10).
# A fake gh serves fixture JSON per API path and fake security/gcloud keep the
# suite hermetic; nothing touches GitHub, the network, or the real Keychain.
# Run from the repo root.
set -euo pipefail

src="$PWD"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/fix"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit "${GH_AUTH_RC:-0}" ;;
  "api "*)
    # doctor.sh must be GET-only against gh api.
    for arg in "$@"; do
      if [[ "$arg" == -X || "$arg" == --method ]]; then
        echo "unexpected mutating gh api call: $*" >&2
        exit 99
      fi
    done
    if [[ -n "${FAKE_INSTALLATIONS_403:-}" && "$2" == user/installations* ]]; then
      echo "gh: You must authenticate with an access token authorized to a GitHub App (HTTP 403)" >&2
      exit 1
    fi
    if [[ -n "${FAKE_INSTALLATIONS_RATE_LIMIT_403:-}" && "$2" == user/installations* ]]; then
      echo "gh: API rate limit exceeded (HTTP 403)" >&2
      exit 1
    fi
    f="$FIX/$(tr '/' '_' <<<"$2").json"
    [[ -f "$f" ]] && cat "$f" && exit 0
    exit 1 ;;
esac
exit 99
EOF
# A logged-out gcloud, so a real one on the owner's machine is never used.
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/gcloud"
# A fake security binary so the real macOS Keychain is never touched.
# Fails loudly (exit 98) if -w is ever passed, proving values are never read.
cat >"$tmp/bin/security" <<'EOF'
#!/usr/bin/env bash
[[ -z "${SECURITY_LOG:-}" ]] || echo "$*" >>"$SECURITY_LOG"
for arg in "$@"; do
  if [[ "$arg" == -w ]]; then
    echo "security must not be called with -w" >&2
    exit 98
  fi
done
if [[ "${FAKE_KEYCHAIN_BOT_KEY:-0}" == 1 && "$*" == *"find-generic-password"*"github-app-private-key"* ]]; then
  exit 0
fi
exit 44
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/gcloud" "$tmp/bin/security"
# No gcloud login and no broker sign-in by default: an empty BOT_CONFIG_DIR so
# a signed-in machine's real ~/.config/agent-bot is never read (broker cases
# set their own), and no BOT_BROKER_URL (cloud sessions export one).
mkdir -p "$tmp/no-botcfg"
unset BOT_BROKER_URL CODESPACES BOT_APP_KEY_B64
export PATH="$tmp/bin:$PATH" FIX="$tmp/fix" DOCTOR_BOT_CHECK=/nonexistent BOT_CONFIG_DIR="$tmp/no-botcfg"

R=repos_acme_hello
good() {
  rm -f "$FIX"/*
  cat >"$FIX/$R.json" <<'EOF'
{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,
 "delete_branch_on_merge":true,"allow_auto_merge":true,
 "security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
EOF
  echo '[{"id":7,"name":"main"},{"id":8,"name":"main-review"}]' >"$FIX/${R}_rulesets.json"
  cat >"$FIX/${R}_rulesets_7.json" <<'EOF'
{"enforcement":"active","rules":[
 {"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci-ok"}]}}]}
EOF
  cat >"$FIX/${R}_rulesets_8.json" <<'EOF'
{"enforcement":"active",
 "bypass_actors":[
   {"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"},
   {"actor_id":222,"actor_type":"Integration","bypass_mode":"pull_request"}
 ],
 "rules":[{"type":"pull_request","parameters":{"require_code_owner_review":true}}]}
EOF
  cat >"$FIX/${R}_environments.json" <<'EOF'
{"environments":[{"name":"dev"},
 {"name":"production","protection_rules":[{"type":"required_reviewers"}],
  "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}]}
EOF
  echo '{"branch_policies":[{"name":"main","type":"branch"}]}' >"$FIX/${R}_environments_production_deployment-branch-policies.json"
  echo '{"secrets":[{"name":"CLAUDE_CODE_OAUTH_TOKEN"},{"name":"CLAUDE_APP_PRIVATE_KEY"}]}' >"$FIX/${R}_actions_secrets?per_page=100.json"
  echo '{"secrets":[{"name":"CI_APP_PRIVATE_KEY"}]}' >"$FIX/${R}_dependabot_secrets?per_page=100.json"
  echo '{"variables":[{"name":"CLAUDE_APP_ID","value":"111"},{"name":"CLAUDE_APP_SLUG","value":"acme-claude"},{"name":"CI_APP_ID","value":"222"},{"name":"GCP_PROJECT_ID","value":"p"},{"name":"GCP_REGION","value":"us-central1"},{"name":"GCP_WIF_PROVIDER","value":"w"},{"name":"GCP_DEPLOY_SA","value":"s"},{"name":"APP_NAME","value":"hello"}]}' >"$FIX/${R}_actions_variables?per_page=30.json"
  echo '{"installations":[{"id":99,"app_slug":"acme-ci"}]}' >"$FIX/user_installations?per_page=100.json"
  echo '{"repositories":[{"full_name":"Acme/Hello"}]}' >"$FIX/user_installations_99_repositories?per_page=100.json"
}

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}
# Doctor reads deploy.yml next to itself, so each case runs in its own copy
# of the working tree with the deploy.yml (and adapter folder) it needs.
# mkproj <dir> <target>
mkproj() {
  mkdir -p "$1"
  (cd "$src" && git ls-files -co --exclude-standard -z | tar --null -cf - -T -) | tar -xf - -C "$1"
  printf 'target: %s\n' "$2" >"$1/deploy.yml"
  mkdir -p "$1/deploy/targets/$2"
}
none_proj="$tmp/none"
mkproj "$none_proj" none
# doc [dir]: run doctor (default: the target-none copy) and set rc and out.
doc() {
  rc=0
  out="$("${1:-$none_proj}/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
}
has() { if grep -qF -- "$2" <<<"$out"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }

good
doc
if [[ "$rc" == 0 ]]; then pass "all good: exits 0"; else fail "all good: rc $rc: $(grep FAIL <<<"$out" | tr '\n' ';')"; fi
has "all good: says so" "doctor: all checks passed"
if grep -q "WARN" <<<"$out"; then fail "all good: no warnings"; else pass "all good: no warnings"; fi
has "bot App check skips without broker sign-in" "SKIP  bot Apps installed (claude, agy)"
has "-ci App check passes via /user/installations (case-insensitive repo)" "PASS  bot App installed (ci: acme-ci) on acme/hello"
has "target none needs no target checks" "PASS  deploy target: none"

# break_one <name> <fixture file> <jq edit> <expected FAIL line>
break_one() {
  good
  local f="$FIX/$2.json"
  jq "$3" "$f" >"$f.new" && mv "$f.new" "$f"
  doc
  if [[ "$rc" == 1 ]] && grep -qF "FAIL  $4" <<<"$out" && grep -A1 -F "FAIL  $4" <<<"$out" | grep -q "fix: "; then
    pass "$1"
  else
    fail "$1 (rc $rc; want FAIL $4 with a fix hint)"
  fi
}
break_one "merge commits on fail" "$R" '.allow_merge_commit = true' "merge: squash only"
break_one "no auto-merge fails" "$R" '.allow_auto_merge = false' "merge: auto-merge allowed"
break_one "push protection off fails" "$R" '.security_and_analysis.secret_scanning_push_protection.status = "disabled"' "security: secret scanning + push protection"

# --- rulesets (main + main-review)
break_one "ruleset main without ci-ok fails" "${R}_rulesets_7" '.rules |= map(select(.type != "required_status_checks"))' "ruleset main: requires ci-ok"
break_one "ruleset main in evaluate mode fails" "${R}_rulesets_7" '.enforcement = "evaluate"' "ruleset main: active"
break_one "ruleset main with Integration bypass fails (FR-7)" "${R}_rulesets_7" '.bypass_actors = [{"actor_id":222,"actor_type":"Integration","bypass_mode":"pull_request"}]' "ruleset main: no Integration bypass"
break_one "missing ruleset main fails" "${R}_rulesets" 'map(select(.name != "main"))' "ruleset main"
break_one "ruleset main-review in evaluate mode fails" "${R}_rulesets_8" '.enforcement = "evaluate"' "ruleset main-review: active"
break_one "ruleset main-review without pull_request fails" "${R}_rulesets_8" '.rules = []' "ruleset main-review: requires a pull request with code owner review"
break_one "ruleset main-review with require_code_owner_review false fails" "${R}_rulesets_8" '.rules[0].parameters.require_code_owner_review = false' "ruleset main-review: requires a pull request with code owner review"
break_one "ruleset main-review without -ci Integration bypass fails" "${R}_rulesets_8" '.bypass_actors |= map(select(.actor_type != "Integration"))' "ruleset main-review: -ci Integration bypass"
break_one "ruleset main-review with wrong -ci Integration ID fails" "${R}_rulesets_8" '(.bypass_actors[] | select(.actor_type == "Integration") | .actor_id) = 999' "ruleset main-review: -ci Integration bypass"
break_one "missing ruleset main-review fails" "${R}_rulesets" 'map(select(.name != "main-review"))' "ruleset main-review"

# --- environments
break_one "production without a reviewer fails" "${R}_environments" '.environments[1].protection_rules = []' "environment: production has a required reviewer"
break_one "production from any branch fails" "${R}_environments" '.environments[1].deployment_branch_policy = null' "environment: production deploys from main only"
break_one "production policy not main fails" "${R}_environments_production_deployment-branch-policies" '.branch_policies[0].name = "dev"' "environment: production branch policy is main"
good
jq '.environments |= map(select(.name != "production"))' "$FIX/${R}_environments.json" >"$tmp/e" && mv "$tmp/e" "$FIX/${R}_environments.json"
rm -f "$FIX/${R}_environments_production_deployment-branch-policies.json"
doc
has "missing production fails its checks" "FAIL  environment: production has a required reviewer"
if grep -q "GitHub API reads" <<<"$out"; then fail "missing production: no extra API FAIL"; else pass "missing production: no extra API FAIL"; fi
break_one "missing dev fails" "${R}_environments" '.environments |= map(select(.name != "dev"))' "environment: dev"

# --- required secrets and variables (FR-10)
break_one "missing Claude OAuth token fails" "${R}_actions_secrets?per_page=100" '.secrets |= map(select(.name != "CLAUDE_CODE_OAUTH_TOKEN"))' "secret: CLAUDE_CODE_OAUTH_TOKEN"
break_one "missing CLAUDE_APP_PRIVATE_KEY fails" "${R}_actions_secrets?per_page=100" '.secrets |= map(select(.name != "CLAUDE_APP_PRIVATE_KEY"))' "secret: CLAUDE_APP_PRIVATE_KEY"
has "missing CLAUDE_APP_PRIVATE_KEY hint uses bot-secrets.sh --key claude" "fix: scripts/bot-secrets.sh --key claude acme/hello"
break_one "missing Dependabot CI_APP_PRIVATE_KEY fails" "${R}_dependabot_secrets?per_page=100" '.secrets = []' "Dependabot secret: CI_APP_PRIVATE_KEY"
has "missing CI_APP_PRIVATE_KEY hint uses bot-secrets.sh --key ci" "fix: scripts/bot-secrets.sh --key ci acme/hello"
break_one "missing CLAUDE_APP_ID fails" "${R}_actions_variables?per_page=30" '.variables |= map(select(.name != "CLAUDE_APP_ID"))' "variable: CLAUDE_APP_ID"
break_one "non-numeric CLAUDE_APP_ID fails" "${R}_actions_variables?per_page=30" '(.variables[] | select(.name == "CLAUDE_APP_ID") | .value) = "abc"' "variable: CLAUDE_APP_ID"
break_one "missing CLAUDE_APP_SLUG fails" "${R}_actions_variables?per_page=30" '.variables |= map(select(.name != "CLAUDE_APP_SLUG"))' "variable: CLAUDE_APP_SLUG"
break_one "missing CI_APP_ID fails" "${R}_actions_variables?per_page=30" '.variables |= map(select(.name != "CI_APP_ID"))' "variable: CI_APP_ID"
break_one "non-numeric CI_APP_ID fails" "${R}_actions_variables?per_page=30" '(.variables[] | select(.name == "CI_APP_ID") | .value) = "abc"' "variable: CI_APP_ID"

# --- wrong-scope secret FAILs (FR-10, C2, C12; acceptance criterion 10)
break_one "CI_APP_PRIVATE_KEY as Actions secret fails (C2)" "${R}_actions_secrets?per_page=100" \
  '.secrets += [{"name":"CI_APP_PRIVATE_KEY"}]' "no Actions secret: CI_APP_PRIVATE_KEY"
break_one "CLAUDE_APP_PRIVATE_KEY as Dependabot secret fails (C12)" "${R}_dependabot_secrets?per_page=100" \
  '.secrets += [{"name":"CLAUDE_APP_PRIVATE_KEY"}]' "no Dependabot secret: CLAUDE_APP_PRIVATE_KEY"

# --- leftover WARNs (FR-10; acceptance criterion 10): each warns and exits 0
warn_one() {
  good
  local f="$FIX/$2.json"
  jq "$3" "$f" >"$f.new" && mv "$f.new" "$f"
  doc
  if [[ "$rc" == 0 ]] && grep -qF "WARN  $4" <<<"$out"; then
    pass "$1"
  else
    fail "$1 (rc $rc; want WARN $4)"
  fi
}
warn_one "leftover BOT_APP_ID variable warns" "${R}_actions_variables?per_page=30" \
  '.variables += [{"name":"BOT_APP_ID","value":"1"}]' "leftover variable: BOT_APP_ID"
warn_one "leftover BOT_APP_PRIVATE_KEY Actions secret warns" "${R}_actions_secrets?per_page=100" \
  '.secrets += [{"name":"BOT_APP_PRIVATE_KEY"}]' "leftover Actions secret: BOT_APP_PRIVATE_KEY"
warn_one "leftover BOT_APP_PRIVATE_KEY Dependabot secret warns" "${R}_dependabot_secrets?per_page=100" \
  '.secrets += [{"name":"BOT_APP_PRIVATE_KEY"}]' "leftover Dependabot secret: BOT_APP_PRIVATE_KEY"

good
cat >"$tmp/bot-check" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$BOT_CHECK_LOG"
[[ "${BOT_CHECK_FAIL_AGENT:-}" == "$2" ]] && exit 1
exit 0
EOF
chmod +x "$tmp/bot-check"
: >"$tmp/bot-check.log"
rc=0
out="$(CODESPACES=true BOT_APP_KEY_B64=x BOT_CHECK_LOG="$tmp/bot-check.log" DOCTOR_BOT_CHECK="$tmp/bot-check" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
if [[ "$rc" == 0 ]]; then pass "leftover BOT_APP_KEY_B64 in Codespace: exits 0"; else fail "leftover BOT_APP_KEY_B64 in Codespace: rc $rc"; fi
has "leftover BOT_APP_KEY_B64 in Codespace: warns" "WARN  leftover Codespaces secret: BOT_APP_KEY_B64"
if [[ ! -s "$tmp/bot-check.log" ]]; then pass "BOT_APP_KEY_B64 is not used as a key source (D6)"; else fail "BOT_APP_KEY_B64 is not used as a key source"; fi

good
: >"$tmp/sec.log"
rc=0
out="$(FAKE_KEYCHAIN_BOT_KEY=1 SECURITY_LOG="$tmp/sec.log" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
if [[ "$rc" == 0 ]]; then pass "leftover Keychain item: exits 0"; else fail "leftover Keychain item: rc $rc"; fi
has "leftover Keychain item: warns" "WARN  leftover Keychain item: github-app-private-key"
if grep -q "find-generic-password -s github-app-private-key" "$tmp/sec.log" && ! grep -q -- "-w" "$tmp/sec.log"; then
  pass "Keychain check never passes -w (never reads secret value)"
else
  fail "Keychain check never passes -w (saw: $(cat "$tmp/sec.log"))"
fi

# --- broker checks: /healthz and --agent claude / --agent agy
mkdir -p "$tmp/botcfg"
printf 'x' >"$tmp/botcfg/identity"
printf 'https://broker.test\n' >"$tmp/botcfg/broker_url"
cat >"$tmp/healthz" <<'EOF'
#!/usr/bin/env bash
echo "{\"ok\":true,\"enabled\":${HEALTH_ENABLED:-true}}"
EOF
chmod +x "$tmp/healthz"

good
: >"$tmp/bot-check.log"
rc=0
out="$(BOT_CONFIG_DIR="$tmp/botcfg" PATH="$tmp/bin:/usr/bin:/bin" BOT_CHECK_LOG="$tmp/bot-check.log" \
  DOCTOR_HEALTHZ="$tmp/healthz" DOCTOR_BOT_CHECK="$tmp/bot-check" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
if [[ "$rc" == 0 ]]; then pass "broker sign-in: exits 0"; else fail "broker sign-in: rc $rc"; fi
has "broker sign-in: the broker answers" "PASS  bot token broker answers and is enabled"
has "broker sign-in: claude App check passes" "PASS  bot App installed (claude: acme-claude) on acme/hello"
has "broker sign-in: agy App check passes" "PASS  bot App installed (agy: acme-agy) on acme/hello"
if grep -qx -- "--agent claude acme/hello" "$tmp/bot-check.log" && grep -qx -- "--agent agy acme/hello" "$tmp/bot-check.log"; then
  pass "broker sign-in: bot-token.sh called with --agent claude and --agent agy"
else
  fail "broker sign-in: bot-token.sh args wrong ($(tr '\n' ';' <"$tmp/bot-check.log"))"
fi
if grep -q "WARN" <<<"$out"; then fail "broker sign-in, no leftovers: no warning"; else pass "broker sign-in, no leftovers: no warning"; fi

rc=0
out="$(BOT_CONFIG_DIR="$tmp/botcfg" PATH="$tmp/bin:/usr/bin:/bin" HEALTH_ENABLED=false BOT_CHECK_LOG="$tmp/bot-check.log" \
  DOCTOR_HEALTHZ="$tmp/healthz" DOCTOR_BOT_CHECK="$tmp/bot-check" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
has "broker kill switch on: fails" "FAIL  bot token broker answers and is enabled"
if [[ "$rc" != 0 ]]; then pass "broker kill switch on: exit non-zero"; else fail "broker kill switch on: exit non-zero"; fi

rc=0
out="$(BOT_CONFIG_DIR="$tmp/botcfg" PATH="$tmp/bin:/usr/bin:/bin" BOT_CHECK_FAIL_AGENT=agy BOT_CHECK_LOG="$tmp/bot-check.log" \
  DOCTOR_HEALTHZ="$tmp/healthz" DOCTOR_BOT_CHECK="$tmp/bot-check" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
has "broker agy check failure: claude still passes" "PASS  bot App installed (claude: acme-claude) on acme/hello"
has "broker agy check failure: agy fails" "FAIL  bot App installed (agy: acme-agy) on acme/hello"
if [[ "$rc" != 0 ]]; then pass "broker agy check failure: exit non-zero"; else fail "broker agy check failure: exit non-zero"; fi

rc=0
out="$(BOT_CONFIG_DIR="$tmp/botcfg" PATH="$tmp/bin:/usr/bin:/bin" BOT_CHECK_FAIL_AGENT=claude BOT_CHECK_LOG="$tmp/bot-check.log" \
  DOCTOR_HEALTHZ="$tmp/healthz" DOCTOR_BOT_CHECK="$tmp/bot-check" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
has "broker claude check failure: claude fails" "FAIL  bot App installed (claude: acme-claude) on acme/hello"
has "broker claude check failure: agy still passes" "PASS  bot App installed (agy: acme-agy) on acme/hello"
if [[ "$rc" != 0 ]]; then pass "broker claude check failure: exit non-zero"; else fail "broker claude check failure: exit non-zero"; fi

# --- -ci installation checks via GET /user/installations (paginated)
break_one "-ci App missing from /user/installations fails" "user_installations?per_page=100" \
  '.installations = [{"id":98,"app_slug":"acme-claude"}]' "bot App installed (ci: acme-ci) on acme/hello"
break_one "repo missing from -ci installation repositories fails" "user_installations_99_repositories?per_page=100" \
  '.repositories = [{"full_name":"acme/other"}]' "bot App installed (ci: acme-ci) on acme/hello"

# Multi-page responses from gh api --paginate (NDJSON): -ci App and repo on page 2.
good
printf '{"installations":[{"id":98,"app_slug":"acme-claude"}]}\n{"installations":[{"id":99,"app_slug":"acme-ci"}]}\n' \
  >"$FIX/user_installations?per_page=100.json"
printf '{"repositories":[{"full_name":"acme/other"}]}\n{"repositories":[{"full_name":"Acme/Hello"}]}\n' \
  >"$FIX/user_installations_99_repositories?per_page=100.json"
doc
if [[ "$rc" == 0 ]]; then pass "-ci installation paginated across pages: exits 0"; else fail "-ci installation paginated: rc $rc"; fi
has "-ci installation paginated: finds repo on page 2" "PASS  bot App installed (ci: acme-ci) on acme/hello"

good
rc=0
out="$(FAKE_INSTALLATIONS_403=1 "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
if [[ "$rc" == 0 ]]; then pass "-ci installation 403 (standard gh OAuth token): exits 0"; else fail "-ci installation 403: rc $rc"; fi
has "-ci installation 403: skips with guidance" "SKIP  bot App installed (ci: acme-ci) on acme/hello"
if grep -q "GitHub API reads" <<<"$out"; then fail "-ci installation 403: no extra API FAIL"; else pass "-ci installation 403: no extra API FAIL"; fi

good
rc=0
out="$(FAKE_INSTALLATIONS_RATE_LIMIT_403=1 "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
if [[ "$rc" == 1 ]]; then pass "-ci installation non-App-auth 403 (rate limit): fails"; else fail "-ci installation non-App-auth 403: rc $rc"; fi
has "-ci installation non-App-auth 403: fails check instead of skipping" "FAIL  bot App installed (ci: acme-ci) on acme/hello"
has "-ci installation non-App-auth 403: recorded in API reads" "FAIL  GitHub API reads (1 failed: user/installations?per_page=100)"

good
rm -f "$FIX/user_installations?per_page=100.json"
doc
has "-ci installation non-403 API error fails" "FAIL  bot App installed (ci: acme-ci) on acme/hello"
has "-ci installation non-403 API error reported in API reads" "FAIL  GitHub API reads (1 failed: user/installations?per_page=100)"

# --- CLI usage and input validation
if "$none_proj/scripts/doctor.sh" --help | grep -q "Usage: scripts/doctor.sh"; then
  pass "doctor --help prints Usage line"
else
  fail "doctor --help prints Usage line"
fi
rc=0
"$none_proj/scripts/doctor.sh" --repo >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 64 ]]; then pass "doctor --repo without value exits 64"; else fail "doctor --repo without value: rc $rc (want 64)"; fi
rc=0
out="$("$none_proj/scripts/doctor.sh" --repo a_b/hello 2>&1)" || rc=$?
if [[ "$rc" == 1 ]] && grep -qF "FAIL  repository" <<<"$out" && ! grep -q "app-manifest.sh" <<<"$out"; then
  pass "doctor invalid owner fails cleanly as FAIL repository"
else
  fail "doctor invalid owner (rc $rc; out: $out)"
fi

# --- generic API read error and logged-out gh
good
rm -f "$FIX/${R}_environments.json"
doc
has "an unreadable API path is its own FAIL" "FAIL  GitHub API reads (1 failed: repos/acme/hello/environments)"
has "the read-error FAIL has a scopes hint" "fix: check gh auth status and its scopes"

good
GH_AUTH_RC=1 doc
has "gh logged out fails with a hint" "FAIL  gh is logged in"

# --- a project on cloud-run: the adapter's required variables are checked
if [[ -f "$src/deploy/targets/cloud-run/target.yml" ]]; then
  proj="$tmp/proj"
  mkproj "$proj" cloud-run
  good
  doc "$proj"
  if [[ "$rc" == 0 ]]; then pass "cloud-run: all variables present passes"; else fail "cloud-run: rc $rc: $(grep FAIL <<<"$out" | tr '\n' ';')"; fi
  has "cloud-run: checks GCP_WIF_PROVIDER" "PASS  variable: GCP_WIF_PROVIDER (cloud-run)"
  has "cloud-run: service check skips without gcloud" "SKIP  cloud-run: services exist"
  jq '.variables |= map(select(.name != "GCP_DEPLOY_SA"))' "$FIX/${R}_actions_variables?per_page=30.json" >"$tmp/v" && mv "$tmp/v" "$FIX/${R}_actions_variables?per_page=30.json"
  doc "$proj"
  has "cloud-run: missing GCP_DEPLOY_SA fails" "FAIL  variable: GCP_DEPLOY_SA (cloud-run)"
  has "cloud-run: hint names make bootstrap-target" "fix: make bootstrap-target"
fi

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
