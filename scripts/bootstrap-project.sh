#!/usr/bin/env bash
# One-time GCP project setup. Idempotent — safe to re-run any time conventions change.
#
# Creates:
#   - Enables every API used across High Ground apps.
#   - Artifact Registry repo `hg-images` (one for all apps, image-name disambiguates).
#   - Project-wide deployer SA (hg-deployer) with deploy roles.
#   - GCS bucket for agent state (gs://hg-agents-state).
#
# Does NOT:
#   - Create runtime SAs (deploy scripts create them per-app on first deploy).
#   - Create the NAT gateway (run scripts/nat-gateway.sh separately if needed).
#   - Set up Workload Identity Federation (see docs/workload-identity.md).
#   - Populate secret values (run bootstrap-secrets.sh).
set -euo pipefail

PROJECT="${GCP_PROJECT:-high-ground-labs}"
REGION="${GCP_REGION:-us-central1}"
REGISTRY="${ARTIFACT_REGISTRY:-hg-images}"
AGENTS_BUCKET="${HG_AGENTS_BUCKET:-hg-agents-state}"
DEPLOYER_SA="hg-deployer@${PROJECT}.iam.gserviceaccount.com"

echo "==> Project: ${PROJECT}  Region: ${REGION}"

echo "==> Enabling APIs"
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  cloudscheduler.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  storage.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  compute.googleapis.com \
  vpcaccess.googleapis.com \
  servicenetworking.googleapis.com \
  bigquery.googleapis.com \
  sheets.googleapis.com \
  drive.googleapis.com \
  aiplatform.googleapis.com \
  --project="${PROJECT}"

echo "==> Artifact Registry: ${REGISTRY}"
if ! gcloud artifacts repositories describe "${REGISTRY}" \
       --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud artifacts repositories create "${REGISTRY}" \
    --repository-format=docker \
    --location="${REGION}" \
    --project="${PROJECT}" \
    --description="Shared Docker registry for all High Ground apps"
fi

echo "==> Deployer service account: ${DEPLOYER_SA}"
SA_LOCAL="${DEPLOYER_SA%@*}"
if ! gcloud iam service-accounts describe "${DEPLOYER_SA}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_LOCAL}" \
    --project="${PROJECT}" \
    --display-name="High Ground deployer (used by GitHub Actions via WIF)"
fi

DEPLOYER_ROLES=(
  roles/run.admin
  roles/cloudbuild.builds.editor
  roles/storage.admin
  roles/artifactregistry.writer
  roles/iam.serviceAccountUser
  roles/iam.serviceAccountCreator
  roles/secretmanager.admin
  roles/cloudscheduler.admin
)

for role in "${DEPLOYER_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${DEPLOYER_SA}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done

echo "==> Agent state bucket: gs://${AGENTS_BUCKET}"
if ! gcloud storage buckets describe "gs://${AGENTS_BUCKET}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${AGENTS_BUCKET}" \
    --project="${PROJECT}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
fi

cat <<NEXT

==> Bootstrap complete.

Remaining one-time setup:

1. Workload Identity Federation (so GitHub Actions can deploy without JSON keys):
     See docs/workload-identity.md for the gcloud commands. ~5 minutes.

2. Secret slots:
     ./scripts/bootstrap-secrets.sh
   (Prompts for each value. Skip what you don't have.)

3. NAT gateway (only if any service needs static-IP egress, e.g. FactSet):
     ./scripts/nat-gateway.sh

4. Tag this repo as v1 once it's deploying both high-ground-data-vendors and high-ground-agents:
     git tag v1 && git push --tags

NEXT
