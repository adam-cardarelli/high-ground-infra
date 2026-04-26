#!/usr/bin/env bash
# Set up the static-IP NAT gateway used by services that call externally-whitelisted APIs
# (FactSet today, others later). Run once. Idempotent.
#
# Creates:
#   - Reserves static IP 34.59.21.34 (or finds existing reservation under any name).
#   - Cloud Router cloud-run-nat-router.
#   - Cloud NAT cloud-run-nat using the static IP.
#   - VPC Access Connector company-data-conn.
#
# After this, services that need outbound through the static IP should deploy with:
#   --vpc-egress all-traffic
# (the reusable workflow exposes this as `vpc_egress: all-traffic`).
set -euo pipefail

PROJECT="${GCP_PROJECT:-high-ground-labs}"
REGION="${GCP_REGION:-us-central1}"
NETWORK="${NAT_NETWORK:-default}"
VPC_CONNECTOR="${VPC_CONNECTOR:-company-data-conn}"
ROUTER_NAME="${NAT_ROUTER:-cloud-run-nat-router}"
NAT_NAME="${NAT_NAME:-cloud-run-nat}"
NAT_GATEWAY_IP="${NAT_GATEWAY_IP:-34.59.21.34}"
DEFAULT_IP_NAME="cloud-run-nat-ip"

echo "==> NAT gateway setup: project=${PROJECT}, IP=${NAT_GATEWAY_IP}"

gcloud services enable \
  compute.googleapis.com \
  vpcaccess.googleapis.com \
  servicenetworking.googleapis.com \
  --project="${PROJECT}" --quiet

# --- 1. Static IP ---
EXISTING_IP_NAME=$(gcloud compute addresses list \
  --project="${PROJECT}" \
  --filter="address=${NAT_GATEWAY_IP} AND region:${REGION}" \
  --format="value(name)" | head -1)

if [[ -n "$EXISTING_IP_NAME" ]]; then
  echo "==> Static IP ${NAT_GATEWAY_IP} already reserved as: ${EXISTING_IP_NAME}"
  STATIC_IP_NAME="$EXISTING_IP_NAME"
else
  STATIC_IP_NAME="$DEFAULT_IP_NAME"
  echo "==> Reserving ${NAT_GATEWAY_IP} as ${STATIC_IP_NAME}"
  gcloud compute addresses create "${STATIC_IP_NAME}" \
    --project="${PROJECT}" \
    --addresses="${NAT_GATEWAY_IP}" \
    --region="${REGION}" \
    --description="High Ground NAT gateway static IP"
fi

# --- 2. Cloud Router ---
if ! gcloud compute routers describe "${ROUTER_NAME}" \
       --project="${PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
  echo "==> Creating Cloud Router: ${ROUTER_NAME}"
  gcloud compute routers create "${ROUTER_NAME}" \
    --project="${PROJECT}" \
    --network="${NETWORK}" \
    --region="${REGION}"
fi

# --- 3. Cloud NAT ---
if gcloud compute routers nats describe "${NAT_NAME}" \
     --project="${PROJECT}" --router="${ROUTER_NAME}" --region="${REGION}" >/dev/null 2>&1; then
  echo "==> NAT ${NAT_NAME} already exists"
else
  echo "==> Creating Cloud NAT ${NAT_NAME} using ${STATIC_IP_NAME}"
  gcloud compute routers nats create "${NAT_NAME}" \
    --project="${PROJECT}" \
    --router="${ROUTER_NAME}" \
    --region="${REGION}" \
    --nat-external-ip-pool="${STATIC_IP_NAME}" \
    --nat-all-subnet-ip-ranges
fi

# --- 4. VPC Access Connector ---
STATE=$(gcloud compute networks vpc-access connectors describe "${VPC_CONNECTOR}" \
  --project="${PROJECT}" --region="${REGION}" \
  --format='value(state)' 2>/dev/null || echo "NOT_FOUND")

if [[ "$STATE" == "READY" ]]; then
  echo "==> VPC connector ${VPC_CONNECTOR} already READY"
elif [[ "$STATE" != "NOT_FOUND" ]]; then
  echo "==> VPC connector exists in state ${STATE}; recreating"
  gcloud compute networks vpc-access connectors delete "${VPC_CONNECTOR}" \
    --project="${PROJECT}" --region="${REGION}" --quiet || true
  sleep 5
fi

if [[ "$STATE" != "READY" ]]; then
  for range in 10.8.0.0/28 10.9.0.0/28 10.10.0.0/28; do
    echo "==> Trying VPC connector with range ${range}"
    if gcloud compute networks vpc-access connectors create "${VPC_CONNECTOR}" \
         --project="${PROJECT}" \
         --region="${REGION}" \
         --network="${NETWORK}" \
         --range="${range}" \
         --min-instances=2 --max-instances=10 \
         --machine-type=e2-micro 2>&1 | tee /tmp/vpc-conn.log; then
      echo "==> VPC connector created with ${range}"
      break
    elif grep -q "conflicts" /tmp/vpc-conn.log; then
      continue
    else
      echo "ERROR creating VPC connector"; exit 1
    fi
  done
fi

echo
echo "==> NAT gateway setup complete."
echo "    Static IP:      ${NAT_GATEWAY_IP}"
echo "    Router:         ${ROUTER_NAME}"
echo "    NAT:            ${NAT_NAME}"
echo "    VPC Connector:  ${VPC_CONNECTOR}"
echo
echo "    Verify after deploy: a service with --vpc-egress all-traffic should curl"
echo "    https://api.ipify.org and see ${NAT_GATEWAY_IP}."
