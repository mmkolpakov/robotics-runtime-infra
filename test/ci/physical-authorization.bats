#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
}

@test "positive physical Compose selects logged verification with no network" {
  # shellcheck source=scripts/ci/lib.sh
  source "${ROOT}/scripts/ci/lib.sh"
  ci_set_compose_fixture_env
  docker compose -f "${ROOT}/compose.yaml" -f "${ROOT}/compose.edge-attach.yaml" \
    -f "${ROOT}/compose.real-observation.yaml" -f "${ROOT}/compose.real-observation.test.yaml" \
    --profile real-observation --profile real-observation-test config --format json \
    >"${BATS_TEST_TMPDIR}/model.json"
  run jq -e '
    .services["physical-permit-preflight"] as $p |
    $p.command[0:2] == ["authorize-logged-test", "/test-keys"] and
    $p.network_mode == "none" and $p.read_only == true and
    any($p.volumes[]; .target == "/test-keys" and .read_only == true) and
    .services["physical-runtime-manifest"].depends_on["physical-permit-preflight"].condition
      == "service_completed_successfully"
  ' "${BATS_TEST_TMPDIR}/model.json"
  [ "${status}" -eq 0 ]
}

@test "direct preflight defaults to logged verification and bypass is explicit" {
  run bash -c '
    set -Eeuo pipefail
    source "$1/scripts/ci/physical-attach/authorization.sh"
    work_root="$2"
    permit_ci_run() { printf "%s\n" "$@"; }
    run_test_preflight "$2/positive" "$2/nonces" "$2/verification.json"
  ' _ "${ROOT}" "${BATS_TEST_TMPDIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'\nauthorize-logged-test\n/work/keys\n'* ]]
  [[ "${output}" != *authorize-offline-test* ]]

  run bash -c '
    set -Eeuo pipefail
    source "$1/scripts/ci/physical-attach/authorization.sh"
    work_root="$2"
    permit_ci_run() { printf "%s\n" "$@"; }
    run_test_preflight "$2/positive" "$2/nonces" "$2/verification.json" authorize-offline-test
  ' _ "${ROOT}" "${BATS_TEST_TMPDIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'\nauthorize-offline-test\n/work/keys\n'* ]]
}
