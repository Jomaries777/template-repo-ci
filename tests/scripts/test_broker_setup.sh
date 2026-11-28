#!/usr/bin/env bash
# broker/setup.sh in DRY_RUN=1 (spec 0004 FR-6, criterion 9). gcloud and curl
# are stubs that fail, so nothing real runs.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
script="$root/broker/setup.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
for t in gcloud gsutil bq curl; do
  printf '#!/usr/bin/env bash\necho "real %s called" >&2\nexit 99\n' "$t" >"$tmp/bin/$t"
  chmod +x "$tmp/bin/$t"
done
P="agent-bot-broker-t1"

ok() { echo "ok - $1"; }
nok() {
  echo "not ok - $1"
  fail=1
}
# go <env...>: run setup.sh dry, output in $out, exit code in $rc.
go() {
  rc=0
  out="$(env PATH="$tmp/bin:$PATH" DRY_RUN=1 BROKER_PROJECT="$P" "$@" "$script" 2>&1)" || rc=$?
}
has() { if grep -qF -- "$2" <<<"$out"; then ok "$1"; else nok "$1 (missing: $2)"; fi; }

go
if [[ "$rc" == 0 ]]; then ok "setup: dry run exits 0"; else nok "setup: dry run exits 0 (rc $rc): $out"; fi
if grep -q 'real .* called' <<<"$out"; then nok "setup: no real tool runs"; else ok "setup: no real tool runs"; fi
lines="$(grep '^DRY-RUN: gcloud' <<<"$out")"
n="$(grep -c . <<<"$lines")"
if ((n >= 25)); then ok "setup: prints its gcloud commands ($n)"; else nok "setup: prints its gcloud commands ($n)"; fi
missing="$(grep -v -- "--project $P" <<<"$lines" || true)"
if [[ -z "$missing" ]]; then ok "setup: every gcloud line passes --project"; else nok "setup: every gcloud line passes --project: $missing"; fi
regional="$(grep -E 'firestore databases create|artifacts repositories' <<<"$lines")"
if [[ -n "$regional" ]] && ! grep -v -E -- '--location us-west1' <<<"$regional" | grep -q .; then
  ok "setup: every regional line uses us-west1"
else
  nok "setup: every regional line uses us-west1"
fi
has "setup: enables the APIs" "secretmanager.googleapis.com firestore.googleapis.com"
has "setup: creates broker@" "service-accounts create broker"
has "setup: creates builder@" "service-accounts create builder"
has "setup: builder@ gets run.builder" "--member serviceAccount:builder@$P.iam.gserviceaccount.com --role roles/run.builder"
has "setup: broker@ gets datastore.user" "--member serviceAccount:broker@$P.iam.gserviceaccount.com --role roles/datastore.user"
has "setup: removes Editor from the default compute account" "remove-iam-policy-binding $P --project $P --member serviceAccount:123456789012-compute@developer.gserviceaccount.com --role roles/editor"
for s in claude-key agy-key ci-key login-client-secret; do
  has "setup: creates secret $s" "secrets create $s --project $P --replication-policy automatic"
  has "setup: broker@ reads $s, on the secret" "secrets add-iam-policy-binding $s --project $P --member serviceAccount:broker@$P.iam.gserviceaccount.com --role roles/secretmanager.secretAccessor"
done
if grep -E 'secretAccessor' <<<"$lines" | grep -q 'projects add-iam-policy-binding'; then
  nok "setup: no project-wide secretAccessor"
else
  ok "setup: no project-wide secretAccessor"
fi
has "setup: Firestore Native in us-west1" "firestore databases create --database \(default\) --location us-west1 --type firestore-native"
has "setup: composite index on audit" "--field-config field-path=caller_id\\,order=ascending --field-config field-path=endpoint\\,order=ascending --field-config field-path=ts\\,order=ascending"
if grep -qi 'ttl' <<<"$lines"; then nok "setup: no TTL policy"; else ok "setup: no TTL policy"; fi
has "setup: AR cleanup policy" "artifacts repositories set-cleanup-policies cloud-run-source-deploy --location us-west1"
has "setup: secret reads are audited" "projects set-iam-policy $P"
has "setup: \$1 budget on the project" "--budget-amount 1USD --filter-projects projects/$P --threshold-rule percent=0.5 --threshold-rule percent=0.9 --threshold-rule percent=1.0"

# Second run, everything there already: no create.
go BROKER_FIXTURE_EDITOR= BROKER_FIXTURE_INDEX=x BROKER_FIXTURE_BUDGET=x
if grep -q 'budgets create\|indexes composite create\|remove-iam-policy-binding' <<<"$out"; then
  nok "setup: idempotent (no budget, index or Editor change when present)"
else
  ok "setup: idempotent (no budget, index or Editor change when present)"
fi

# Region override.
go BROKER_REGION=europe-west1
has "setup: BROKER_REGION overrides the region" "--location europe-west1"

# Refusals.
refuse() { # name want-text env...
  local name="$1" want="$2"
  shift 2
  go "$@"
  if [[ "$rc" != 0 ]] && grep -qF -- "$want" <<<"$out" && ! grep -q 'services enable' <<<"$out"; then
    ok "setup: refuses $name"
  else
    nok "setup: refuses $name (rc $rc): $out"
  fi
}
refuse "a project without the label" "has no label purpose=agent-bot-broker" BROKER_FIXTURE_LABEL=
refuse "a project with another label value" "has no label" BROKER_FIXTURE_LABEL=other
refuse "a workload identity pool" "workload identity pool" BROKER_FIXTURE_POOLS=projects/1/locations/global/workloadIdentityPools/github
refuse "another Cloud Run service" "another Cloud Run service (web)" "BROKER_FIXTURE_SERVICES=agent-bot-broker web"
refuse "a user-managed key" "has a user-managed key" BROKER_FIXTURE_KEYS=k1
refuse "no BROKER_PROJECT" "set BROKER_PROJECT" BROKER_PROJECT=
refuse "the off-limits project" "is not a broker project" BROKER_PROJECT=pse-advisor-feat001

exit "$fail"
