#!/usr/bin/env bash
# Tests for scripts/doctor.sh (FR-15). A fake gh serves fixture JSON per API
# path; nothing touches GitHub. Run from the repo root.
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
    f="$FIX/$(tr '/' '_' <<<"$2").json"
    [[ -f "$f" ]] && cat "$f" && exit 0
    exit 1 ;;
esac
exit 99
EOF
# A logged-out gcloud, so a real one on the owner's machine is never used.
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/gcloud"
chmod +x "$tmp/bin/gh" "$tmp/bin/gcloud"
# No gcloud login and no bot check: those checks must SKIP, not fail.
# No broker sign-in either: an empty BOT_CONFIG_DIR, so a signed-in machine's
# real ~/.config/agent-bot is never read (the broker cases set their own), and
# no BOT_BROKER_URL (cloud sessions export one).
mkdir -p "$tmp/no-botcfg"
unset BOT_BROKER_URL
export PATH="$tmp/bin:$PATH" FIX="$tmp/fix" DOCTOR_BOT_CHECK=/nonexistent BOT_CONFIG_DIR="$tmp/no-botcfg"

R=repos_acme_hello
good() {
  rm -f "$FIX"/*
  cat >"$FIX/$R.json" <<'EOF'
{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,
 "delete_branch_on_merge":true,"allow_auto_merge":true,
 "security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
EOF
  echo '[{"id":7,"name":"main"}]' >"$FIX/${R}_rulesets.json"
  cat >"$FIX/${R}_rulesets_7.json" <<'EOF'
{"enforcement":"active","rules":[{"type":"pull_request"},
 {"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci-ok"}]}}]}
EOF
  cat >"$FIX/${R}_environments.json" <<'EOF'
{"environments":[{"name":"dev"},
 {"name":"production","protection_rules":[{"type":"required_reviewers"}],
  "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}]}
EOF
  echo '{"branch_policies":[{"name":"main","type":"branch"}]}' >"$FIX/${R}_environments_production_deployment-branch-policies.json"
  echo '{"secrets":[{"name":"CLAUDE_CODE_OAUTH_TOKEN"},{"name":"BOT_APP_PRIVATE_KEY"}]}' >"$FIX/${R}_actions_secrets?per_page=100.json"
  echo '{"secrets":[{"name":"BOT_APP_PRIVATE_KEY"}]}' >"$FIX/${R}_dependabot_secrets?per_page=100.json"
  echo '{"variables":[{"name":"BOT_APP_ID","value":"1"},{"name":"GCP_PROJECT_ID","value":"p"},{"name":"GCP_REGION","value":"us-central1"},{"name":"GCP_WIF_PROVIDER","value":"w"},{"name":"GCP_DEPLOY_SA","value":"s"},{"name":"APP_NAME","value":"hello"}]}' >"$FIX/${R}_actions_variables?per_page=30.json"
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
has "bot App check skips without the Keychain" "SKIP  bot App installed"
has "target none needs no target checks" "PASS  deploy target: none"

# break <name> <fixture file> <jq edit> <expected FAIL line>
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
break_one "ruleset without ci-ok fails" "${R}_rulesets_7" '.rules |= map(select(.type != "required_status_checks"))' "ruleset main: requires ci-ok"
break_one "ruleset in evaluate mode fails" "${R}_rulesets_7" '.enforcement = "evaluate"' "ruleset main: active"
break_one "missing ruleset fails" "${R}_rulesets" '[]' "ruleset main"
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
break_one "missing Claude token fails" "${R}_actions_secrets?per_page=100" '.secrets |= map(select(.name != "CLAUDE_CODE_OAUTH_TOKEN"))' "secret: CLAUDE_CODE_OAUTH_TOKEN"
good
echo '{"secrets":[]}' >"$FIX/${R}_dependabot_secrets?per_page=100.json"
doc
has "missing bot key: hint is the Mac command" "fix: on a Mac: security find-generic-password -s github-app-private-key -w | base64 -d | gh secret set BOT_APP_PRIVATE_KEY --repo acme/hello --app dependabot"
# shellcheck disable=SC2016 # the hint is a literal command for the user
has "missing bot key: hint includes the Codespace command" 'in a Codespace with the BOT_APP_KEY_B64 secret: printf %s "$BOT_APP_KEY_B64" | base64 -d | gh secret set BOT_APP_PRIVATE_KEY --repo acme/hello --app dependabot'

# In a Codespace (spec 0002 phase 1): with BOT_APP_KEY_B64 the bot check runs;
# without it, doctor says how to add the Codespaces secret.
good
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bot-ok"
chmod +x "$tmp/bot-ok"
rc=0
out="$(CODESPACES=true BOT_APP_KEY_B64=x DOCTOR_BOT_CHECK="$tmp/bot-ok" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
has "codespace with the secret: bot check runs" "PASS  bot App installed on acme/hello"
if grep -q "bot key in this Codespace" <<<"$out"; then fail "codespace with the secret: no setup hint"; else pass "codespace with the secret: no setup hint"; fi
rc=0
out="$(CODESPACES=true DOCTOR_BOT_CHECK="$tmp/bot-ok" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
has "codespace without the secret: says how to add it" "SKIP  bot key in this Codespace (sign in to the broker with scripts/bot-login.sh, or add the Codespaces secret BOT_APP_KEY_B64"
if [[ "$rc" == 0 ]]; then pass "codespace without the secret: not a failure"; else fail "codespace without the secret: not a failure (rc $rc)"; fi

# Signed in to the broker (bot-login.sh, spec 0002 phase 2): the bot check runs.
mkdir -p "$tmp/botcfg"
printf 'x' >"$tmp/botcfg/identity"
printf 'https://broker.test\n' >"$tmp/botcfg/broker_url"
rc=0
cat >"$tmp/healthz" <<'EOF'
#!/usr/bin/env bash
echo "{\"ok\":true,\"enabled\":${HEALTH_ENABLED:-true}}"
EOF
chmod +x "$tmp/healthz"
out="$(BOT_CONFIG_DIR="$tmp/botcfg" PATH="$tmp/bin:/usr/bin:/bin" DOCTOR_HEALTHZ="$tmp/healthz" DOCTOR_BOT_CHECK="$tmp/bot-ok" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
has "broker sign-in: bot check runs" "PASS  bot App installed on acme/hello"
has "broker sign-in: the broker answers" "PASS  bot token broker answers and is enabled"
if grep -q "WARN" <<<"$out"; then fail "broker sign-in, no phase 1 secret: no warning"; else pass "broker sign-in, no phase 1 secret: no warning"; fi
rc=0
out="$(BOT_CONFIG_DIR="$tmp/botcfg" PATH="$tmp/bin:/usr/bin:/bin" HEALTH_ENABLED=false DOCTOR_HEALTHZ="$tmp/healthz" DOCTOR_BOT_CHECK="$tmp/bot-ok" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
has "broker kill switch on: fails" "FAIL  bot token broker answers and is enabled"
if [[ "$rc" != 0 ]]; then pass "broker kill switch on: exit non-zero"; else fail "broker kill switch on: exit non-zero"; fi
rc=0
out="$(CODESPACES=true BOT_APP_KEY_B64=x BOT_CONFIG_DIR="$tmp/botcfg" PATH="$tmp/bin:/usr/bin:/bin" DOCTOR_HEALTHZ="$tmp/healthz" DOCTOR_BOT_CHECK="$tmp/bot-ok" "$none_proj/scripts/doctor.sh" --repo acme/hello 2>&1)" || rc=$?
has "phase 1 secret alongside the broker: warns" "WARN  phase 1 bot key still in this Codespace (delete the Codespaces secret BOT_APP_KEY_B64"
break_one "missing Dependabot key fails" "${R}_dependabot_secrets?per_page=100" '.secrets = []' "Dependabot secret: BOT_APP_PRIVATE_KEY"
break_one "missing BOT_APP_ID fails" "${R}_actions_variables?per_page=30" '.variables |= map(select(.name != "BOT_APP_ID"))' "variable: BOT_APP_ID"

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
