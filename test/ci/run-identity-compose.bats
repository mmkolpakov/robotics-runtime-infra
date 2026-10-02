#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
}

@test "the base simulation model remains usable without an acceptance run" {
  run env -u ROBOTICS_RUN_ID -u ROBOTICS_DOMAIN_ID \
    docker compose -f "${ROOT}/compose.yaml" config --quiet
  [ "${status}" -eq 0 ]
  [[ "${output}" != *'variable is not set'* ]]
}

@test "evidence producing overlays reject an unset run identity" {
  local overlay
  for overlay in evidence record sensor-inference zenoh; do
    run env -u ROBOTICS_RUN_ID ROBOTICS_DOMAIN_ID=primary \
      docker compose -f "${ROOT}/compose.yaml" -f "${ROOT}/compose.${overlay}.yaml" config --quiet
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'ROBOTICS_RUN_ID is required'* ]]
  done
}

@test "sensor inference rejects an unset observation domain" {
  run env -u ROBOTICS_DOMAIN_ID ROBOTICS_RUN_ID=run-00000000-0000-4000-8000-000000000001 \
    docker compose -f "${ROOT}/compose.yaml" -f "${ROOT}/compose.sensor-inference.yaml" config --quiet
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'ROBOTICS_DOMAIN_ID is required'* ]]
}
