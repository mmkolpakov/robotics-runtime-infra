#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/integration/host-time/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo

docker run --detach --name host-chronyd-unsync \
  --network none \
  --volume "${HOST_TIME_UNSYNC_SOCKET_DIR}:/run/robotics-time" \
  --volume \
    "${PWD}/config/time/chrony-unsynchronized-fixture.conf:/etc/chrony/chrony.conf:ro" \
  "${HOST_IO_FIXTURE_IMAGE}" >/dev/null
host_time_wait_for_socket \
  /run/robotics-time/chronyd.sock host-chronyd-unsync
docker run --detach --name host-chrony-otel-unsync \
  --network none \
  --user 100:101 \
  --volume "${HOST_TIME_UNSYNC_SOCKET_DIR}:/run/robotics-time" \
  --volume "${HOST_TIME_CHRONY_UNSYNC_EVIDENCE}:/evidence" \
  --volume "${PWD}/config/time/otel-chrony.yaml:/config.yaml:ro" \
  "${HOST_TIME_OTEL_IMAGE}" --config=/config.yaml >/dev/null
host_time_wait_for_evidence \
  "${HOST_TIME_CHRONY_UNSYNC_EVIDENCE}/hardware-time.otlp.json" \
  host-chronyd-unsync host-chrony-otel-unsync
docker stop --time 10 \
  host-chrony-otel-unsync host-chronyd-unsync >/dev/null

docker run --detach --name host-ptp-otel-unsync \
  --network none \
  --user 100:101 \
  --volume "${HOST_TIME_PTP_UNSYNC_EVIDENCE}:/evidence" \
  --volume \
    "${PWD}/test/time/pmc-unsynchronized.fixture:/input/pmc.log:ro" \
  --volume "${PWD}/config/time/otel-ptp.yaml:/config.yaml:ro" \
  "${HOST_TIME_OTEL_IMAGE}" --config=/config.yaml >/dev/null
sleep 2
docker stop --time 10 host-ptp-otel-unsync >/dev/null
test -s "${HOST_TIME_PTP_UNSYNC_EVIDENCE}/hardware-time.otlp.json"

host_time_verify_timing \
  chrony_ntp \
  "${HOST_TIME_CHRONY_UNSYNC_EVIDENCE}/hardware-time.otlp.json" false
host_time_require_no_samples \
  "${HOST_TIME_PTP_UNSYNC_EVIDENCE}/hardware-time.otlp.json"
