#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/integration/host-time/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo

docker run --detach --name host-chronyd \
  --network none \
  --volume "${HOST_TIME_SOCKET_DIR}:/run/robotics-time" \
  "${HOST_IO_FIXTURE_IMAGE}" >/dev/null
host_time_wait_for_socket /run/robotics-time/chronyd.sock host-chronyd
docker run --detach --name host-chrony-otel \
  --network none \
  --user 100:101 \
  --volume "${HOST_TIME_SOCKET_DIR}:/run/robotics-time" \
  --volume "${HOST_TIME_CHRONY_EVIDENCE}:/evidence" \
  --volume "${PWD}/config/time/otel-chrony.yaml:/config.yaml:ro" \
  "${HOST_TIME_OTEL_IMAGE}" --config=/config.yaml >/dev/null
host_time_wait_for_evidence \
  "${HOST_TIME_CHRONY_EVIDENCE}/hardware-time.otlp.json" \
  host-chronyd host-chrony-otel
docker stop --time 10 host-chrony-otel host-chronyd >/dev/null
docker logs host-chrony-otel >"${HOST_TIME_WORK}/chrony-collector.log" 2>&1
host_time_require_clean_log "${HOST_TIME_WORK}/chrony-collector.log"

docker run --detach --name host-ptp-otel \
  --network none \
  --user 100:101 \
  --volume "${HOST_TIME_PTP_EVIDENCE}:/evidence" \
  --volume "${PWD}/test/time/pmc.fixture:/input/pmc.log:ro" \
  --volume "${PWD}/config/time/otel-ptp.yaml:/config.yaml:ro" \
  "${HOST_TIME_OTEL_IMAGE}" --config=/config.yaml >/dev/null
host_time_wait_for_evidence \
  "${HOST_TIME_PTP_EVIDENCE}/hardware-time.otlp.json" host-ptp-otel
docker stop --time 10 host-ptp-otel >/dev/null
docker logs host-ptp-otel >"${HOST_TIME_WORK}/ptp-collector.log" 2>&1
host_time_require_clean_log "${HOST_TIME_WORK}/ptp-collector.log"

host_time_verify_timing \
  chrony_ntp "${HOST_TIME_CHRONY_EVIDENCE}/hardware-time.otlp.json" true
host_time_verify_timing \
  ptp "${HOST_TIME_PTP_EVIDENCE}/hardware-time.otlp.json" true
