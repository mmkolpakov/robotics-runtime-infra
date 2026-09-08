#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  VALIDATOR="${REPOSITORY_ROOT}/scripts/ci/foundation/validate-caller-documents.sh"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI before these tests}"
  export ROBOTICS_CONTRACTS_CLI
  CONSUMER="${BATS_TEST_TMPDIR}/consumer"
  mkdir "${CONSUMER}"
  cp "${REPOSITORY_ROOT}/test/qualification/fixtures/acceptance-scenario.yaml" \
    "${CONSUMER}/scenario with spaces.yaml"
  cp "${REPOSITORY_ROOT}/test/qualification/fixtures/runtime-manifest.json" \
    "${CONSUMER}/runtime.json"
}

@test "caller validation accepts explicit roles with spaces and CRLF entries" {
  DOCUMENTS=$'acceptance-scenario.v1=scenario with spaces.yaml\r\nruntime-manifest.v1=runtime.json\r\n' \
    run bash "${VALIDATOR}" "${CONSUMER}"
  [ "${status}" -eq 0 ]
}

@test "caller validation rejects a valid document in the wrong role" {
  run "${ROBOTICS_CONTRACTS_CLI}" validate --schema runtime-manifest.v1 "${CONSUMER}/runtime.json"
  [ "${status}" -eq 0 ]
  DOCUMENTS='acceptance-scenario.v1=runtime.json' run bash "${VALIDATOR}" "${CONSUMER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *'[schema.validation_failed]'* ]]
}

@test "caller validation requires an explicit role instead of trusting the document" {
  DOCUMENTS='runtime.json' run bash "${VALIDATOR}" "${CONSUMER}"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *'expected SCHEMA=PATH'* ]]
}

@test "caller validation rejects an empty document list" {
  DOCUMENTS=$'\r\n\n' run bash "${VALIDATOR}" "${CONSUMER}"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *'no caller documents were specified'* ]]
}

@test "caller validation rejects traversal out of the repository" {
  cp "${CONSUMER}/runtime.json" "${BATS_TEST_TMPDIR}/outside.json"
  DOCUMENTS='runtime-manifest.v1=../outside.json' run bash "${VALIDATOR}" "${CONSUMER}"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *'document escapes caller repository'* ]]
}

@test "caller validation rejects unknown roles through the contracts catalogue" {
  DOCUMENTS='invented-document.v1=runtime.json' run bash "${VALIDATOR}" "${CONSUMER}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'invented-document.v1'* ]]
}
