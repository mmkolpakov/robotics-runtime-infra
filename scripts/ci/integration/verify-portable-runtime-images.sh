#!/usr/bin/env bash
set -Eeuo pipefail

docker compose --profile test run --rm --no-deps edge-smoke
docker compose --profile test run --rm --no-deps sensor-smoke
docker compose --profile test run --rm --no-deps inference-cpu-smoke
docker run --rm "${OBSERVER_IMAGE}" robotics-acceptance --version
docker run --rm "${EVIDENCE_IMAGE}" versions
docker run --rm "${PERMIT_PREFLIGHT_IMAGE}" versions
docker run --rm --entrypoint cat "${HOST_IO_FIXTURE_IMAGE}" \
  /usr/share/robotics-runtime/host-io-fixture-packages.tsv \
  > "${RUNNER_TEMP}/host-io-fixture-packages.tsv"
grep -Fxq $'can-utils\t2023.03-1\tamd64' \
  "${RUNNER_TEMP}/host-io-fixture-packages.tsv"
grep -Fxq $'chrony\t4.5-1ubuntu4.2\tamd64' \
  "${RUNNER_TEMP}/host-io-fixture-packages.tsv"
grep -Fxq $'iproute2\t6.1.0-1ubuntu6.3\tamd64' \
  "${RUNNER_TEMP}/host-io-fixture-packages.tsv"
grep -Fxq $'linuxptp\t4.0-1ubuntu1.1\tamd64' \
  "${RUNNER_TEMP}/host-io-fixture-packages.tsv"
grep -Fxq $'systemd\t255.4-1ubuntu8.16\tamd64' \
  "${RUNNER_TEMP}/host-io-fixture-packages.tsv"
grep -Fxq $'udev\t255.4-1ubuntu8.16\tamd64' \
  "${RUNNER_TEMP}/host-io-fixture-packages.tsv"
docker run --rm --entrypoint test "${HOST_IO_FIXTURE_IMAGE}" \
  ! -s /etc/machine-id
