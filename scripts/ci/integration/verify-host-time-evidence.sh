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
"${HOST_TIME_PHASE_DIR}/verify-synchronized.sh"
"${HOST_TIME_PHASE_DIR}/verify-unsynchronized.sh"
export HOST_TIME_MEASUREMENT_FINISHED_NS
HOST_TIME_MEASUREMENT_FINISHED_NS="$(date -u +%s%N)"
"${HOST_TIME_PHASE_DIR}/publish-evidence.sh"
