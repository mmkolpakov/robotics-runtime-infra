#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
actual_packages="${RUNNER_TEMP}/host-io-fixture-packages.tsv"
expected_packages="${root}/docker/apt/host-io-fixture-packages.lock"

docker compose --profile test run --rm --no-deps edge-smoke
docker compose --profile test run --rm --no-deps sensor-smoke
docker compose --profile test run --rm --no-deps inference-cpu-smoke
docker run --rm "${OBSERVER_IMAGE}" robotics-acceptance --version
docker run --rm "${EVIDENCE_IMAGE}" versions
docker run --rm "${PERMIT_PREFLIGHT_IMAGE}" versions
docker run --rm --entrypoint cat "${HOST_IO_FIXTURE_IMAGE}" \
  /usr/share/robotics-runtime/host-io-fixture-packages.tsv \
  > "${actual_packages}"
diff -u "${expected_packages}" "${actual_packages}"
docker run --rm --entrypoint test "${HOST_IO_FIXTURE_IMAGE}" \
  ! -s /etc/machine-id
