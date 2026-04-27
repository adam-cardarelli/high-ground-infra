# Conventions

The contract every High Ground repo follows. If a script in this repo violates it, that's the bug.

## GCP target

| | |
|---|---|
| Project | `high-ground-labs` |
| Region | `us-central1` |
| Artifact Registry | `us-central1-docker.pkg.dev/high-ground-labs/hg-images` |

One project for everything. No `-dev` / `-prod` split — this is a labs environment. When something earns a real production lifecycle, it gets its own project.

## Naming

| Resource | Pattern | Example |
|---|---|---|
| Cloud Run service | `hg-<app>` | `hg-data-vendors-api` |
| Cloud Run job | `hg-<app>-<task>` | `hg-agent-action-item-registry` |
| Container image | `<app>:<git-sha>` (also `:latest`) | `data-vendors-api:a3f9c2e` |
| Runtime SA | `hg-<app>@…` | `hg-data-vendors-api@high-ground-labs.iam.gserviceaccount.com` |
| Deployer SA | `hg-deployer@…` | one per project, used by GitHub Actions via WIF |
| Secret (cross-app) | `hg-shared-<name>` | `hg-shared-anthropic-key` |
| Secret (app-scoped) | `hg-<app>-<name>` | `hg-data-vendors-factset-key` |
| Cloud Scheduler entry | `hg-<job>-cron` | `hg-agent-action-item-registry-cron` |

`<app>` is the app's slug — usually the repo name, or `<repo>-<sub>` if the repo deploys multiple things (e.g. `data-vendors-api`, `data-vendors-web`).

## Service accounts

One **runtime SA per app**. Created at deploy time if missing. Granted only the IAM roles the app needs:

| Need | Role |
|---|---|
| Read Secret Manager values it owns | `roles/secretmanager.secretAccessor` (per-secret binding) |
| Write to its GCS state bucket | `roles/storage.objectAdmin` (per-bucket binding) |
| Read BigQuery dataset | `roles/bigquery.dataViewer` (per-dataset binding) |
| Run BigQuery jobs | `roles/bigquery.jobUser` (project-level — limited to the SA itself) |

One **deployer SA** at the project level: `hg-deployer@high-ground-labs.iam.gserviceaccount.com`, used by GitHub Actions only. Roles: `roles/run.admin`, `roles/cloudbuild.builds.editor`, `roles/storage.admin` (for build artifacts), `roles/iam.serviceAccountUser` (so it can deploy services that run as the per-app runtime SAs), `roles/iam.serviceAccountCreator` (creates per-app runtime SAs on first deploy), `roles/artifactregistry.writer`, `roles/secretmanager.admin`, `roles/cloudscheduler.admin`. **Authenticated via Workload Identity Federation** — no JSON keys ever exist on disk.

## Secrets

- Values live only in Secret Manager. Never in git, never in `.env` files committed anywhere.
- Apps reference secrets at deploy time via `--set-secrets ENV_VAR=secret-name:latest`. The value never lands in the image or env file.
- Local development uses gcloud Application Default Credentials. If a real `.env` is needed locally, only `.env.example` is committed; `.env` is gitignored.

See [`secrets.md`](./secrets.md) for the current list and how to add new ones.

## Networking

If a service needs to call an externally-whitelisted API (FactSet today, others later), it must egress through the static IP. Add to its deploy:

```
--vpc-connector company-data-conn
--vpc-egress    all-traffic
```

The reusable workflow exposes this as `vpc_egress: all-traffic`. Default is no VPC connector — most services don't need it.

See [`nat-gateway.md`](./nat-gateway.md) for the topology.

## Image tagging

Every build pushes two tags:

- `<app>:<git-sha>` — immutable, deterministic, used by the deploy.
- `<app>:latest` — convenience, never trusted by automation.

Cloud Run is configured to deploy by SHA. `:latest` is for humans poking around with `gcloud run deploy --image …:latest`.

## Region and lock-in

Everything is `us-central1`. Don't add multi-region until there's a reason. NAT gateway, VPC connector, Artifact Registry, Cloud Run services, Cloud Run jobs, Cloud Scheduler, GCS state buckets all colocated.

## Defaults the reusable workflow assumes

When you call the reusable workflow without overriding, you get:

- `port: 8080` (services)
- `memory: 512Mi`
- `cpu: 1`
- `min_instances: 0`
- `max_instances: 10`
- `timeout: 60` (services) / `15m` (jobs)
- `allow_unauthenticated: true` (services — flip to false for internal-only)
- `vpc_egress: none`
- `runtime_sa: hg-<app>` (created if missing)

Override in your workflow inputs when defaults don't fit.

## Migration note

Legacy `high-ground-labs` deploy scripts target project `high-ground-dev` and hardcode account `acardarelli@highground.market`. **Both are wrong** for the new convention. The migration:

1. Reconcile to `high-ground-labs` project everywhere.
2. Drop the hardcoded account — auth flows through GitHub Actions via WIF, or local `gcloud auth login` for human-driven runs.
3. Migrate existing secrets (`factset-username`, `factset-api-key`, `gemini-api-key`, `slack-bot-token`) to the new naming if you're starting clean, OR keep the legacy names and document the mapping in `secrets.md`. **Easier path: document the legacy names; rename only when adding new secrets.**
