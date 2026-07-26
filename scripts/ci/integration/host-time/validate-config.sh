#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/integration/host-time/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo

docker run --rm \
  --volume "${PWD}:/project:ro" \
  --entrypoint bash "${HOST_IO_FIXTURE_IMAGE}" -euo pipefail -c '
    udevadm verify /project/config/udev/99-robotics-serial.rules
    systemd-analyze verify \
      /project/systemd/robotics-ptp-sample.service \
      /project/systemd/robotics-ptp-sample.timer \
      /project/systemd/robotics-can-observation@.service
    systemd-tmpfiles --create /project/tmpfiles.d/robotics-time.conf
    test -f /run/robotics-time/pmc.log
  '
docker run --rm \
  --volume "${PWD}/config/time:/config:ro" \
  "${HOST_TIME_OTEL_IMAGE}" validate --config=/config/otel-ptp.yaml
