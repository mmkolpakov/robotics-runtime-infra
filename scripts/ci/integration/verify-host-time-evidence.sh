#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/integration/host-time/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/host-time/lib.sh"
ci_enter_repo

sudo rm -rf "${HOST_TIME_WORK}"
mkdir -p \
  "${HOST_TIME_SOCKET_DIR}" "${HOST_TIME_UNSYNC_SOCKET_DIR}" \
  "${HOST_TIME_CHRONY_EVIDENCE}" "${HOST_TIME_CHRONY_UNSYNC_EVIDENCE}" \
  "${HOST_TIME_PTP_EVIDENCE}" "${HOST_TIME_PTP_UNSYNC_EVIDENCE}"
sudo chown 100:101 \
  "${HOST_TIME_SOCKET_DIR}" "${HOST_TIME_UNSYNC_SOCKET_DIR}" \
  "${HOST_TIME_CHRONY_EVIDENCE}" "${HOST_TIME_CHRONY_UNSYNC_EVIDENCE}" \
  "${HOST_TIME_PTP_EVIDENCE}" "${HOST_TIME_PTP_UNSYNC_EVIDENCE}"
sudo chmod 0770 "${HOST_TIME_SOCKET_DIR}" "${HOST_TIME_UNSYNC_SOCKET_DIR}"

trap host_time_cleanup EXIT
export HOST_TIME_MEASUREMENT_STARTED_NS
HOST_TIME_MEASUREMENT_STARTED_NS="$(date -u +%s%N)"
export HOST_TIME_MEASUREMENT_RUN_ID
HOST_TIME_MEASUREMENT_RUN_ID="time-$(
  tr -d '-' </proc/sys/kernel/random/uuid
)"
"${HOST_TIME_PHASE_DIR}/validate-config.sh"

run_chrony_case() (
  local name="$1"
  local config="$2"
  local socket_dir="$3"
  local evidence_dir="$4"
  local expected="$5"
  local compose=(
    env
    "ROBOTICS_CHRONY_FIXTURE_CONFIG=${config}"
    ROBOTICS_CHRONY_IDENTITY=100:101
    "ROBOTICS_TIME_EVIDENCE_DIR=${evidence_dir}"
    "ROBOTICS_TIME_SOCKET_DIR=${socket_dir}"
    docker compose
    --project-name "host-time-${name}-${GITHUB_RUN_ID:-local}"
    --file compose.yaml
    --file compose.time.yaml
    --file test/time/compose.yaml
    --profile time-chrony
  )
  trap '"${compose[@]}" down --volumes --remove-orphans || true' EXIT

  "${compose[@]}" up --detach --no-build --wait --wait-timeout 30 time-fixture
  "${compose[@]}" up --detach --no-build time-evidence-chrony
  host_time_wait_for_evidence \
    "${evidence_dir}/hardware-time.otlp.json" "${compose[@]}"
  "${compose[@]}" stop --timeout 10 time-evidence-chrony time-fixture
  "${compose[@]}" logs --no-color time-evidence-chrony \
    >"${HOST_TIME_WORK}/${name}-collector.log" 2>&1
  host_time_require_clean_log "${HOST_TIME_WORK}/${name}-collector.log"
  host_time_verify_timing \
    chrony_ntp "${evidence_dir}/hardware-time.otlp.json" "${expected}"
)

run_ptp_case() (
  local name="$1"
  local sample="$2"
  local evidence_dir="$3"
  local expected="$4"
  local compose=(
    env
    ROBOTICS_CHRONY_IDENTITY=100:101
    "ROBOTICS_PTP_SAMPLE_FILE=${sample}"
    "ROBOTICS_TIME_EVIDENCE_DIR=${evidence_dir}"
    docker compose
    --project-name "host-time-${name}-${GITHUB_RUN_ID:-local}"
    --file compose.yaml
    --file compose.time.yaml
    --profile time-ptp
  )
  trap '"${compose[@]}" down --volumes --remove-orphans || true' EXIT

  "${compose[@]}" up --detach --no-build time-evidence-ptp
  host_time_wait_for_evidence \
    "${evidence_dir}/hardware-time.otlp.json" "${compose[@]}"
  "${compose[@]}" stop --timeout 10 time-evidence-ptp
  "${compose[@]}" logs --no-color time-evidence-ptp \
    >"${HOST_TIME_WORK}/${name}-collector.log" 2>&1
  host_time_require_clean_log "${HOST_TIME_WORK}/${name}-collector.log"
  if [[ "${expected}" == true ]]; then
    host_time_verify_timing \
      ptp "${evidence_dir}/hardware-time.otlp.json" true
  else
    host_time_require_no_samples "${evidence_dir}/hardware-time.otlp.json"
  fi
)

run_chrony_case \
  chrony config/time/chrony-fixture.conf \
  "${HOST_TIME_SOCKET_DIR}" "${HOST_TIME_CHRONY_EVIDENCE}" true
run_chrony_case \
  chrony-unsync config/time/chrony-unsynchronized-fixture.conf \
  "${HOST_TIME_UNSYNC_SOCKET_DIR}" "${HOST_TIME_CHRONY_UNSYNC_EVIDENCE}" false
run_ptp_case ptp test/time/pmc.fixture "${HOST_TIME_PTP_EVIDENCE}" true
run_ptp_case \
  ptp-unsync test/time/pmc-unsynchronized.fixture \
  "${HOST_TIME_PTP_UNSYNC_EVIDENCE}" false

export HOST_TIME_MEASUREMENT_FINISHED_NS
HOST_TIME_MEASUREMENT_FINISHED_NS="$(date -u +%s%N)"
"${HOST_TIME_PHASE_DIR}/publish-evidence.sh"
