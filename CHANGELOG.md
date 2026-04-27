# Changelog

App repos pin to a tag of this repo (`@v1`, `@v2`, …). Bump major when the deploy contract changes in a backward-incompatible way.

## v1

First tagged release. Hardened during the initial end-to-end deploy of
`high-ground-agents` (action-items + demo-triage skills) and
`high-ground-simulations` (hearing-signals dashboard). Notable fixes baked
in to the v1 contract:
- Drop `-runtime` suffix from default runtime SA name (GCP 30-char SA limit).
- `--suppress-logs` on `gcloud builds submit` (recent gcloud default writes
  build logs to a Google-internal bucket the calling SA can't read).
- Auto-append `:latest` to `--set-secrets` pairs.
- 15s sleep after SA creation for IAM propagation.
- Grant runtime SA `storage.objectAdmin` on the agents state bucket.
- `schedule-job.sh` grants scheduler SA `roles/run.invoker` on the job.
- Bootstrap-project.sh now enables `cloudresourcemanager.googleapis.com`
  and grants the deployer SA `roles/iam.serviceAccountCreator`.

`high-ground-data-vendors` (formerly `data-workbench`) hasn't deployed
through this repo yet — the service deploy script has the same hardening
but is unvalidated end-to-end against a real service deploy.
