#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  source "${ROOT}/scripts/ci/foundation/lib.sh"
  CONSUMER="${BATS_TEST_TMPDIR}/consumer"
  mkdir -p "${CONSUMER}/inputs"
  printf 'original bytes\n' >"${CONSUMER}/inputs/artifact file.txt"
  printf '{"type":"object"}\n' >"${CONSUMER}/inputs/schema.json"
  ARGUMENTS="${CONSUMER}/artifact-arguments.txt"
}

@test "empty optional arguments preserve the stock inventory vector" {
  FOUNDATION_ARTIFACT_ARGUMENTS=(stale)
  foundation_load_artifact_arguments "${CONSUMER}" ""
  [ "${#FOUNDATION_ARTIFACT_ARGUMENTS[@]}" -eq 0 ]
}

@test "artifact and extension paths retain spaces and internal aliases" {
  ln -s "inputs/artifact file.txt" "${CONSUMER}/artifact-alias"
  printf '%s\n' --artifact 'other_evidence:consumer/data=artifact-alias' \
    --extension-schema 'https://example.org/schema.json=inputs/schema.json' >"${ARGUMENTS}"
  foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
  [ "${#FOUNDATION_ARTIFACT_ARGUMENTS[@]}" -eq 4 ]
  [ "${FOUNDATION_ARTIFACT_ARGUMENTS[1]}" = "other_evidence:consumer/data=${CONSUMER}/inputs/artifact file.txt" ]
  [ "${FOUNDATION_ARTIFACT_ARGUMENTS[3]}" = "https://example.org/schema.json=${CONSUMER}/inputs/schema.json" ]
  [ "$(cat "${CONSUMER}/inputs/artifact file.txt")" = 'original bytes' ]
}

@test "literal shell text in a subject never executes" {
  cd "${BATS_TEST_TMPDIR}"
  printf '%s\n' --artifact 'other_evidence:$(touch injected)=inputs/schema.json' >"${ARGUMENTS}"
  foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
  [[ "${FOUNDATION_ARTIFACT_ARGUMENTS[1]}" == 'other_evidence:$(touch injected)='* ]]
  [ ! -e injected ]
}

@test "consumer flags cannot select output or verification trust" {
  local option
  for option in --output --bundle --key --policy --trusted-root --scenario; do
    printf '%s\n' "${option}" inputs/schema.json >"${ARGUMENTS}"
    run foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
    [ "${status}" -eq 64 ]
    [[ "${output}" == *'unsupported consumer artifact argument'* ]]
  done
}

@test "an incomplete argument pair is rejected" {
  printf '%s\n' --artifact >"${ARGUMENTS}"
  run foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *'requires a value'* ]]
}

@test "the final argument does not require a trailing newline" {
  printf '%s\n%s' --artifact 'other_evidence:data=inputs/schema.json' >"${ARGUMENTS}"
  foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
  [ "${#FOUNDATION_ARTIFACT_ARGUMENTS[@]}" -eq 2 ]
}

@test "sibling prefixes and symlinks leaving the consumer are rejected" {
  mkdir -p "${CONSUMER}-foreign"
  printf 'foreign\n' >"${CONSUMER}-foreign/data"
  ln -s "${CONSUMER}-foreign/data" "${CONSUMER}/outside"
  local path
  for path in "../consumer-foreign/data" outside; do
    printf '%s\n' --artifact "other_evidence:data=${path}" >"${ARGUMENTS}"
    run foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
    [ "${status}" -eq 64 ]
    [[ "${output}" == *'outside its repository'* ]]
  done
}

@test "the arguments file cannot escape through a symlink" {
  printf '%s\n' --artifact 'other_evidence:data=inputs/schema.json' \
    >"${BATS_TEST_TMPDIR}/outside-arguments"
  ln -s "${BATS_TEST_TMPDIR}/outside-arguments" "${ARGUMENTS}"
  run foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
  [ "${status}" -eq 64 ]
}

@test "directories and absent artifact paths are rejected" {
  local path
  for path in inputs inputs/absent.json; do
    printf '%s\n' --artifact "other_evidence:data=${path}" >"${ARGUMENTS}"
    run foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
    [ "${status}" -eq 64 ]
  done
}

@test "raw and symlink-target control characters cannot select a trimmed filename" {
  printf 'different newline file\n' >"${CONSUMER}/inputs/schema.json"$'\n'
  run foundation_consumer_file "${CONSUMER}" "inputs/schema.json"$'\n'
  [ "${status}" -eq 64 ]
  ln -s "inputs/schema.json"$'\n' "${CONSUMER}/newline-alias"
  run foundation_consumer_file "${CONSUMER}" newline-alias
  [ "${status}" -eq 64 ]
  [ "$(cat "${CONSUMER}/inputs/schema.json")" = '{"type":"object"}' ]
}
