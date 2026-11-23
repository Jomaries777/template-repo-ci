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
# Never read the repo's own deploy.yml: a bootstrapped project has its own.
printf 'target: none\n' >"$tmp/plain.yml"
export DEPLOY_CONFIG="$tmp/plain.yml"
# A bootstrapped project keeps one adapter; test the ones that are installed.
have_none=0 have_cr=0
[[ -d "$root/deploy/targets/none" ]] && have_none=1
[[ -d "$root/deploy/targets/cloud-run" ]] && have_cr=1
have_local=0
[[ -d "$root/deploy/targets/local" ]] && have_local=1

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
# `preview` (C9) is a contract verb, only for adapters without a dark deploy:
# an adapter that lacks it is a missing verb, not an unknown one.
dr cloud-run preview production 1234567
lacks "dispatcher: preview is a known verb" "unknown verb"
dr nope url dev
rc_is "dispatcher: unknown target exits 64" 64
dr '../none' url
rc_is "dispatcher: path-like target exits 64" 64
cfg="$tmp/deploy.yml"
if ((have_none)); then
  rc=0
  out="$(DEPLOY_CONFIG="$tmp/plain.yml" "$deploy" url 2>/dev/null)" || rc=$?
  rc_is "dispatcher: deploy.yml target (none) is used" 0
  rc=0
  out="$(DEPLOY_CONFIG="$cfg" DEPLOY_TARGET=none "$deploy" url 2>/dev/null)" || rc=$?
  out_is "dispatcher: DEPLOY_TARGET overrides deploy.yml" ""
fi
if ((have_cr)); then
printf 'target: cloud-run   # comment\n' >"$cfg"
rc=0
out="$(DEPLOY_CONFIG="$cfg" "$deploy" url dev 2>/dev/null)" || rc=$?
out_is "dispatcher: reads target from config" "https://hello-dev-dryrun.a.run.app"
  printf 'smoke:\n  target: cloud-run\ntarget: nope\n' >"$cfg.nested"
  rc=0
  DEPLOY_CONFIG="$cfg.nested" "$deploy" url dev >/dev/null 2>&1 || rc=$?
  rc_is "dispatcher: ignores an indented nested target:" 64
fi

# --- none adapter: every verb is a no-op with empty stdout
for verb in bootstrap publish current deploy-dark promote revert url discard cleanup; do
  ((have_none)) || break
  dr none "$verb" dev "$sha"
  if [[ "$rc" == 0 && -z "$out" ]]; then pass "none: $verb is a no-op"; else fail "none: $verb (rc $rc, stdout [$out])"; fi
done

# --- cloud-run (the block below runs only when the adapter is installed;
# it is left unindented to keep the diff readable)
if ((have_cr)); then
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
# promote moves the "<env>" tag, and moving an existing tag removes it first:
# that takes artifactregistry.tags.delete, which writer lacks (M2 step 6b).
has "bootstrap: registry repoAdmin is scoped to the app repository" "artifacts repositories add-iam-policy-binding app --project test-proj-42 --location europe-west1 --member serviceAccount:deployer@test-proj-42.iam.gserviceaccount.com --role roles/artifactregistry.repoAdmin"
lacks "bootstrap: no project-wide registry role" "add-iam-policy-binding test-proj-42 --member serviceAccount:deployer@test-proj-42.iam.gserviceaccount.com --role roles/artifactregistry."
lacks "bootstrap: no registry admin (it could change the repository's IAM)" "roles/artifactregistry.admin"
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
has "publish: builds from . without a stack" "hello:$sha ."
printf 'target: cloud-run\nstack: node\n' >"$tmp/stack.yml"
rc=0
out="$(DEPLOY_CONFIG="$tmp/stack.yml" "$deploy" publish "$sha" 2>&1)" || rc=$?
if grep -qF "hello:$sha $root/stacks/node" <<<"$out"; then pass "publish: builds from stacks/<stack> when deploy.yml names one"; else fail "publish: stack context (got: $out)"; fi
printf 'target: cloud-run\nstack: ../etc\n' >"$tmp/badstack.yml"
rc=0
DEPLOY_CONFIG="$tmp/badstack.yml" "$deploy" publish "$sha" >/dev/null 2>&1 || rc=$?
rc_is "publish: invalid stack exits 64" 64

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

fi # have_cr

# --- local (test-only target: Docker containers on the job's machine)
if ((have_local)); then
  printf 'target: local\nstack: node\n' >"$tmp/local.yml"
  export DEPLOY_CONFIG="$tmp/local.yml"
  dr local current dev
  out_is "local current: prints the serving revision" "hello-dev-c0000000"
  dr local deploy-dark dev "$sha"
  rc_is "local deploy-dark: exits 0" 0
  has "local deploy-dark: builds the candidate" "docker build -q -t local/hello-dev-c1234567"
  has "local deploy-dark: runs it on localhost only" "-p 127.0.0.1:18080:8080"
  has "local deploy-dark: sets APP_VERSION" "-e APP_VERSION=$sha"
  out_is "local deploy-dark: stdout is only the candidate URL" "http://127.0.0.1:18080"
  dr local promote production "$sha"
  has "local promote: points live at the candidate" "live <- hello-production-c1234567"
  dr local revert dev hello-dev-c0000000
  has "local revert: points live back" "live <- hello-dev-c0000000"
  dr local url dev
  out_is "local url: the serving container's port" "http://127.0.0.1:18080"
  dr local discard dev "$sha"
  has "local discard: removes the candidate" "docker rm -f hello-dev-c1234567"
  dr local cleanup dev
  has "local cleanup: removes other revisions" "docker rm -f hello-dev-c1111111"
  lacks "local cleanup: keeps the serving one" "docker rm -f hello-dev-c0000000"
  dr local publish "$sha"
  rc_is "local publish: nothing to push" 0
  dr local deploy-dark staging "$sha"
  rc_is "local: unknown env exits 64" 64
  export DEPLOY_CONFIG="$tmp/plain.yml"

  # start_rev outside dry run, against a fake docker and curl: it removes a
  # same-named container only if `docker container inspect` finds one.
  mkdir -p "$tmp/real-bin" "$tmp/real-state"
  # shellcheck disable=SC2016 # expanded by the fake docker, not here
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "docker $*" >>"$FAKE_DOCKER_LOG"' \
    '[[ "$1 $2" == "container inspect" ]] && exit "${FAKE_INSPECT_RC:-1}"' \
    'exit 0' >"$tmp/real-bin/docker"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/real-bin/curl"
  chmod +x "$tmp/real-bin/docker" "$tmp/real-bin/curl"
  # start_with_inspect_rc <rc>: run start_rev once; prints the docker calls.
  start_with_inspect_rc() {
    : >"$tmp/docker.log"
    (
      # shellcheck disable=SC2030 # local to this subshell on purpose
      export PATH="$tmp/real-bin:$PATH" FAKE_DOCKER_LOG="$tmp/docker.log" FAKE_INSPECT_RC="$1"
      unset DEPLOY_DRY_RUN
      # shellcheck source=deploy/targets/local/lib.sh disable=SC1091
      source "$root/deploy/targets/local/lib.sh"
      # shellcheck disable=SC2034 # read by start_rev from lib.sh
      STATE="$tmp/real-state"
      start_rev hello-dev-c1234567 "$tmp" 1234567
    ) >/dev/null 2>&1 || echo "start_rev failed"
    cat "$tmp/docker.log"
  }
  calls_seen="$(start_with_inspect_rc 1)"
  if grep -q '^docker rm ' <<<"$calls_seen"; then
    fail "local start_rev: no leftover container, no docker rm"
  else
    pass "local start_rev: no leftover container, no docker rm"
  fi
  if grep -q '^docker run -d --name hello-dev-c1234567' <<<"$calls_seen"; then
    pass "local start_rev: starts the container"
  else
    fail "local start_rev: starts the container (calls: $calls_seen)"
  fi
  calls_seen="$(start_with_inspect_rc 0)"
  if grep -q '^docker rm -f hello-dev-c1234567' <<<"$calls_seen"; then
    pass "local start_rev: removes a leftover container first"
  else
    fail "local start_rev: removes a leftover container first (calls: $calls_seen)"
  fi
fi

if [[ -s "$tmp/calls" ]]; then
  fail "dry run never calls a real CLI (called: $(tr '\n' ';' <"$tmp/calls"))"
else
  pass "dry run never calls a real CLI"
fi

# --- github-pages (M3, C9): dry run of every verb, then a real promote and
# revert against a local bare repository with a fake gh.
# shellcheck disable=SC2031 # $root is the script's own; the subshell above only sources a lib
if [[ -d "$root/deploy/targets/github-pages" ]]; then
  for v in "url production" "current production" "publish 1234567" "preview production 1234567" \
    "discard production 1234567" "promote production 1234567" "revert production abcdef1" "cleanup production" bootstrap; do
    # shellcheck disable=SC2086 # split on purpose
    DEPLOY_DRY_RUN=1 GITHUB_REPOSITORY=acme/site dr github-pages $v
    rc_is "github-pages dry run: $v" 0
  done
  DEPLOY_DRY_RUN=1 GITHUB_REPOSITORY=acme/site dr github-pages url dev
  rc_is "github-pages: dev is refused (one site)" 64
  DEPLOY_DRY_RUN=1 GITHUB_REPOSITORY=acme/site dr github-pages deploy-dark production 1234567
  rc_is "github-pages: deploy-dark is refused (C9)" 64
  DEPLOY_DRY_RUN=1 GITHUB_REPOSITORY=acme/site dr github-pages bootstrap
  has "github-pages bootstrap: creates gh-pages" "git/refs -f ref=refs/heads/gh-pages"
  has "github-pages bootstrap: serves Pages from gh-pages" "source\[branch\]=gh-pages"
  # Creating gh-pages makes GitHub turn Pages on by itself a moment later, so
  # the "is Pages on?" check can say no and the POST then answers 409.
  # Bootstrap must take that as "already on" and set the source with PUT.
  race="$tmp/race"
  mkdir -p "$race"
  cat >"$race/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >>"$race/calls"
case "\$*" in
  "auth status"*) exit 0 ;;
  *"git/trees"* | *"git/commits"*) echo 4444444444444444444444444444444444444444 ;;
  *"git/refs"*) exit 0 ;;
  *"-X POST repos/acme/site/pages "*) echo "gh: GitHub Pages is already enabled. (HTTP 409)" >&2; exit 1 ;;
  *"-X PUT repos/acme/site/pages "*) exit 0 ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
EOF
  chmod +x "$race/gh"
  printf 'target: github-pages\nstack: node\n' >"$race/deploy.yml"
  rc=0
  (cd "$tmp" && PATH="$race:$PATH" DEPLOY_DRY_RUN=0 DEPLOY_CONFIG="$race/deploy.yml" GITHUB_REPOSITORY=acme/site RUNNER_TEMP="$race" \
    "$root/deploy/targets/github-pages/bootstrap") >/dev/null 2>"$tmp/err" || rc=$?
  err="$(cat "$tmp/err")"
  rc_is "github-pages bootstrap: Pages turned on by GitHub meanwhile (409) is not an error" 0
  if grep -q -- '-X PUT repos/acme/site/pages ' "$race/calls"; then pass "github-pages bootstrap: after a 409 it sets the source with PUT"; else fail "github-pages bootstrap: no PUT after 409 ($(tr '\n' ';' <"$race/calls"))"; fi
  if grep -qx 'dark_deploy: false' "$root/deploy/targets/github-pages/target.yml"; then pass "github-pages: target.yml declares no dark deploy"; else fail "github-pages: target.yml dark_deploy"; fi

  # A throwaway project: the adapter, a fake stack whose build-static writes
  # the version, and a bare repository standing in for GitHub.
  gp="$tmp/gp"
  mkdir -p "$gp/deploy/targets" "$gp/stacks/fake" "$gp/bin"
  cp -R "$root/deploy/targets/github-pages" "$gp/deploy/targets/"
  printf 'target: github-pages\nstack: fake\n' >"$gp/deploy.yml"
  # shellcheck disable=SC2016 # $$APP_VERSION is for make, not this shell
  printf 'build-static:\n\tmkdir -p dist/static/health\n\techo "v=$$APP_VERSION" >dist/static/index.html\n\techo ok >dist/static/health/index.html\n' >"$gp/stacks/fake/Makefile"
  git -C "$gp" init -q && git -C "$gp" add -A && git -C "$gp" -c user.email=t@t -c user.name=t commit -qm src
  src_sha="$(git -C "$gp" rev-parse HEAD)"
  git init -q --bare "$tmp/gp.git"
  seed="$tmp/gp-seed"
  git init -q "$seed" && touch "$seed/.nojekyll" && git -C "$seed" add -A &&
    git -C "$seed" -c user.email=t@t -c user.name=t commit -qm seed && git -C "$seed" push -q "$tmp/gp.git" HEAD:refs/heads/gh-pages
  first="$(git -C "$tmp/gp.git" rev-parse gh-pages)"
  cat >"$gp/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >>"$tmp/gp.calls"
head="\$(git -C "$tmp/gp.git" rev-parse gh-pages)"
case "\$*" in
  *"pages/builds/latest"*) printf '{"status":"built","commit":"%s"}\n' "\$head" ;;
  *"branches/gh-pages"*) echo "\$head" ;;
esac
EOF
  chmod +x "$gp/bin/gh"
  gpdeploy() { # gpdeploy <verb> <args...>: a verb of the copied adapter, for real
    rc=0
    out="$(cd "$gp" && PATH="$gp/bin:$PATH" DEPLOY_DRY_RUN=0 DEPLOY_CONFIG="$gp/deploy.yml" GITHUB_REPOSITORY=acme/site PAGES_REMOTE="file://$tmp/gp.git" \
      RUNNER_TEMP="$tmp/gp-run" PAGES_WAIT_SECONDS=5 "$gp/deploy/targets/github-pages/$1" "${@:2}" 2>"$tmp/err")" || rc=$?
    err="$(cat "$tmp/err")"
  }
  mkdir -p "$tmp/gp-run"
  gpdeploy current production
  out_is "github-pages: current is the gh-pages commit" "$first"
  gpdeploy promote production "$src_sha"
  rc_is "github-pages: promote exits 0" 0
  deployed="$(git -C "$tmp/gp.git" rev-parse gh-pages)"
  if [[ "$(git -C "$tmp/gp.git" show gh-pages:index.html)" == "v=$src_sha" ]]; then pass "github-pages: promote publishes the export of the deployed commit"; else fail "github-pages: promoted index.html"; fi
  if git -C "$tmp/gp.git" cat-file -e gh-pages:.nojekyll 2>/dev/null; then pass "github-pages: keeps .nojekyll"; else fail "github-pages: .nojekyll"; fi
  if [[ "$(git -C "$tmp/gp.git" rev-parse "$deployed~1")" == "$first" ]]; then pass "github-pages: promote is a fast-forward (no force push)"; else fail "github-pages: promote history"; fi
  if grep -q "pages/builds" "$tmp/gp.calls"; then pass "github-pages: promote asks Pages to build and waits"; else fail "github-pages: no Pages build request"; fi
  gpdeploy revert production "$first"
  rc_is "github-pages: revert exits 0" 0
  if ! git -C "$tmp/gp.git" cat-file -e gh-pages:index.html 2>/dev/null; then pass "github-pages: revert restores the earlier files"; else fail "github-pages: revert left index.html"; fi
  if [[ "$(git -C "$tmp/gp.git" rev-parse gh-pages~1)" == "$deployed" ]]; then pass "github-pages: revert is a new commit (history kept)"; else fail "github-pages: revert history"; fi
  git -C "$gp" -c user.email=t@t -c user.name=t commit -q --allow-empty -m other
  gpdeploy promote production "$src_sha"
  rc_is "github-pages: refuses to export a commit other than the checkout" 1
fi

# --- cloudflare-workers (M3 step 4, C10): dry run of every verb, then the
# real code paths against a fake wrangler that records its calls.
# shellcheck disable=SC2031 # $root is the script's own; the subshell above only sources a lib
if [[ -d "$root/deploy/targets/cloudflare-workers" ]]; then
  cf_env=(CLOUDFLARE_ACCOUNT_ID=0123456789abcdef0123456789abcdef CLOUDFLARE_WORKERS_SUBDOMAIN=acme APP_NAME=hello)
  prev_id=11111111-1111-4111-8111-111111111111
  for v in bootstrap "publish $sha" "current dev" "deploy-dark dev $sha" "promote production $sha" \
    "revert production $prev_id" "url production" "discard dev $sha" "cleanup production"; do
    rc=0
    # shellcheck disable=SC2086 # split on purpose
    out="$(env "${cf_env[@]}" DEPLOY_TARGET=cloudflare-workers "$deploy" $v 2>"$tmp/err")" || rc=$?
    err="$(cat "$tmp/err")"
    rc_is "cloudflare-workers dry run: $v" 0
  done
  cfdr() { env "${cf_env[@]}" DEPLOY_TARGET=cloudflare-workers "$@"; }
  rc=0; out="$(cfdr "$deploy" url production 2>"$tmp/err")" || rc=$?; err="$(cat "$tmp/err")"
  out_is "cloudflare-workers: production URL is <app>.<subdomain>.workers.dev" "https://hello.acme.workers.dev"
  rc=0; out="$(cfdr "$deploy" url dev 2>"$tmp/err")" || rc=$?; err="$(cat "$tmp/err")"
  out_is "cloudflare-workers: dev is a separate Worker, <app>-dev" "https://hello-dev.acme.workers.dev"
  rc=0; out="$(cfdr "$deploy" url staging 2>"$tmp/err")" || rc=$?; err="$(cat "$tmp/err")"
  rc_is "cloudflare-workers: unknown environment exits 64" 64
  rc=0; out="$(cfdr "$deploy" revert production 'abc; rm -rf /' 2>"$tmp/err")" || rc=$?; err="$(cat "$tmp/err")"
  rc_is "cloudflare-workers: revert refuses a malformed version ID" 64
  rc=0; out="$(cfdr APP_NAME=Bad_Name "$deploy" url production 2>"$tmp/err")" || rc=$?; err="$(cat "$tmp/err")"
  rc_is "cloudflare-workers: invalid APP_NAME is refused" 1
  rc=0; out="$(cfdr "$deploy" bootstrap 2>"$tmp/err")" || rc=$?; err="$(cat "$tmp/err")"
  has "cloudflare-workers bootstrap: placeholder per Worker" "deploy --name hello-dev"
  has "cloudflare-workers bootstrap: token is an Environment secret (dev)" "secret set CLOUDFLARE_API_TOKEN --env dev"
  has "cloudflare-workers bootstrap: token is an Environment secret (production)" "secret set CLOUDFLARE_API_TOKEN --env production"
  lacks "cloudflare-workers bootstrap: token is never a repo-wide secret" "secret set CLOUDFLARE_API_TOKEN --repo"
  has "cloudflare-workers bootstrap: records when the token was set" "gh variable set CLOUDFLARE_API_TOKEN_SET_AT --repo acme/hello --body"
  if grep -qx 'dark_deploy: true' "$root/deploy/targets/cloudflare-workers/target.yml"; then pass "cloudflare-workers: target.yml declares a dark deploy"; else fail "cloudflare-workers: target.yml dark_deploy"; fi

  # Fake wrangler: answers from files in $cfw, records every call.
  cfw="$tmp/cfw"
  mkdir -p "$cfw"
  cat >"$cfw/wrangler" <<'FAKE'
#!/usr/bin/env bash
d="$(dirname "$0")"
echo "$* TOKEN=${CLOUDFLARE_API_TOKEN:-}" >>"$d/calls"
case "$1 $2" in
  "deployments status") cat "$d/status.json" ;;
  "versions list")
    # versions.lag: Cloudflare doesn't list a new version yet (seen live,
    # 2026-11-23): the first list after an upload comes back without it.
    if [[ -f "$d/versions.lag" ]]; then rm "$d/versions.lag"; echo '[]'; else cat "$d/versions.json"; fi ;;
  "versions upload")
    echo "uploading" >&2
    [[ -f "$d/upload.json" ]] && cat "$d/upload.json" >>"$WRANGLER_OUTPUT_FILE_PATH" ;;
esac
exit 0
FAKE
  chmod +x "$cfw/wrangler"
  # Fake curl for promote's wait on the live URL: answers /health with the
  # first line of health.seq (consumed), else a version that never matches.
  mkdir -p "$cfw/pbin"
  cat >"$cfw/pbin/curl" <<'FAKE'
#!/usr/bin/env bash
d="$(dirname "$0")/.."
echo "curl $*" >>"$d/calls"
if [[ -s "$d/health.seq" ]]; then head -n 1 "$d/health.seq"; sed -i.bak 1d "$d/health.seq"; else echo '{"status": "ok", "version": "other"}'; fi
FAKE
  chmod +x "$cfw/pbin/curl"
  cfreal() {
    rc=0
    : >"$cfw/calls"
    out="$(env -u DEPLOY_DRY_RUN "${cf_env[@]}" WRANGLER_BIN="$cfw/wrangler" CLOUDFLARE_API_TOKEN=s3cr3t-token CF_TAG_LOOKUP_INTERVAL=0 CF_SERVING_INTERVAL=0 PATH="$cfw/pbin:$PATH" \
      DEPLOY_BUILD_CONTEXT="$root/stacks/node" "$root/deploy/targets/cloudflare-workers/$1" "${@:2}" 2>"$tmp/err")" || rc=$?
    err="$(cat "$tmp/err")"
  }
  printf '{"versions": [{"version_id": "%s", "percentage": 100}]}' "$prev_id" >"$cfw/status.json"
  cfreal current production
  out_is "cloudflare-workers: current is the version serving 100%" "$prev_id"
  printf '{"versions": [{"version_id": "%s", "percentage": 90}, {"version_id": "x", "percentage": 10}]}' "$prev_id" >"$cfw/status.json"
  cfreal current production
  rc_is "cloudflare-workers: current refuses a traffic split" 1

  printf '%s\n' '{"type": "wrangler-session", "version": 1}' \
    '{"type": "version-upload", "version": 1, "version_id": "33333333-3333-4333-8333-333333333333", "preview_url": "https://33333333-hello-dev.acme.workers.dev"}' >"$cfw/upload.json"
  cfreal deploy-dark dev "$sha"
  out_is "cloudflare-workers: deploy-dark prints the preview URL from wrangler's output file" "https://33333333-hello-dev.acme.workers.dev"
  if grep -q "versions upload --name hello-dev .*--tag c1234567 .*--var APP_VERSION:$sha" "$cfw/calls"; then pass "cloudflare-workers: upload is tagged c<sha7> and carries APP_VERSION"; else fail "cloudflare-workers: upload args ($(cat "$cfw/calls"))"; fi
  lacks "cloudflare-workers: token never reaches stdout or stderr" "s3cr3t-token"
  if grep -q "TOKEN=s3cr3t-token" "$cfw/calls"; then pass "cloudflare-workers: wrangler gets the token from the environment"; else fail "cloudflare-workers: token not passed to wrangler"; fi
  if grep -q -- "s3cr3t-token " "$cfw/calls"; then fail "cloudflare-workers: token passed as an argument"; else pass "cloudflare-workers: token is never a command-line argument"; fi
  printf '%s\n' '{"type": "version-upload", "version": 1, "version_id": "33333333-3333-4333-8333-333333333333", "preview_url": null}' >"$cfw/upload.json"
  cfreal deploy-dark dev "$sha"
  rc_is "cloudflare-workers: deploy-dark fails without a preview URL (so release.sh discards)" 1

  cat >"$cfw/versions.json" <<JSON
[{"id": "44444444-4444-4444-8444-444444444444", "metadata": {"created_on": "2026-11-01T00:00:00Z"}, "annotations": {"workers/tag": "c1234567"}},
 {"id": "55555555-5555-4555-8555-555555555555", "metadata": {"created_on": "2026-11-02T00:00:00Z"}, "annotations": {"workers/tag": "c1234567"}},
 {"id": "$prev_id", "metadata": {"created_on": "2026-11-03T00:00:00Z"}, "annotations": {"workers/tag": "cfffffff"}}]
JSON
  cfreal promote production "$sha"
  rc_is "cloudflare-workers: promote" 0
  if grep -q "versions deploy 55555555-5555-4555-8555-555555555555@100% --name hello " "$cfw/calls"; then pass "cloudflare-workers: promote deploys the newest version with the tag at 100%"; else fail "cloudflare-workers: promote args ($(cat "$cfw/calls"))"; fi
  printf '%s\n' '{"status": "ok", "version": "old"}' "{\"status\": \"ok\", \"version\": \"$sha\"}" >"$cfw/health.seq"
  cfreal promote production "$sha"
  rc_is "cloudflare-workers: promote waits for the live URL to serve the new version" 0
  if [[ "$(grep -c '^curl .*https://hello.acme.workers.dev/health' "$cfw/calls")" == 2 ]]; then pass "cloudflare-workers: promote polls /health until it reports the sha"; else fail "cloudflare-workers: /health polls ($(cat "$cfw/calls"))"; fi
  if [[ "$(grep -n '^versions deploy' "$cfw/calls" | cut -d: -f1)" -lt "$(grep -n '^curl' "$cfw/calls" | head -n 1 | cut -d: -f1)" ]]; then pass "cloudflare-workers: promote waits only after the deploy"; else fail "cloudflare-workers: wait order ($(cat "$cfw/calls"))"; fi
  has_err() { if grep -q -- "$2" <<<"$err"; then pass "$1"; else fail "$1 (stderr: $err)"; fi; }
  has_err "cloudflare-workers: promote says the new version is live" "serves $sha"
  rm -f "$cfw/health.seq"
  cfreal promote production "$sha"
  rc_is "cloudflare-workers: promote leaves an unconfirmed switch to the live check" 0
  has_err "cloudflare-workers: promote warns when the switch is not confirmed" "did not report version $sha"
  if [[ "$(grep -c '^curl' "$cfw/calls")" == 12 ]]; then pass "cloudflare-workers: promote stops polling after 12 tries"; else fail "cloudflare-workers: /health polls before giving up ($(grep -c '^curl' "$cfw/calls"))"; fi
  touch "$cfw/versions.lag"
  cfreal promote production "$sha"
  rc_is "cloudflare-workers: promote waits for a just-uploaded version to be listed" 0
  if grep -q "versions deploy 55555555-5555-4555-8555-555555555555@100% --name hello " "$cfw/calls"; then pass "cloudflare-workers: promote deploys the version once it is listed"; else fail "cloudflare-workers: promote after lag ($(cat "$cfw/calls"))"; fi
  cfreal promote production abcdef1
  rc_is "cloudflare-workers: promote fails when no version has the tag" 1
  if grep -q "versions deploy" "$cfw/calls"; then fail "cloudflare-workers: promote deployed without a tagged version"; else pass "cloudflare-workers: no deploy without a tagged version"; fi
  if [[ "$(grep -c '^versions list' "$cfw/calls")" == 7 ]]; then pass "cloudflare-workers: promote gives up after 7 lookups"; else fail "cloudflare-workers: lookups before giving up ($(grep -c '^versions list' "$cfw/calls"))"; fi
  cfreal revert production "$prev_id"
  if grep -q "^rollback $prev_id --name hello .*--yes" "$cfw/calls"; then pass "cloudflare-workers: revert rolls back to the given version without prompting"; else fail "cloudflare-workers: revert args ($(cat "$cfw/calls"))"; fi

  # bootstrap, for real: only a 404 from the API deploys the placeholder; a
  # Worker that exists is left alone, and any other answer deploys nothing.
  mkdir -p "$cfw/bin"
  cat >"$cfw/bin/curl" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *" -w "*) echo -n "$CF_SCRIPT_CODE" ;;
  *) echo '{"success": true, "result": {"subdomain": "acme"}}' ;;
esac
FAKE
  # shellcheck disable=SC2016 # $* and $1 belong to the generated script
  printf '#!/usr/bin/env bash\necho "gh $*" >>"%s/calls"\n[[ "$1 $2" != "secret set" ]] || cat >/dev/null\nexit 0\n' "$cfw" >"$cfw/bin/gh"
  chmod +x "$cfw/bin/curl" "$cfw/bin/gh"
  cfboot() {
    rc=0
    : >"$cfw/calls"
    out="$(env -u DEPLOY_DRY_RUN "${cf_env[@]}" PATH="$cfw/bin:$PATH" WRANGLER_BIN="$cfw/wrangler" \
      CLOUDFLARE_API_TOKEN=s3cr3t-token CF_SCRIPT_CODE="$1" GITHUB_REPOSITORY=acme/hello \
      "$root/deploy/targets/cloudflare-workers/bootstrap" 2>"$tmp/err")" || rc=$?
    err="$(cat "$tmp/err")"
  }
  cfboot 404
  rc_is "cloudflare-workers bootstrap: new account" 0
  if [[ "$(grep -c '^deploy --name hello' "$cfw/calls")" == 2 ]]; then pass "cloudflare-workers bootstrap: a 404 deploys the placeholder to both Workers"; else fail "cloudflare-workers bootstrap: placeholder deploys ($(cat "$cfw/calls"))"; fi
  if grep -q "secret set CLOUDFLARE_API_TOKEN --env production --repo acme/hello" "$cfw/calls"; then pass "cloudflare-workers bootstrap: sets the Environment secret"; else fail "cloudflare-workers bootstrap: no Environment secret ($(cat "$cfw/calls"))"; fi
  cfboot 200
  rc_is "cloudflare-workers bootstrap: rerun" 0
  if grep -q '^deploy ' "$cfw/calls"; then fail "cloudflare-workers bootstrap: rerun replaced an existing Worker"; else pass "cloudflare-workers bootstrap: rerun leaves existing Workers alone"; fi
  for code in 401 500 000; do
    cfboot "$code"
    rc_is "cloudflare-workers bootstrap: HTTP $code stops" 1
    if grep -q '^deploy ' "$cfw/calls"; then fail "cloudflare-workers bootstrap: HTTP $code deployed the placeholder"; else pass "cloudflare-workers bootstrap: HTTP $code deploys nothing"; fi
  done
  lacks "cloudflare-workers bootstrap: token never reaches stdout or stderr" "s3cr3t-token"
fi

[[ "$failures" -eq 0 ]] || {
  echo "$failures failure(s)"
  exit 1
}
