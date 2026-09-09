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
sudo chmod 2770 "${HOST_TIME_SOCKET_DIR}" "${HOST_TIME_UNSYNC_SOCKET_DIR}"

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
  local replay="${6:-}"
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
  if [[ "${expected}" == true ]]; then
    compose+=(--file test/time/compose.ntp.yaml)
  fi
  trap '"${compose[@]}" logs --no-color >"${HOST_TIME_WORK}/${name}-compose.log" 2>&1 || true;
    "${compose[@]}" down --volumes --remove-orphans || true' EXIT

  if [[ -z "${replay}" ]]; then
    "${compose[@]}" up --detach --no-build --wait --wait-timeout 30 time-fixture
  else
    # Re-read the actual positive-case CSV after it is stale; never rewrite its
    # reference time to manufacture a current measurement.
    test -s "${replay}"
    sleep 3
  fi
  if [[ "${expected}" == true ]]; then
    "${compose[@]}" exec -T time-fixture \
      chronyc -n -h /run/robotics-time/chronyd.sock waitsync 60 0.005 20 1
  fi
  "${compose[@]}" up --detach --no-build time-evidence-chrony
  host_time_wait_for_collector time-evidence-chrony "${compose[@]}"
  # Exercise the same timestamp parser and publisher as the host timer. The
  # NTP pair is an isolated fixture, not a qualified lab time source.
  for _ in {1..10}; do
    if [[ -n "${replay}" ]]; then
      tail -n 1 "${replay}"
    else
      "${compose[@]}" exec -T time-fixture \
        chronyc -c -n -h /run/robotics-time/chronyd.sock tracking
    fi |
      tee -a "${HOST_TIME_WORK}/${name}-tracking.csv" |
      sudo bash scripts/time/sample.sh chrony "${socket_dir}" --stdin
    if host_time_has_samples "${evidence_dir}/hardware-time.otlp.json"; then
      break
    fi
    sleep 0.25
  done
  host_time_wait_for_evidence \
    "${evidence_dir}/hardware-time.otlp.json" "${compose[@]}"
  "${compose[@]}" stop --timeout 10 time-evidence-chrony time-fixture
  "${compose[@]}" logs --no-color time-evidence-chrony \
    >"${HOST_TIME_WORK}/${name}-collector.log" 2>&1
  if [[ "${expected}" == true ]]; then
    host_time_require_clean_log "${HOST_TIME_WORK}/${name}-collector.log"
  fi
  host_time_verify_timing \
    chrony_ntp "${evidence_dir}/hardware-time.otlp.json" "${expected}" \
    "$(if [[ -n "${replay}" ]]; then printf true; else printf '%s' "${expected}"; fi)"
)

run_ptp_case() (
  local name="$1"
  local sample="$2"
  local evidence_dir="$3"
  local expected="$4"
  local stale="${5:-false}"
  local sample_dir="${HOST_TIME_WORK}/${name}-samples"
  sudo install -d -o 100 -g 101 -m 2770 "${sample_dir}"
  local compose=(
    env
    ROBOTICS_CHRONY_IDENTITY=100:101
    "ROBOTICS_PTP_SAMPLE_DIR=${sample_dir}"
    "ROBOTICS_TIME_EVIDENCE_DIR=${evidence_dir}"
    docker compose
    --project-name "host-time-${name}-${GITHUB_RUN_ID:-local}"
    --file compose.yaml
    --file compose.time.yaml
    --profile time-ptp
  )
  trap '"${compose[@]}" down --volumes --remove-orphans || true' EXIT

  "${compose[@]}" up --detach --no-build time-evidence-ptp
  host_time_wait_for_collector time-evidence-ptp "${compose[@]}"
  for _ in {1..10}; do
    if [[ "${stale}" == true ]]; then
      cat "${sample}"
    else
      # Fixture PHC is in PTP/TAI; TIME_PROPERTIES_DATA_SET specifies 37s.
      sed -E "s/(ingress_time[[:space:]]+)[0-9]+/\\1$(( $(date -u +%s%N) + 37000000000 ))/" \
        "${sample}"
    fi | sudo bash scripts/time/sample.sh ptp "${sample_dir}" --stdin
    if host_time_has_samples "${evidence_dir}/hardware-time.otlp.json"; then
      break
    fi
    sleep 0.25
  done
  host_time_wait_for_evidence \
    "${evidence_dir}/hardware-time.otlp.json" "${compose[@]}"
  "${compose[@]}" stop --timeout 10 time-evidence-ptp
  "${compose[@]}" logs --no-color time-evidence-ptp \
    >"${HOST_TIME_WORK}/${name}-collector.log" 2>&1
  if [[ "${expected}" == true ]]; then
    host_time_require_clean_log "${HOST_TIME_WORK}/${name}-collector.log"
  fi
  host_time_verify_timing \
    ptp "${evidence_dir}/hardware-time.otlp.json" "${expected}" \
    "$(if [[ "${stale}" == true ]]; then printf true; else printf '%s' "${expected}"; fi)"
)

run_chrony_case \
  chrony config/time/chrony-fixture.conf \
  "${HOST_TIME_SOCKET_DIR}" "${HOST_TIME_CHRONY_EVIDENCE}" true
sudo install -d -o 100 -g 101 -m 2770 "${HOST_TIME_WORK}/replay-socket"
# The Collector writes as the fixture user; the CI runner must also be able to
# read completed evidence. Socket directories keep their restricted group mode.
sudo install -d -o 100 -g 101 -m 0755 "${HOST_TIME_WORK}/chrony-replay"
run_chrony_case \
  chrony-replay config/time/chrony-unsynchronized-fixture.conf \
  "${HOST_TIME_WORK}/replay-socket" "${HOST_TIME_WORK}/chrony-replay" false \
  "${HOST_TIME_WORK}/chrony-tracking.csv"
run_chrony_case \
  chrony-unsync config/time/chrony-unsynchronized-fixture.conf \
  "${HOST_TIME_UNSYNC_SOCKET_DIR}" "${HOST_TIME_CHRONY_UNSYNC_EVIDENCE}" false
run_ptp_case ptp test/time/pmc.fixture "${HOST_TIME_PTP_EVIDENCE}" true
run_ptp_case \
  ptp-unsync test/time/pmc-unsynchronized.fixture \
  "${HOST_TIME_PTP_UNSYNC_EVIDENCE}" false
sudo install -d -o 100 -g 101 -m 0755 "${HOST_TIME_WORK}/ptp-stale"
run_ptp_case ptp-stale test/time/pmc.fixture "${HOST_TIME_WORK}/ptp-stale" false true

export HOST_TIME_MEASUREMENT_FINISHED_NS
HOST_TIME_MEASUREMENT_FINISHED_NS="$(date -u +%s%N)"
"${HOST_TIME_PHASE_DIR}/publish-evidence.sh"
