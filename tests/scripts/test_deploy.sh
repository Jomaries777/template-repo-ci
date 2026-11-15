#!/usr/bin/env bash
# Tests for scripts/deploy.sh and the cloud-run and none adapters (spec
# §4.11). Dry run only: no cloud CLI or credentials. Run from the repo root.
set -euo pipefail

root="$PWD"
deploy="$root/scripts/deploy.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stub CLIs that record any call. Dry run must never reach them.
mkdir -p "$tmp/bin"
for cli in gcloud docker gh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/calls"\nexit 99\n' "$cli" "$tmp" >"$tmp/bin/$cli"
  chmod +x "$tmp/bin/$cli"
done
export PATH="$tmp/bin:$PATH"

export DEPLOY_DRY_RUN=1 GCP_PROJECT_ID=test-proj-42 GCP_REGION=europe-west1 \
  APP_NAME=hello GITHUB_REPOSITORY=acme/hello BILLING_ACCOUNT=0A1B2C-3D4E5F-6A7B8C
sha=1234567abcdef0123456789abcdef0123456789

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}

# dr <target> <verb> [args...]: run the dispatcher; sets out (stdout),
# err (stderr) and rc.
dr() {
  local target="$1"
  shift
  rc=0
  out="$(DEPLOY_TARGET="$target" "$deploy" "$@" 2>"$tmp/err")" || rc=$?
  err="$(cat "$tmp/err")"
}

# has <name> <needle>: err contains needle.
has() {
  if grep -qF -- "$2" <<<"$err"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
lacks() {
  if grep -qF -- "$2" <<<"$err$out"; then fail "$1 (found: $2)"; else pass "$1"; fi
}
rc_is() {
  if [[ "$rc" == "$2" ]]; then pass "$1"; else fail "$1 (rc $rc, want $2; stderr: $err)"; fi
}
out_is() {
  if [[ "$out" == "$2" ]]; then pass "$1"; else fail "$1 (stdout [$out], want [$2])"; fi
}

# --- dispatcher
dr cloud-run frobnicate
rc_is "dispatcher: unknown verb exits 64" 64
dr nope url dev
rc_is "dispatcher: unknown target exits 64" 64
dr '../none' url
rc_is "dispatcher: path-like target exits 64" 64
rc=0
out="$(DEPLOY_CONFIG="$root/deploy.yml" "$deploy" url 2>/dev/null)" || rc=$?
rc_is "dispatcher: deploy.yml target (none) is used" 0
cfg="$tmp/deploy.yml"
printf 'target: cloud-run   # comment\n' >"$cfg"
rc=0
out="$(DEPLOY_CONFIG="$cfg" "$deploy" url dev 2>/dev/null)" || rc=$?
out_is "dispatcher: reads target from config" "https://hello-dev-dryrun.a.run.app"
printf 'smoke:\n  target: cloud-run\ntarget: none\n' >"$cfg.nested"
rc=0
out="$(DEPLOY_CONFIG="$cfg.nested" "$deploy" url dev 2>/dev/null)" || rc=$?
out_is "dispatcher: ignores an indented nested target:" ""
rc=0
out="$(DEPLOY_CONFIG="$cfg" DEPLOY_TARGET=none "$deploy" url 2>/dev/null)" || rc=$?
out_is "dispatcher: DEPLOY_TARGET overrides deploy.yml" ""

# --- none adapter: every verb is a no-op with empty stdout
for verb in bootstrap publish current deploy-dark promote revert url discard cleanup; do
  dr none "$verb" dev "$sha"
  if [[ "$rc" == 0 && -z "$out" ]]; then pass "none: $verb is a no-op"; else fail "none: $verb (rc $rc, stdout [$out])"; fi
done

# --- cloud-run
dr cloud-run bootstrap
rc_is "cloud-run bootstrap: exits 0" 0
has "bootstrap: enables run API" "run.googleapis.com"
has "bootstrap: enables billingbudgets API" "billingbudgets.googleapis.com"
has "bootstrap: creates registry" "gcloud artifacts repositories create app"
has "bootstrap: keep-5 cleanup policy" '"keepCount": 5'
has "bootstrap: untagged 7d delete policy" '"olderThan": "7d"'
has "bootstrap: tagged 30d delete policy" '{"tagState": "TAGGED", "olderThan": "30d"}'
has "bootstrap: deployed images are kept" '"tagPrefixes": ["dev", "production"]'
policy_json="$(sed -n 's/^DRY-RUN: cleanup policy: //p' <<<"$err")"
if jq -e '(.[] | select(.name == "keep-deployed") | .action.type == "Keep" and .condition.tagState == "TAGGED" and .condition.tagPrefixes == ["dev", "production"])
  and (.[] | select(.name == "delete-tagged-30d") | .action.type == "Delete" and .condition.olderThan == "30d")
  and ([.[] | select(.action.type == "Keep")] | length == 2)' >/dev/null 2>&1 <<<"$policy_json"; then
  pass "bootstrap: policy JSON parses with the keep-deployed and 30-day rules"
else
  fail "bootstrap: policy JSON (got: $policy_json)"
fi
has "bootstrap: OIDC issuer" "--issuer-uri https://token.actions.githubusercontent.com"
has "bootstrap: attribute-condition pins the repo and main" "--attribute-condition assertion.repository==\\'acme/hello\\'\\ \\&\\&\\ assertion.ref==\\'refs/heads/main\\'"
has "bootstrap: maps the ref claim" "attribute.ref=assertion.ref"
has "bootstrap: deploy SA is run.developer" "--role roles/run.developer"
has "bootstrap: registry writer is scoped to the app repository" "artifacts repositories add-iam-policy-binding app --project test-proj-42 --location europe-west1 --member serviceAccount:deployer@test-proj-42.iam.gserviceaccount.com --role roles/artifactregistry.writer"
lacks "bootstrap: no project-wide registry role" "add-iam-policy-binding test-proj-42 --member serviceAccount:deployer@test-proj-42.iam.gserviceaccount.com --role roles/artifactregistry.writer"
has "bootstrap: serviceAccountUser on runtime SA only" "add-iam-policy-binding runtime@test-proj-42.iam.gserviceaccount.com --project test-proj-42 --member serviceAccount:deployer@test-proj-42.iam.gserviceaccount.com --role roles/iam.serviceAccountUser"
has "bootstrap: WIF user bound to the repo principalSet" "attribute.repository/acme/hello --role roles/iam.workloadIdentityUser"
has "bootstrap: budget amount" "--budget-amount 10USD"
has "bootstrap: budget thresholds" "--threshold-rule percent=0.1 --threshold-rule percent=0.5 --threshold-rule percent=1.0"
has "bootstrap: services start public and idle" "--image us-docker.pkg.dev/cloudrun/container/hello --min-instances 0 --max-instances 2"
has "bootstrap: sets GCP_WIF_PROVIDER" "gh variable set GCP_WIF_PROVIDER"
has "bootstrap: sets APP_NAME" "gh variable set APP_NAME --repo acme/hello --body hello"
gcloud_lines="$(grep -c 'DRY-RUN: gcloud' <<<"$err" || true)"
if [[ "$gcloud_lines" -ge 20 ]]; then pass "bootstrap: prints its gcloud calls ($gcloud_lines)"; else fail "bootstrap: only $gcloud_lines gcloud calls"; fi
if grep -F 'gcloud' <<<"$err" | grep -v -- '--project test-proj-42' | grep -qvE 'billing budgets|projects (describe|add-iam-policy-binding) test-proj-42'; then
  fail "bootstrap: every gcloud call names the project"
else
  pass "bootstrap: every gcloud call names the project"
fi

rc=0
out="$(DEPLOY_TARGET=cloud-run GITHUB_REPOSITORY="evil/x' || true || '" "$deploy" bootstrap 2>&1)" || rc=$?
rc_is "bootstrap: rejects an unsafe repository name" 1

dr cloud-run publish "$sha"
rc_is "publish: exits 0" 0
has "publish: builds the sha image" "docker build -t europe-west1-docker.pkg.dev/test-proj-42/app/hello:$sha"
has "publish: pushes" "docker push europe-west1-docker.pkg.dev/test-proj-42/app/hello:$sha"

dr cloud-run current dev
out_is "current: prints the 100% revision" "hello-dev-00002-aaa"

dr cloud-run deploy-dark dev "$sha"
rc_is "deploy-dark: exits 0" 0
for flag in "--no-traffic" "--tag c1234567" "--max-instances 2" "--min-instances 0" \
  "--service-account runtime@test-proj-42.iam.gserviceaccount.com" "--update-env-vars APP_VERSION=$sha" \
  "--region europe-west1" "gcloud run deploy hello-dev"; do
  has "deploy-dark: $flag" "$flag"
done
lacks "deploy-dark: never replaces all env vars" "--set-env-vars"
out_is "deploy-dark: stdout is only the tag URL" "https://c1234567---hello-dev-dryrun.a.run.app"

dr cloud-run deploy-dark production "$sha"
has "deploy-dark: production service" "gcloud run deploy hello-prod"
dr cloud-run deploy-dark staging "$sha"
rc_is "deploy-dark: unknown env exits 64" 64
dr cloud-run deploy-dark dev 'abc;rm'
rc_is "deploy-dark: bad sha exits 64" 64

dr cloud-run promote production "$sha"
has "promote: resolves the tagged revision" "--to-revisions hello-prod-00009-aaa=100"
lacks "promote: never --to-latest" "--to-latest"
out_is "promote: stdout empty" ""
has "promote: keeps the serving revision's image as production-prev" "tags add europe-west1-docker.pkg.dev/test-proj-42/app/hello@sha256:0000000000000000000000000000000000000000000000000000000000000000 europe-west1-docker.pkg.dev/test-proj-42/app/hello:production-prev"
has "promote: reads the revert target from the serving revision" "revisions describe hello-prod-00002-aaa"
has "promote: tags the new image production" "tags add europe-west1-docker.pkg.dev/test-proj-42/app/hello:$sha europe-west1-docker.pkg.dev/test-proj-42/app/hello:production"
first_tag="$(grep -n 'tags add' <<<"$err" | head -n 1 | cut -d: -f1)"
traffic="$(grep -n 'update-traffic' <<<"$err" | head -n 1 | cut -d: -f1)"
if [[ -n "$first_tag" && -n "$traffic" && "$first_tag" -lt "$traffic" ]]; then pass "promote: tags before moving traffic"; else fail "promote: tag/traffic order ($first_tag, $traffic)"; fi
# A retry of the same SHA: its candidate revision already serves 100%. The
# revision reports a digest-pinned image, as gcloud does; the guard must
# still hold (it compares revisions, not image references).
export DRY_RUN_SERVING_REVISION=hello-prod-00009-aaa
dr cloud-run promote production "$sha"
lacks "promote retry: production-prev unchanged" ":production-prev"
has "promote retry: still tags production" "tags add europe-west1-docker.pkg.dev/test-proj-42/app/hello:$sha europe-west1-docker.pkg.dev/test-proj-42/app/hello:production"
unset DRY_RUN_SERVING_REVISION
# Before the first deploy the service runs Google's sample image: nothing to keep.
export DRY_RUN_REVISION_IMAGE="us-docker.pkg.dev/cloudrun/container/hello"
dr cloud-run promote production "$sha"
lacks "promote over the sample image: no production-prev" ":production-prev"
has "promote over the sample image: says why" "doesn't run an app image"
dr cloud-run revert dev hello-dev-00002-aaa
lacks "revert to the sample image: not tagged" "tags add us-docker.pkg.dev"
unset DRY_RUN_REVISION_IMAGE

dr cloud-run revert dev hello-dev-00002-aaa
has "revert: targets the revision" "--to-revisions hello-dev-00002-aaa=100"
has "revert: re-tags the restored (digest-pinned) image as dev" "tags add europe-west1-docker.pkg.dev/test-proj-42/app/hello@sha256:0000000000000000000000000000000000000000000000000000000000000000 europe-west1-docker.pkg.dev/test-proj-42/app/hello:dev"
# Real mode: if reading the restored revision fails after traffic moved, the
# revert still succeeds (it only reports the missing tag).
mkdir -p "$tmp/bin2"
cat >"$tmp/bin2/gcloud" <<'EOF2'
#!/usr/bin/env bash
case "$*" in
  "run revisions describe"*) exit 1 ;;
esac
exit 0
EOF2
chmod +x "$tmp/bin2/gcloud"
rc=0
out="$(PATH="$tmp/bin2:$PATH" DEPLOY_DRY_RUN=0 DEPLOY_TARGET=cloud-run "$deploy" revert dev hello-dev-00002-aaa 2>&1)" || rc=$?
rc_is "revert: a failed image lookup after moving traffic doesn't fail the revert" 0
if grep -q "not tagged" <<<"$out"; then pass "revert: says the image wasn't tagged"; else fail "revert: no message ($out)"; fi
dr cloud-run revert dev 'x=1,y'
rc_is "revert: bad revision exits 64" 64

dr cloud-run url production
out_is "url: prints status.url" "https://hello-prod-dryrun.a.run.app"

dr cloud-run discard dev "$sha"
has "discard: removes the candidate tag" "--remove-tags c1234567"

dr cloud-run cleanup dev
rc_is "cleanup: exits 0" 0
has "cleanup: removes tags at 0%" "--remove-tags c0000000"
has "cleanup: deletes old revision 4" "revisions delete hello-dev-00004-aaa"
has "cleanup: deletes old revision 1" "revisions delete hello-dev-00001-aaa"
lacks "cleanup: keeps the newest 5" "revisions delete hello-dev-00005-aaa"
lacks "cleanup: keeps the serving revision" "revisions delete hello-dev-00002-aaa"
deleted="$(grep -c 'revisions delete' <<<"$err" || true)"
if [[ "$deleted" == 3 ]]; then pass "cleanup: deletes exactly 3"; else fail "cleanup: deleted $deleted, want 3"; fi

# Every verb works with no variables at all (placeholders in dry run).
rc=0
env -u GCP_PROJECT_ID -u APP_NAME -u GITHUB_REPOSITORY -u BILLING_ACCOUNT -u GCP_REGION \
  DEPLOY_TARGET=cloud-run "$deploy" bootstrap >/dev/null 2>&1 || rc=$?
rc_is "cloud-run: bootstrap runs with no variables in dry run" 0
rc=0
env -u GCP_PROJECT_ID -u APP_NAME DEPLOY_DRY_RUN=0 DEPLOY_TARGET=cloud-run "$deploy" url dev >/dev/null 2>&1 || rc=$?
rc_is "cloud-run: missing variables fail outside dry run" 1

if [[ -s "$tmp/calls" ]]; then
  fail "dry run never calls a real CLI (called: $(tr '\n' ';' <"$tmp/calls"))"
else
  pass "dry run never calls a real CLI"
fi

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
