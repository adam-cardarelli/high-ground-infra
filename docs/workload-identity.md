# Workload Identity Federation: GitHub Actions → GCP

One-time setup so app repos' CI can deploy to GCP without storing JSON service account keys anywhere.

## Why this matters

The alternative is a JSON SA key stored as a GitHub secret (`GCP_SA_KEY`) in every repo. That key:
- Is long-lived and high-privilege.
- Has to be rotated manually and synced across N repos.
- Is leaked the moment any repo accidentally `cat`s it in CI logs.

Workload Identity Federation issues short-lived tokens minted from GitHub's OIDC provider, scoped to the specific repo and branch. No keys exist on disk. Less to rotate, smaller blast radius, simpler.

## One-time setup

Run from any account with `roles/owner` on `high-ground-labs`:

```bash
PROJECT="high-ground-labs"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
POOL="github"
PROVIDER="github"
GITHUB_OWNER="adam-cardarelli"   # change if you move to an org

# 1. Create the workload identity pool.
gcloud iam workload-identity-pools create "$POOL" \
  --project="$PROJECT" \
  --location=global \
  --display-name="GitHub Actions"

# 2. Create the OIDC provider that trusts GitHub's token issuer.
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
  --project="$PROJECT" \
  --location=global \
  --workload-identity-pool="$POOL" \
  --display-name="GitHub OIDC" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository_owner == '${GITHUB_OWNER}'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# 3. Allow the deployer SA to be impersonated by any of YOUR repos via this provider.
gcloud iam service-accounts add-iam-policy-binding \
  "hg-deployer@${PROJECT}.iam.gserviceaccount.com" \
  --project="$PROJECT" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository_owner/${GITHUB_OWNER}"

# 4. Print the provider resource name to drop into your reusable workflow defaults.
echo "wif_provider: projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
```

## After setup — update the reusable workflows

The reusable workflows in this repo have `wif_provider` defaulted to a placeholder string (`projects/<PROJECT_NUMBER>/...`). Replace `<PROJECT_NUMBER>` with the actual number printed by step 4 above, **commit, and tag `v1`**. App repos pin to `v1` and the WIF provider is hardcoded in the workflow defaults — they don't need to know the project number.

## Tighter scoping (optional)

The setup above lets *any* repo you own deploy. If you want to restrict to specific repos:

```bash
# In step 3, replace the principalSet line with one binding per repo:
gcloud iam service-accounts add-iam-policy-binding "hg-deployer@${PROJECT}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${GITHUB_OWNER}/high-ground-data-vendors"
```

For a solo developer, repo-level restriction is overkill. The `repository_owner` condition (step 2) is enough.

## What app repos need

Just this in their deploy workflow:

```yaml
permissions:
  contents: read
  id-token: write     # ← required for WIF

jobs:
  deploy:
    uses: adam-cardarelli/high-ground-infra/.github/workflows/reusable-deploy-service.yml@v1
    with:
      app: data-vendors-api
      source_dir: apps/api
      # ...
```

No `secrets:` block needed. No `GCP_SA_KEY` secret to set. The reusable workflow handles auth.

## Verifying

After setup, push to any app repo and watch the deploy run. The "Authenticate to GCP" step should print:

```
Successfully created credentials file at /tmp/gha-creds-...
```

…and the subsequent gcloud calls should succeed without prompting for any credentials.

If you see `Permission 'iam.serviceAccounts.getAccessToken' denied` — the IAM binding in step 3 didn't apply. Double-check `repository_owner` in the GitHub OIDC token matches what you bound.
