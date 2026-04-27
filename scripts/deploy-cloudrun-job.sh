#!/usr/bin/env bash
# Deploy a Cloud Run job following High Ground conventions.
#
# Two modes:
#   1. Single-image-per-skill (default): build image from --source-dir, deploy job hg-<app>.
#   2. Shared-image, multi-job: build once via build-only run, then deploy multiple jobs that share
#      the image. Use --image to skip the build and reuse an existing tag. The agent framework
#      uses this — same image, AGENT_NAME env var picks the skill.
#
# Usage:
#   # Single job that owns its image:
#   deploy-cloudrun-job.sh \
#     --app pipeline-ingest \
#     --source-dir . \
#     --secrets "GEMINI_API_KEY=hg-shared-gemini-key" \
#     --env-vars "MODE=daily"
#
#   # Build a shared image once, then deploy N jobs against it:
#   deploy-cloudrun-job.sh --app agents --source-dir . --build-only
#   deploy-cloudrun-job.sh --app agent-action-item-registry \
#     --image us-central1-docker.pkg.dev/high-ground-labs/hg-images/agents:abc123 \
#     --env-vars "AGENT_NAME=action-item-registry"
#
# Idempotent.
set -euo pipefail

PROJECT="${GCP_PROJECT:-high-ground-labs}"
REGION="${GCP_REGION:-us-central1}"
REGISTRY="${ARTIFACT_REGISTRY:-hg-images}"
IMAGE_HOST="${REGION}-docker.pkg.dev"

TASK_TIMEOUT="15m"
MAX_RETRIES="1"
MEMORY="1Gi"
CPU="1"
SECRETS=""
ENV_VARS=""
RUNTIME_SA=""
BUILD_ONLY="false"
PRESET_IMAGE=""
APP=""
SOURCE_DIR=""
GIT_SHA="${GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo "manual-$(date +%s)")}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)             APP="$2"; shift 2 ;;
    --source-dir)      SOURCE_DIR="$2"; shift 2 ;;
    --image)           PRESET_IMAGE="$2"; shift 2 ;;
    --task-timeout)    TASK_TIMEOUT="$2"; shift 2 ;;
    --max-retries)     MAX_RETRIES="$2"; shift 2 ;;
    --memory)          MEMORY="$2"; shift 2 ;;
    --cpu)             CPU="$2"; shift 2 ;;
    --secrets)         SECRETS="$2"; shift 2 ;;
    --env-vars)        ENV_VARS="$2"; shift 2 ;;
    --runtime-sa)      RUNTIME_SA="$2"; shift 2 ;;
    --build-only)      BUILD_ONLY="true"; shift 1 ;;
    --git-sha)         GIT_SHA="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$APP" ]] || { echo "ERROR: --app is required"; exit 2; }

# Normalize SECRETS: Cloud Run requires an explicit version suffix on each
# secret reference (e.g. KEY=name:latest). Append :latest to any pair that
# doesn't already specify a version.
if [[ -n "$SECRETS" ]]; then
  NORMALIZED=""
  IFS=',' read -ra _PAIRS <<< "$SECRETS"
  for pair in "${_PAIRS[@]}"; do
    [[ "$pair" == *":"* ]] || pair="${pair}:latest"
    NORMALIZED="${NORMALIZED:+${NORMALIZED},}${pair}"
  done
  SECRETS="$NORMALIZED"
fi

JOB="hg-${APP}"
# SA name default is `hg-<app>` (no `-runtime` suffix) to fit GCP's 30-char SA
# local-part limit, which `hg-<app>-runtime` blows past for any app with a
# composite slug like `agent-action-item-registry`.
RUNTIME_SA="${RUNTIME_SA:-hg-${APP}@${PROJECT}.iam.gserviceaccount.com}"

# ---- Decide image source ----
if [[ -n "$PRESET_IMAGE" ]]; then
  IMAGE_SHA="$PRESET_IMAGE"
  echo "==> Reusing existing image: ${IMAGE_SHA}"
else
  [[ -n "$SOURCE_DIR" ]] || { echo "ERROR: --source-dir required when --image not provided"; exit 2; }
  [[ -d "$SOURCE_DIR" ]] || { echo "ERROR: source dir not found: $SOURCE_DIR"; exit 2; }

  IMAGE="${IMAGE_HOST}/${PROJECT}/${REGISTRY}/${APP}"
  IMAGE_SHA="${IMAGE}:${GIT_SHA}"
  IMAGE_LATEST="${IMAGE}:latest"

  echo "==> Building image: ${IMAGE_SHA}"
  # --suppress-logs: gcloud's recent default writes build logs to a Google-internal
  # bucket that the calling SA can't read, breaking CI. Skip log streaming; the
  # build still runs and gcloud waits + returns the final status. Inspect failures
  # in the GCP console via the build URL printed above.
  gcloud builds submit "${SOURCE_DIR}" \
    --project="${PROJECT}" \
    --tag "${IMAGE_SHA}" \
    --suppress-logs \
    --quiet

  gcloud artifacts docker tags add "${IMAGE_SHA}" "${IMAGE_LATEST}" \
    --project="${PROJECT}" \
    >/dev/null 2>&1 || true

  if [[ "$BUILD_ONLY" == "true" ]]; then
    echo "==> Build only. Image: ${IMAGE_SHA}"
    echo "${IMAGE_SHA}"   # last line is parseable for callers
    exit 0
  fi
fi

# ---- Ensure runtime SA exists ----
SA_LOCAL="${RUNTIME_SA%@*}"
SA_CREATED="false"
if ! gcloud iam service-accounts describe "${RUNTIME_SA}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "==> Creating runtime SA: ${RUNTIME_SA}"
  gcloud iam service-accounts create "${SA_LOCAL}" \
    --project="${PROJECT}" \
    --display-name="${APP} runtime"
  SA_CREATED="true"
fi

# IAM is eventually consistent. After creation, subsequent gcloud calls that
# reference the SA can fail with "service account does not exist" until the
# new SA propagates. Wait briefly when we just created one.
if [[ "$SA_CREATED" == "true" ]]; then
  echo "==> Waiting 15s for SA to propagate"
  sleep 15
fi

# ---- Grant runtime SA access to the shared agents state bucket ----
# Cloud Run captures stdout/stderr to Cloud Logging via its own service
# agent — no logWriter/metricWriter grants needed on the runtime SA.
# But the runtime SA does need r/w on the agents state bucket since that's
# where state_* tools persist cursors / runs / artifacts.
AGENTS_BUCKET="${HG_AGENTS_BUCKET:-hg-agents-state}"
if gcloud storage buckets describe "gs://${AGENTS_BUCKET}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud storage buckets add-iam-policy-binding "gs://${AGENTS_BUCKET}" \
    --member="serviceAccount:${RUNTIME_SA}" \
    --role=roles/storage.objectAdmin \
    --project="${PROJECT}" \
    --quiet >/dev/null
fi

# ---- Grant runtime SA access to declared secrets ----
if [[ -n "$SECRETS" ]]; then
  IFS=',' read -ra SECRET_PAIRS <<< "$SECRETS"
  for pair in "${SECRET_PAIRS[@]}"; do
    secret_name="${pair#*=}"
    secret_name="${secret_name%:*}"
    if gcloud secrets describe "${secret_name}" --project="${PROJECT}" >/dev/null 2>&1; then
      gcloud secrets add-iam-policy-binding "${secret_name}" \
        --project="${PROJECT}" \
        --member="serviceAccount:${RUNTIME_SA}" \
        --role="roles/secretmanager.secretAccessor" \
        --condition=None \
        >/dev/null
    else
      echo "WARNING: secret '${secret_name}' does not exist."
    fi
  done
fi

# ---- Deploy job ----
DEPLOY_ARGS=(
  "${JOB}"
  --project="${PROJECT}"
  --region="${REGION}"
  --image="${IMAGE_SHA}"
  --service-account="${RUNTIME_SA}"
  --task-timeout="${TASK_TIMEOUT}"
  --max-retries="${MAX_RETRIES}"
  --memory="${MEMORY}"
  --cpu="${CPU}"
)

if [[ -n "$SECRETS" ]]; then
  DEPLOY_ARGS+=(--set-secrets="${SECRETS}")
fi

if [[ -n "$ENV_VARS" ]]; then
  DEPLOY_ARGS+=(--set-env-vars="${ENV_VARS}")
fi

echo "==> Deploying job: ${JOB}"
gcloud run jobs deploy "${DEPLOY_ARGS[@]}"

echo
echo "==> Done."
echo "    Job:   ${JOB}"
echo "    Image: ${IMAGE_SHA}"
echo "    Trigger: gcloud run jobs execute ${JOB} --region=${REGION} --project=${PROJECT}"
