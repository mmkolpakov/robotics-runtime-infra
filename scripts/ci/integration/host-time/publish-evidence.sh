#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/integration/host-time/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${HOST_TIME_MEASUREMENT_STARTED_NS:?measurement start is required}"
: "${HOST_TIME_MEASUREMENT_FINISHED_NS:?measurement finish is required}"
: "${HOST_TIME_MEASUREMENT_RUN_ID:?measurement run identity is required}"
time_evidence="${RUNNER_TEMP}/physical-attach-time.otlp.json"
time_window="${RUNNER_TEMP}/physical-attach-time-window.json"
install -m 0644 \
  "${HOST_TIME_CHRONY_EVIDENCE}/hardware-time.otlp.json" \
  "${time_evidence}"
jq -n \
  --arg evidence_sha256 "$(sha256sum "${time_evidence}" | awk '{print $1}')" \
  --arg finished_at_unix_nano "${HOST_TIME_MEASUREMENT_FINISHED_NS}" \
  --arg source_revision "${GITHUB_SHA:-local}" \
  --arg run_id "${HOST_TIME_MEASUREMENT_RUN_ID}" \
  --arg started_at_unix_nano "${HOST_TIME_MEASUREMENT_STARTED_NS}" \
  --arg workflow_run_attempt "${GITHUB_RUN_ATTEMPT:-1}" \
  --arg workflow_run_id "${GITHUB_RUN_ID:-local}" '
    {
      schema_version: "physical-attach-time-window.v1",
      run_id: $run_id,
      workflow_run_id: $workflow_run_id,
      workflow_run_attempt: $workflow_run_attempt,
      source_revision: $source_revision,
      started_at_unix_nano: $started_at_unix_nano,
      finished_at_unix_nano: $finished_at_unix_nano,
      evidence_sha256: $evidence_sha256
    }
  ' >"${time_window}"
{
  printf 'ROBOTICS_TIME_EVIDENCE=%s\n' "${time_evidence}"
  printf 'ROBOTICS_TIME_EVIDENCE_WINDOW=%s\n' "${time_window}"
  printf 'ROBOTICS_TIME_EVIDENCE_RUN_ID=%s\n' \
    "${HOST_TIME_MEASUREMENT_RUN_ID}"
} >>"${GITHUB_ENV}"
