#!/usr/bin/env bash
set -Eeuo pipefail

report_dir="${PWD}/artifacts/provider-conformance/intel-cpu"
provider_config="${ROBOTICS_OPENVINO_CONFIG:-${PWD}/config/inference/openvino-cpu-latency.json}"
latency_config="${PWD}/config/inference/openvino-cpu-latency.json"
throughput_config="${PWD}/config/inference/openvino-cpu-throughput.json"

jq -e '
  .device_type == "CPU" and
  (.load_config | fromjson | .CPU) == {
    "NUM_STREAMS": "1",
    "PERFORMANCE_HINT": "LATENCY"
  }
' "${latency_config}" >/dev/null
jq -e '
  .device_type == "CPU" and
  (.load_config | fromjson | .CPU) == {
    "PERFORMANCE_HINT": "THROUGHPUT"
  }
' "${throughput_config}" >/dev/null

docker run --rm "${INFERENCE_INTEL_CPU_IMAGE}" bash -Eeuo pipefail -c '
  ! command -v clinfo
  ! dpkg-query -W intel-opencl-icd intel-level-zero-gpu 2>/dev/null
'
docker run --rm "${INFERENCE_INTEL_GPU_IMAGE}" bash -Eeuo pipefail -c '
  command -v clinfo
  dpkg-query -W intel-opencl-icd intel-level-zero-gpu >/dev/null
'

mkdir -p "${report_dir}"
sudo chown -R 1000:1000 "${PWD}/artifacts/provider-conformance"
ROBOTICS_PROVIDER_REPORT_DIR="${report_dir}" \
ROBOTICS_OPENVINO_CONFIG="${provider_config}" \
  docker compose -f compose.yaml -f compose.intel.yaml \
  --profile conformance-intel-cpu run \
  --rm --no-deps provider-conformance-intel-cpu
jq -e --arg config_sha256 "$(sha256sum "${provider_config}" | cut -d' ' -f1)" '
  .status == "passed" and
  .expected_provider == "OpenVINOExecutionProvider" and
  .executed_providers == ["OpenVINOExecutionProvider"] and
  .provider_options.device_type == "CPU" and
  .provider_options_sha256 == $config_sha256 and
  .fallback_count == 0
' "${report_dir}/provider-conformance.json"
