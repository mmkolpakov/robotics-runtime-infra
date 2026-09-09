#!/usr/bin/env bash

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../lib.sh"

export HOST_TIME_PHASE_DIR
HOST_TIME_PHASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export HOST_TIME_WORK="${RUNNER_TEMP}/host-preflight"
export HOST_TIME_SOCKET_DIR="${HOST_TIME_WORK}/socket"
export HOST_TIME_UNSYNC_SOCKET_DIR="${HOST_TIME_WORK}/unsync-socket"
export HOST_TIME_CHRONY_EVIDENCE="${HOST_TIME_WORK}/chrony"
export HOST_TIME_CHRONY_UNSYNC_EVIDENCE="${HOST_TIME_WORK}/chrony-unsync"
export HOST_TIME_PTP_EVIDENCE="${HOST_TIME_WORK}/ptp"
export HOST_TIME_PTP_UNSYNC_EVIDENCE="${HOST_TIME_WORK}/ptp-unsync"
export HOST_TIME_OTEL_IMAGE="otel/opentelemetry-collector-contrib:0.153.0@sha256:93aad750175cbf1a973ae1c5886c3371f4d800f61be25cdd26870b8441ffe9fa"

host_time_cleanup() {
  local status=$?
  local report_dir="${PWD}/artifacts/host-time"
  mkdir -p "${report_dir}"
  if [[ -d "${HOST_TIME_WORK}" ]]; then
    # Exclude command sockets; retain raw samples and Collector output on failure.
    (
      cd "${HOST_TIME_WORK}" || exit
      sudo find . -type f -exec cp --parents '{}' "${report_dir}" \;
    )
    sudo chown -R "$(id -u):$(id -g)" "${report_dir}"
  fi
  sudo rm -rf "${HOST_TIME_WORK}"
  return "${status}"
}

host_time_wait_for_collector() {
  local service="$1"
  shift
  for _ in {1..30}; do
    if "$@" logs --no-color "${service}" 2>&1 |
      grep -F 'Everything is ready' >/dev/null; then
      return 0
    fi
    sleep 1
  done
  "$@" logs --no-color "${service}" >&2 || true
  return 1
}

host_time_has_samples() {
  local path="$1"
  test -s "${path}" && jq -s -e '
    [.[] | .resourceMetrics[]? | .scopeMetrics[]? | .metrics[]? |
      .gauge.dataPoints[]?] | length > 0
  ' "${path}" >/dev/null 2>&1
}

host_time_wait_for_evidence() {
  local path="$1"
  shift
  for _ in {1..30}; do
    host_time_has_samples "${path}" && return 0
    sleep 1
  done
  "$@" logs --no-color >&2 || true
  return 1
}

host_time_require_clean_log() {
  local path="$1"
  if grep -Eiq 'deprecated|(^|[[:space:]])error([[:space:]]|$)' "${path}"; then
    printf 'Collector log contains an error or deprecation: %s\n' "${path}" >&2
    return 1
  fi
}

host_time_verify_timing() {
  local protocol="$1"
  local evidence="$2"
  local expected="$3"
  local monotonic="${4:-${expected}}"
  docker run --rm \
    --volume "${evidence}:/metrics.otlp.jsonl:ro" \
    --entrypoint /opt/venv/bin/python \
    "${OBSERVER_IMAGE}" -c '
from robotics_acceptance_harness.hardware_timing import evaluate_hardware_timing
from robotics_acceptance_harness.otel import load_otlp_json_metrics
import sys

expected = sys.argv[2] == "true"
# Chrony 4.5 deliberately randomizes tracking reference time backwards by
# up to one second (reference.c, fuzz_ref_time). Keep that conservative age:
# this fixture allows 1s timestamp uncertainty + 1s polling/export budget.
# PTP ingress timestamps have no such randomization.
max_age_ms = 2000 if sys.argv[1] == "chrony_ntp" else 1000
result = evaluate_hardware_timing(
    {
        "clock_sync_protocol": sys.argv[1],
        "time_authority_min_samples": 1,
        "max_clock_offset_ms": 5,
        "max_clock_drift_ppm": 20,
        "max_message_age_ms": max_age_ms,
    },
    load_otlp_json_metrics("/metrics.otlp.jsonl"),
)
assert result.sample_count >= 1, result
assert result.monotonic is (sys.argv[3] == "true"), result
assert result.within_policy is expected, result
' "${protocol}" "${expected}" "${monotonic}"
}

host_time_require_no_samples() {
  local evidence="$1"
  docker run --rm \
    --volume "${evidence}:/metrics.otlp.jsonl:ro" \
    --entrypoint /opt/venv/bin/python \
    "${OBSERVER_IMAGE}" -c '
from robotics_acceptance_harness.otel import load_otlp_json_metrics

assert load_otlp_json_metrics("/metrics.otlp.jsonl") == ()
'
}
