#!/usr/bin/env bash
# Shared retry helpers for our deploy scripts.
#
# IAM policies in GCP use optimistic concurrency — every read returns an etag,
# every write must include the etag, and writes fail if another caller has
# updated the policy in the meantime. When the agents-deploy workflow runs N
# parallel deploys against the same buckets / secrets, those writes race and
# return 409 (Status code: 409) or 412 (HTTPError 412 precondition) errors.
#
# Without retries the script `set -e`'s its way to exit 1, the CI job fails,
# and somebody has to retrigger the workflow manually. With retries we just
# back off and try again — every IAM write we issue is idempotent (we're
# adding a binding that's safe to add twice), so retrying is correct.
#
# Source this from any deploy script that mutates IAM policies:
#     # shellcheck source=lib/retry.sh
#     source "$(dirname "$0")/lib/retry.sh"
#
#     retry_on_iam_conflict gcloud secrets add-iam-policy-binding ...

# Run a command, retrying on optimistic-concurrency IAM errors.
# Exits with the command's exit code on non-retryable failures or after
# exhausting retries. Backoff: 2s, 4s, 8s, 16s, 32s (5 attempts total).
retry_on_iam_conflict() {
  local max_attempts=5
  local attempt=1
  local backoff=2
  local stderr_file
  stderr_file="$(mktemp -t hg-retry.XXXXXX)"

  while (( attempt <= max_attempts )); do
    if "$@" 2>"$stderr_file"; then
      # Surface any warnings the command printed (still in stderr_file).
      [[ -s "$stderr_file" ]] && cat "$stderr_file" >&2
      rm -f "$stderr_file"
      return 0
    fi

    local rc=$?
    local err
    err="$(<"$stderr_file")"

    # Optimistic-concurrency patterns we want to retry:
    # - 409 from `gcloud secrets / projects / iam` (concurrent policy change)
    # - 412 from `gcloud storage buckets` (precondition failed on etag)
    # - "ABORTED" from any IAM API
    if echo "$err" | grep -qiE 'Status code: 409|HTTPError 412|concurrent policy|ABORTED|precondition'; then
      if (( attempt < max_attempts )); then
        echo "==> IAM conflict (attempt ${attempt}/${max_attempts}); retrying in ${backoff}s..." >&2
        echo "    $(echo "$err" | grep -iE '409|412|concurrent|ABORTED|precondition' | head -1)" >&2
        sleep "$backoff"
        backoff=$(( backoff * 2 ))
        attempt=$(( attempt + 1 ))
        continue
      fi
      echo "==> IAM conflict persisted after ${max_attempts} attempts; failing." >&2
    fi

    # Non-retryable error or exhausted retries — surface stderr and fail.
    cat "$stderr_file" >&2
    rm -f "$stderr_file"
    return "$rc"
  done

  rm -f "$stderr_file"
  return 1
}
