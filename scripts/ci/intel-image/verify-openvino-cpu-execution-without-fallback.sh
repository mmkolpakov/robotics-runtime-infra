#!/usr/bin/env bash
set -Eeuo pipefail

report_dir="${PWD}/artifacts/provider-conformance/intel-cpu"
mkdir -p "${report_dir}"
sudo chown -R 1000:1000 "${PWD}/artifacts/provider-conformance"
ROBOTICS_PROVIDER_REPORT_DIR="${report_dir}" \
  docker compose -f compose.yaml -f compose.intel.yaml \
  --profile conformance-intel-cpu run \
  --rm --no-deps provider-conformance-intel-cpu
jq -e '
  .status == "passed" and
  .expected_provider == "OpenVINOExecutionProvider" and
  .executed_providers == ["OpenVINOExecutionProvider"] and
  .provider_options.device_type == "CPU" and
  .fallback_count == 0
' "${report_dir}/provider-conformance.json"
