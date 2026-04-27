#!/usr/bin/env bash
# Schedule a Cloud Run job via Cloud Scheduler.
#
# Usage:
#   schedule-job.sh --app agent-action-item-registry --cron "30 17 * * 1-5" --tz America/New_York
#
# Idempotent: creates if missing, updates if present.
set -euo pipefail

PROJECT="${GCP_PROJECT:-high-ground-labs}"
REGION="${GCP_REGION:-us-central1}"
TZ_NAME="America/New_York"
APP=""
CRON=""
SCHEDULER_SA="${SCHEDULER_SA:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)   APP="$2"; shift 2 ;;
    --cron)  CRON="$2"; shift 2 ;;
    --tz)    TZ_NAME="$2"; shift 2 ;;
    --sa)    SCHEDULER_SA="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$APP" ]]  || { echo "ERROR: --app is required"; exit 2; }
[[ -n "$CRON" ]] || { echo "ERROR: --cron is required"; exit 2; }

JOB="hg-${APP}"
SCHEDULE_NAME="${JOB}-cron"
URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB}:run"

if [[ -z "$SCHEDULER_SA" ]]; then
  PROJ_NUM=$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')
  SCHEDULER_SA="${PROJ_NUM}-compute@developer.gserviceaccount.com"
fi

# Grant the scheduler SA permission to invoke this specific Cloud Run job.
# Without this, the scheduled trigger fires but the run.googleapis.com call
# returns 403. Idempotent.
gcloud run jobs add-iam-policy-binding "${JOB}" \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --member="serviceAccount:${SCHEDULER_SA}" \
  --role=roles/run.invoker \
  --quiet >/dev/null

if gcloud scheduler jobs describe "${SCHEDULE_NAME}" \
     --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  CMD="update"
else
  CMD="create"
fi

gcloud scheduler jobs "${CMD}" http "${SCHEDULE_NAME}" \
  --project="${PROJECT}" \
  --location="${REGION}" \
  --schedule="${CRON}" \
  --time-zone="${TZ_NAME}" \
  --uri="${URI}" \
  --http-method=POST \
  --oauth-service-account-email="${SCHEDULER_SA}"

echo "==> Scheduled ${SCHEDULE_NAME}: '${CRON}' (${TZ_NAME}) -> ${JOB}"
