#!/usr/bin/env bash
set -Eeuo pipefail

report_dir="${PWD}/artifacts/provider-conformance/cpu"
negative_dir="${PWD}/artifacts/provider-conformance/cpu-negative"
mkdir -p "${report_dir}" "${negative_dir}"
sudo chown -R 1000:1000 "${PWD}/artifacts/provider-conformance"
ROBOTICS_PROVIDER_REPORT_DIR="${report_dir}" \
  docker compose --profile conformance run \
  --rm --no-deps provider-conformance-cpu
jq -e '
  .status == "passed" and
  .expected_provider == "CPUExecutionProvider" and
  .executed_providers == ["CPUExecutionProvider"] and
  .fallback_count == 0
' "${report_dir}/provider-conformance.json"
set +e
ROBOTICS_EXPECTED_PROVIDER=CUDAExecutionProvider \
ROBOTICS_PROVIDER_REPORT_DIR="${negative_dir}" \
  docker compose --profile conformance run \
  --rm --no-deps provider-conformance-cpu
status=$?
set -e
test "${status}" -ne 0
jq -e '
  .status == "failed" and
  .reason == "expected_provider_unavailable"
' "${negative_dir}/provider-conformance.json"
