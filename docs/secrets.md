# Secrets

All secret values live in GCP Secret Manager in project `high-ground-labs`. Never in git.

## Naming

| Pattern | Use |
|---|---|
| `hg-shared-<name>` | Shared across multiple apps (LLM keys, etc.) |
| `hg-<app>-<name>` | Owned by one app |

## Current secrets

| Name | Used by | Description |
|---|---|---|
| `hg-shared-anthropic-key` | agents | Anthropic API key (claude-* models) |
| `hg-shared-gemini-key` | agents | Gemini API key (gemini-* models) |
| `hg-agents-slack-bot-token` | agents | Slack bot token, read-only on configured channels |
| `hg-data-workbench-factset-username` | data-workbench | FactSet API username |
| `hg-data-workbench-factset-key` | data-workbench | FactSet API key |

When you add a new secret, append it to the table above AND to `scripts/bootstrap-secrets.sh` so future bootstraps include it.

## Adding a new secret

```bash
# Interactive (preferred):
./scripts/bootstrap-secrets.sh
# Then edit the script to permanently include the new prompt.

# Non-interactive (one-off):
printf '%s' "VALUE" | gcloud secrets create hg-<app>-<name> \
  --project=high-ground-labs \
  --replication-policy=automatic \
  --data-file=-
```

## How apps consume secrets at runtime

Apps declare secrets in their deploy workflow's `secrets_map` input:

```yaml
secrets_map: FACTSET_USERNAME=hg-data-workbench-factset-username,FACTSET_API_KEY=hg-data-workbench-factset-key
```

The deploy script:
1. Grants the runtime SA (`hg-<app>-runtime`) `roles/secretmanager.secretAccessor` on each declared secret.
2. Wires `--set-secrets` so Cloud Run injects the values as env vars at container start.

The secret value never lands in the image, the env file, or your laptop.

## Rotation

```bash
# Add a new version:
printf '%s' "NEW_VALUE" | gcloud secrets versions add hg-<app>-<name> \
  --project=high-ground-labs --data-file=-

# The next deploy picks up the new value because we reference :latest.
# Cloud Run *does not auto-update* running services on secret rotation —
# you must redeploy (push to main) for the new value to take effect.
```

## Migrating from legacy names

Legacy `high-ground-labs/infra/create-secrets.sh` created:

| Legacy name | New convention |
|---|---|
| `factset-username` | `hg-data-workbench-factset-username` |
| `factset-api-key` | `hg-data-workbench-factset-key` |
| `gemini-api-key` | `hg-shared-gemini-key` |
| `anthropic-api-key` | `hg-shared-anthropic-key` |
| `slack-bot-token` | `hg-agents-slack-bot-token` |

Two paths:

1. **Rename properly** (clean): create new secrets with new names, copy values over, update each app's `secrets_map`, delete the old secrets after one deploy cycle.
2. **Keep legacy names** (pragmatic): leave as-is, document the mapping in this file. Apps reference the legacy name in `secrets_map`. Only new secrets follow the convention. **Recommended for the first migration pass.**
