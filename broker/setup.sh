#!/usr/bin/env bash
# One-time, idempotent setup of the broker project (spec 0004 FR-6, "The
# broker project"). The owner runs it with their own gcloud login:
#
#   BROKER_PROJECT=agent-bot-broker-<suffix> DRY_RUN=1 broker/setup.sh   # review
#   BROKER_PROJECT=agent-bot-broker-<suffix> broker/setup.sh
#
# The project must already exist, carry the label purpose=agent-bot-broker
# and be linked to billing. Every step checks before it creates, so a second
# run changes nothing. No TTL policy (plan Deviations), and no Firebase rules:
# a database made with gcloud already refuses unauthenticated clients (403,
# checked 2026-11-28 in the spike project).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=broker/lib.sh disable=SC1091
source "$here/lib.sh"

init_project
require_label
require_clean

say "project $P, region $REGION"

# --- APIs
run gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  secretmanager.googleapis.com firestore.googleapis.com iam.googleapis.com \
  billingbudgets.googleapis.com cloudresourcemanager.googleapis.com --project "$P"

# --- service accounts: broker@ (runtime) and builder@ (builds, C2)
for name in broker builder; do
  if ! exists gcloud iam service-accounts describe "${name}@${P}.iam.gserviceaccount.com" --project "$P"; then
    run gcloud iam service-accounts create "$name" --project "$P" --display-name "agent-bot-broker $name"
  fi
done
run gcloud projects add-iam-policy-binding "$P" --project "$P" \
  --member "serviceAccount:$BUILDER_SA" --role roles/run.builder --condition None --format none
run gcloud projects add-iam-policy-binding "$P" --project "$P" \
  --member "serviceAccount:$BROKER_SA" --role roles/datastore.user --condition None --format none

# The default compute account gets Editor in a project without an
# organization; a build identity with Editor could read the keys (C2).
number="$(query "${BROKER_FIXTURE_NUMBER-123456789012}" \
  gcloud projects describe "$P" --project "$P" --format "value(projectNumber)")"
compute_sa="${number}-compute@developer.gserviceaccount.com"
has_editor="$(query "${BROKER_FIXTURE_EDITOR-roles/editor}" \
  gcloud projects get-iam-policy "$P" --project "$P" --flatten "bindings[].members" \
  --filter "bindings.role=roles/editor AND bindings.members=serviceAccount:$compute_sa" --format "value(bindings.role)")"
if [[ -n "$has_editor" ]]; then
  run gcloud projects remove-iam-policy-binding "$P" --project "$P" \
    --member "serviceAccount:$compute_sa" --role roles/editor --condition None --format none
fi

# --- secrets: created empty, readable only by broker@, each on its own
for s in "${SECRETS[@]}"; do
  if ! exists gcloud secrets describe "$s" --project "$P"; then
    run gcloud secrets create "$s" --project "$P" --replication-policy automatic
  fi
  run gcloud secrets add-iam-policy-binding "$s" --project "$P" \
    --member "serviceAccount:$BROKER_SA" --role roles/secretmanager.secretAccessor --condition None --format none
done

# --- Firestore: (default), Native mode, in the service's region
if ! exists gcloud firestore databases describe --database "(default)" --project "$P"; then
  run gcloud firestore databases create --database "(default)" --location "$REGION" --type firestore-native --project "$P"
fi
index="$(query "${BROKER_FIXTURE_INDEX-}" \
  gcloud firestore indexes composite list --project "$P" --database "(default)" \
  --filter "name~/collectionGroups/audit/" --format "value(name)")"
if [[ -z "$index" ]]; then
  run gcloud firestore indexes composite create --project "$P" --database "(default)" \
    --collection-group audit --query-scope COLLECTION \
    --field-config field-path=caller_id,order=ascending \
    --field-config field-path=endpoint,order=ascending \
    --field-config field-path=ts,order=ascending
fi

# --- Artifact Registry: the source-deploy repository, 2 newest images kept
repo="cloud-run-source-deploy"
if ! exists gcloud artifacts repositories describe "$repo" --location "$REGION" --project "$P"; then
  run gcloud artifacts repositories create "$repo" --repository-format docker --location "$REGION" --project "$P"
fi
policy="$(mktemp)"
trap 'rm -f "$policy" "${iam:-}"' EXIT
cat >"$policy" <<'JSON'
[
  {"name": "keep-2-newest", "action": {"type": "Keep"}, "mostRecentVersions": {"keepCount": 2}},
  {"name": "delete-the-rest", "action": {"type": "Delete"}, "condition": {"tagState": "any"}}
]
JSON
run gcloud artifacts repositories set-cleanup-policies "$repo" --location "$REGION" --project "$P" \
  --policy "$policy" --no-dry-run

# --- audit logs: every read of a key is logged with who read it (NFR-2)
iam="$(mktemp)"
empty_policy='{"bindings":[]}'
query "${BROKER_FIXTURE_IAM-$empty_policy}" gcloud projects get-iam-policy "$P" --project "$P" --format json |
  jq '.auditConfigs = (((.auditConfigs // []) | map(select(.service != "secretmanager.googleapis.com")))
        + [{service: "secretmanager.googleapis.com", auditLogConfigs: [{logType: "DATA_READ"}]}])' >"$iam"
run gcloud projects set-iam-policy "$P" "$iam" --project "$P" --format none

# --- budget: $1 on this project, alerts at 50%, 90% and 100% (NFR-1)
account="$(query "${BROKER_FIXTURE_BILLING-billingAccounts/000000-000000-000000}" \
  gcloud billing projects describe "$P" --project "$P" --format "value(billingAccountName)")"
account="${account#billingAccounts/}"
[[ -n "$account" ]] || die "$P has no billing account; link one first"
budget_name="agent-bot-broker $P"
budget="$(query "${BROKER_FIXTURE_BUDGET-}" \
  gcloud billing budgets list --billing-account "$account" --project "$P" \
  --filter "displayName=\"$budget_name\"" --format "value(name)")"
if [[ -z "$budget" ]]; then
  run gcloud billing budgets create --billing-account "$account" --project "$P" \
    --display-name "$budget_name" --budget-amount 1USD --filter-projects "projects/$P" \
    --threshold-rule percent=0.5 --threshold-rule percent=0.9 --threshold-rule percent=1.0
fi

say "setup done. Next: broker/put-secret.sh for each of ${SECRETS[*]}, then broker/deploy.sh (broker/README.md)"
