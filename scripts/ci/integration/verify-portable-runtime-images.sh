#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
actual_packages="${RUNNER_TEMP}/host-io-fixture-packages.tsv"
expected_packages="${root}/docker/apt/host-io-fixture-packages.lock"

docker compose --profile test run --rm --no-deps edge-smoke
docker compose --profile test run --rm --no-deps sensor-smoke
docker run --rm "${OBSERVER_IMAGE}" robotics-acceptance --version
docker run --rm "${EVIDENCE_IMAGE}" versions
docker run --rm "${PERMIT_PREFLIGHT_IMAGE}" versions
docker run --rm "${PERMIT_PREFLIGHT_CI_IMAGE}" versions
docker run --rm --entrypoint sh "${PERMIT_PREFLIGHT_IMAGE}" -c \
  'set -eu
   test ! -e /usr/local/bin/permit-preflight-ci
   ! grep -E "authorize-(logged|offline)-test|verify-offline-test-attestation|--insecure-ignore-tlog" \
     /usr/local/bin/permit-preflight
   # Core inspects bypass arguments to report the truth; it exposes no CI mode.
   ! grep -E "authorize-(logged|offline)-test|verify-offline-test-attestation" \
     /usr/local/lib/robotics-runtime/permit-preflight-core.sh'
docker run --rm --entrypoint cat "${HOST_IO_FIXTURE_IMAGE}" \
  /usr/share/robotics-runtime/host-io-fixture-packages.tsv \
  > "${actual_packages}"
diff -u "${expected_packages}" "${actual_packages}"
docker run --rm --entrypoint test "${HOST_IO_FIXTURE_IMAGE}" \
  ! -s /etc/machine-id
