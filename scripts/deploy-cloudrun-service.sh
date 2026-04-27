#!/usr/bin/env bash
# Deploy a Cloud Run service following High Ground conventions.
#
# Usage:
#   deploy-cloudrun-service.sh \
#     --app data-vendors-api \
#     --source-dir apps/api \
#     --port 8000 \
#     --vpc-egress all-traffic \
#     --secrets "FACTSET_USERNAME=hg-data-vendors-factset-username,FACTSET_API_KEY=hg-data-vendors-factset-key" \
#     --env-vars "ENVIRONMENT=production" \
#     --allow-unauthenticated true
#
# Required: --app, --source-dir
# Everything else: optional with sane defaults from docs/conventions.md.
#
# Behavior:
#   1. Build image via gcloud builds submit, tag <app>:<sha> + <app>:latest in Artifact Registry.
#   2. Ensure runtime SA exists (hg-<app>-runtime).
#   3. Deploy/update Cloud Run service hg-<app> using the SHA-tagged image.
#   4. Print service URL.
#
# This script is idempotent. Safe to re-run.
set -euo pipefail

# ---- Defaults (per docs/conventions.md) ----
PROJECT="${GCP_PROJECT:-high-ground-labs}"
REGION="${GCP_REGION:-us-central1}"
REGISTRY="${ARTIFACT_REGISTRY:-hg-images}"
IMAGE_HOST="${REGION}-docker.pkg.dev"

PORT="8080"
MEMORY="512Mi"
CPU="1"
MIN_INSTANCES="0"
MAX_INSTANCES="10"
TIMEOUT="60"
ALLOW_UNAUTH="true"
VPC_EGRESS="none"
VPC_CONNECTOR="company-data-conn"
SECRETS=""
ENV_VARS=""
BUILD_ARGS=""
RUNTIME_SA=""

# ---- Parse args ----
APP=""
SOURCE_DIR=""
GIT_SHA="${GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo "manual-$(date +%s)")}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)                 APP="$2"; shift 2 ;;
    --source-dir)          SOURCE_DIR="$2"; shift 2 ;;
    --port)                PORT="$2"; shift 2 ;;
    --memory)              MEMORY="$2"; shift 2 ;;
    --cpu)                 CPU="$2"; shift 2 ;;
    --min-instances)       MIN_INSTANCES="$2"; shift 2 ;;
    --max-instances)       MAX_INSTANCES="$2"; shift 2 ;;
    --timeout)             TIMEOUT="$2"; shift 2 ;;
    --allow-unauthenticated) ALLOW_UNAUTH="$2"; shift 2 ;;
    --vpc-egress)          VPC_EGRESS="$2"; shift 2 ;;
    --secrets)             SECRETS="$2"; shift 2 ;;
    --env-vars)            ENV_VARS="$2"; shift 2 ;;
    --build-args)          BUILD_ARGS="$2"; shift 2 ;;
    --runtime-sa)          RUNTIME_SA="$2"; shift 2 ;;
    --git-sha)             GIT_SHA="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$APP" ]]        || { echo "ERROR: --app is required"; exit 2; }
[[ -n "$SOURCE_DIR" ]] || { echo "ERROR: --source-dir is required"; exit 2; }
[[ -d "$SOURCE_DIR" ]] || { echo "ERROR: source dir not found: $SOURCE_DIR"; exit 2; }

# Normalize SECRETS: Cloud Run requires an explicit version suffix on each
# secret reference. Append :latest to any pair that doesn't have one.
if [[ -n "$SECRETS" ]]; then
  NORMALIZED=""
  IFS=',' read -ra _PAIRS <<< "$SECRETS"
  for pair in "${_PAIRS[@]}"; do
    [[ "$pair" == *":"* ]] || pair="${pair}:latest"
    NORMALIZED="${NORMALIZED:+${NORMALIZED},}${pair}"
  done
  SECRETS="$NORMALIZED"
fi

SERVICE="hg-${APP}"
IMAGE="${IMAGE_HOST}/${PROJECT}/${REGISTRY}/${APP}"
IMAGE_SHA="${IMAGE}:${GIT_SHA}"
IMAGE_LATEST="${IMAGE}:latest"
# SA name default is `hg-<app>` (no `-runtime` suffix) to fit GCP's 30-char SA
# local-part limit, which `hg-<app>-runtime` blows past for composite slugs.
RUNTIME_SA="${RUNTIME_SA:-hg-${APP}@${PROJECT}.iam.gserviceaccount.com}"

echo "==> App: ${APP}"
echo "    Service:    ${SERVICE}"
echo "    Image:      ${IMAGE_SHA}"
echo "    Source:     ${SOURCE_DIR}"
echo "    Runtime SA: ${RUNTIME_SA}"

# ---- 1. Ensure runtime service account exists ----
SA_LOCAL="${RUNTIME_SA%@*}"
SA_CREATED="false"
if ! gcloud iam service-accounts describe "${RUNTIME_SA}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "==> Creating runtime SA: ${RUNTIME_SA}"
  gcloud iam service-accounts create "${SA_LOCAL}" \
    --project="${PROJECT}" \
    --display-name="${APP} runtime"
  SA_CREATED="true"
fi

# IAM is eventually consistent — wait briefly so subsequent calls see the new SA.
if [[ "$SA_CREATED" == "true" ]]; then
  echo "==> Waiting 15s for SA to propagate"
  sleep 15
fi

# ---- 2. Grant runtime SA access to its declared secrets ----
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
      echo "WARNING: secret '${secret_name}' does not exist. Create it before deploy succeeds."
    fi
  done
fi

# ---- 3. Build image ----
echo "==> Building image: ${IMAGE_SHA}"
# --suppress-logs: gcloud's recent default writes build logs to a Google-internal
# bucket the calling SA can't read. Skip log streaming; build still runs and
# gcloud waits + returns final status. Inspect failures in GCP console.
#
# Build args: gcloud builds submit doesn't accept --build-arg directly when
# using --tag. If build args are provided, generate an inline cloudbuild.yaml
# step that does the docker build with --build-arg KEY=VALUE for each.
BUILD_ARGS_FLAGS=()
if [[ -n "$BUILD_ARGS" ]]; then
  IFS=',' read -ra _BARGS <<< "$BUILD_ARGS"
  for kv in "${_BARGS[@]}"; do
    BUILD_ARGS_FLAGS+=(--build-arg "$kv")
  done
fi

if [[ ${#BUILD_ARGS_FLAGS[@]} -gt 0 ]]; then
  # Use docker build via a substitution-driven cloudbuild config so we can
  # pass build args. Cloud Build's docker builder accepts --build-arg.
  CLOUDBUILD_TMP=$(mktemp)
  cat > "$CLOUDBUILD_TMP" <<EOF
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['build'$(printf ", '--build-arg', '%s'" "${_BARGS[@]}"), '-t', '${IMAGE_SHA}', '.']
images: ['${IMAGE_SHA}']
options:
  logging: CLOUD_LOGGING_ONLY
EOF
  gcloud builds submit "${SOURCE_DIR}" \
    --project="${PROJECT}" \
    --config "$CLOUDBUILD_TMP" \
    --suppress-logs \
    --quiet
  rm -f "$CLOUDBUILD_TMP"
else
  gcloud builds submit "${SOURCE_DIR}" \
    --project="${PROJECT}" \
    --tag "${IMAGE_SHA}" \
    --default-buckets-behavior=REGIONAL_USER_OWNED_BUCKET \
    --quiet
fi

# Tag :latest as a convenience pointer.
gcloud artifacts docker tags add "${IMAGE_SHA}" "${IMAGE_LATEST}" \
  --project="${PROJECT}" \
  >/dev/null 2>&1 || true

# ---- 4. Build deploy flags ----
DEPLOY_ARGS=(
  "${SERVICE}"
  --project="${PROJECT}"
  --region="${REGION}"
  --image="${IMAGE_SHA}"
  --service-account="${RUNTIME_SA}"
  --port="${PORT}"
  --memory="${MEMORY}"
  --cpu="${CPU}"
  --min-instances="${MIN_INSTANCES}"
  --max-instances="${MAX_INSTANCES}"
  --timeout="${TIMEOUT}"
  --platform=managed
)

if [[ "$ALLOW_UNAUTH" == "true" ]]; then
  DEPLOY_ARGS+=(--allow-unauthenticated)
else
  DEPLOY_ARGS+=(--no-allow-unauthenticated)
fi

if [[ "$VPC_EGRESS" != "none" ]]; then
  DEPLOY_ARGS+=(--vpc-connector="${VPC_CONNECTOR}" --vpc-egress="${VPC_EGRESS}")
fi

if [[ -n "$SECRETS" ]]; then
  DEPLOY_ARGS+=(--set-secrets="${SECRETS}")
fi

if [[ -n "$ENV_VARS" ]]; then
  DEPLOY_ARGS+=(--set-env-vars="${ENV_VARS}")
fi

echo "==> Deploying service: ${SERVICE}"
gcloud run deploy "${DEPLOY_ARGS[@]}"

# ---- 5. Report ----
URL=$(gcloud run services describe "${SERVICE}" \
  --project="${PROJECT}" --region="${REGION}" \
  --format='value(status.url)')
echo
echo "==> Done."
echo "    URL: ${URL}"
echo "    Image: ${IMAGE_SHA}"
