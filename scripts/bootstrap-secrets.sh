#!/usr/bin/env bash
# Create or update secret slots in Secret Manager.
# Prompts for each value. Press Enter to skip — leaves existing values untouched.
#
# Idempotent. Re-run any time you need to rotate a value or add a new secret.
#
# To add a new secret to this script, append a line below:
#   put_secret <secret-name> "<prompt text>" [silent]
set -euo pipefail

PROJECT="${GCP_PROJECT:-high-ground-labs}"

put_secret() {
  local name="$1"
  local prompt="$2"
  local silent="${3:-false}"

  echo
  echo "==> ${name}"
  if [[ "$silent" == "silent" ]]; then
    read -r -s -p "$prompt (or Enter to skip): " value
    echo
  else
    read -r -p "$prompt (or Enter to skip): " value
  fi

  if [[ -z "$value" ]]; then
    echo "    Skipped."
    return
  fi

  if gcloud secrets describe "${name}" --project="${PROJECT}" >/dev/null 2>&1; then
    printf '%s' "$value" | gcloud secrets versions add "${name}" \
      --project="${PROJECT}" --data-file=- >/dev/null
    echo "    Updated."
  else
    printf '%s' "$value" | gcloud secrets create "${name}" \
      --project="${PROJECT}" \
      --replication-policy=automatic \
      --data-file=- >/dev/null
    echo "    Created."
  fi
}

echo "Creating/updating secrets in project: ${PROJECT}"
echo "Press Enter on any prompt to skip."

# ---- Cross-app shared secrets ----
put_secret hg-shared-anthropic-key    "Anthropic API key (claude-* models)"          silent
put_secret hg-shared-gemini-key       "Gemini API key (gemini-* models)"             silent

# ---- Agents app ----
put_secret hg-agents-slack-bot-token  "Slack bot token (agents — xoxb-...)"          silent

# ---- Data workbench app ----
put_secret hg-data-workbench-factset-username "FactSet username (data-workbench)"
put_secret hg-data-workbench-factset-key      "FactSet API key (data-workbench)"     silent

cat <<DONE

==> Done.

Inspect:
  gcloud secrets list --project=${PROJECT}

Read a value (only with appropriate permissions):
  gcloud secrets versions access latest --secret=hg-shared-anthropic-key --project=${PROJECT}

Each app's runtime SA gets read access to the secrets it declares — that binding happens
automatically the first time you deploy via deploy-cloudrun-{service,job}.sh.

DONE
