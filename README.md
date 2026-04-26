# high-ground-infra

GCP foundation and shared deploy machinery for every High Ground repo.

App repos contain their own code and a thin `infra/deploy.sh`. Everything else — GCP project setup, service-account conventions, secret naming, NAT gateway, the actual deploy scripts, the reusable CI workflows — lives here.

## Layout

```
high-ground-infra/
├── docs/
│   ├── conventions.md       ← the contract. Every other repo follows this.
│   ├── secrets.md           ← secret naming + how to add new ones
│   ├── nat-gateway.md       ← static IP 34.59.21.34, VPC egress, FactSet whitelist
│   └── workload-identity.md ← keyless GitHub Actions → GCP auth
├── scripts/
│   ├── deploy-cloudrun-service.sh   ← shared deploy library (HTTP services)
│   ├── deploy-cloudrun-job.sh       ← shared deploy library (batch jobs)
│   ├── schedule-job.sh              ← Cloud Scheduler wiring for jobs
│   ├── bootstrap-project.sh         ← one-time project setup (idempotent)
│   └── bootstrap-secrets.sh         ← create secret slots in Secret Manager
└── .github/workflows/
    ├── reusable-deploy-service.yml  ← consumed by app repos via `uses:`
    └── reusable-deploy-job.yml
```

## How app repos consume this

Each app repo's CI is a 15-line file that calls our reusable workflow. Example:

```yaml
# data-workbench/.github/workflows/deploy.yml
on:
  push:
    branches: [main]

jobs:
  deploy-api:
    uses: adam-cardarelli/high-ground-infra/.github/workflows/reusable-deploy-service.yml@v1
    with:
      app: data-workbench-api
      source_dir: apps/api
      port: 8000
      vpc_egress: all-traffic
      secrets_map: FACTSET_USERNAME=hg-data-workbench-factset-username,FACTSET_API_KEY=hg-data-workbench-factset-key
    permissions:
      contents: read
      id-token: write
```

That's it. Image build, registry push, Cloud Run deploy, secret wiring, VPC connector — handled by the reusable workflow. Pin to `@v1` for stability; bump tags here when conventions change.

## Bootstrap order (one-time)

```bash
# 1. Authenticate (any human-shaped account with project Owner role).
gcloud auth login
gcloud config set project high-ground-labs

# 2. Enable APIs, create Artifact Registry, GCS buckets.
./scripts/bootstrap-project.sh

# 3. Set up Workload Identity Federation for GitHub → GCP (no JSON keys).
#    See docs/workload-identity.md.

# 4. Create secret slots (values come later, prompted).
./scripts/bootstrap-secrets.sh

# 5. NAT gateway (run only if you need outbound static IP — FactSet etc.).
./scripts/nat-gateway.sh
```

After bootstrap, app repos can deploy themselves via their own `deploy.yml` workflows.

## Versioning

Tag this repo (`v1`, `v2`, …) when the deploy contract changes. App repos pin to a tag. Breaking changes are a tag bump + a migration note in [CHANGELOG.md](./CHANGELOG.md).

## Access control

Repo settings → Actions → General → "Access" → **Accessible from repositories owned by the user**. That's how every repo you own can call this repo's reusable workflows. No other repo can. No PATs needed.

## What does NOT live here

- Application code. Lives in app repos.
- Application-specific secret *values*. Live in Secret Manager, not git.
- Per-app Dockerfiles. Live in app repos (each app knows its own runtime).
- One-off experimental scripts. Stay local.
