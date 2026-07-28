#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  COMPOSE_FILE="${REPOSITORY_ROOT}/compose.zenoh.yaml"
  RUNNER="${REPOSITORY_ROOT}/test/zenoh/run"
  FOUNDATION_VALIDATION="${REPOSITORY_ROOT}/scripts/ci/foundation/validate-foundation.sh"
}

@test "Zenoh bridges allow the typed Trace Context topic" {
  local config

  for config in \
    "${REPOSITORY_ROOT}/config/zenoh/source.json5" \
    "${REPOSITORY_ROOT}/config/zenoh/destination.json5"; do
    run grep -c '"\^/robotics/trace_context\$"' "${config}"
    [ "${status}" -eq 0 ]
    [ "${output}" -eq 2 ]
    run grep -F '/robotics/qualification' "${config}"
    [ "${status}" -eq 1 ]
  done
}

@test "Zenoh probes write reports as the host user" {
  run grep -F \
    'user: "${ROBOTICS_HOST_UID:-1000}:${ROBOTICS_HOST_GID:-1000}"' \
    "${COMPOSE_FILE}"
  [ "${status}" -eq 0 ]

  run grep -E \
    'export ROBOTICS_HOST_(UID|GID)=.*id -[ug]' \
    "${RUNNER}"
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | wc -l)" -eq 2 ]
}

@test "Zenoh bridges inspect the canonical ROS distribution" {
  run grep -A1 '^  environment:$' "${COMPOSE_FILE}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ROS_DISTRO: jazzy"* ]]
}

@test "Zenoh runner isolates Compose and report state" {
  run grep -F \
    'readonly project_name="robotics-zenoh-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}-${RANDOM}"' \
    "${RUNNER}"
  [ "${status}" -eq 0 ]
  run grep -F \
    'readonly report_dir="${report_root}/${project_name}"' \
    "${RUNNER}"
  [ "${status}" -eq 0 ]
  run grep -E -- '--remove-orphans|rm -rf' "${RUNNER}"
  [ "${status}" -eq 1 ]
}

@test "Zenoh transport qualification has one canonical evaluator and a zero-loss policy" {
  run grep -F 'robotics-acceptance transport-evaluate' "${COMPOSE_FILE}"
  [ "${status}" -eq 0 ]
  run grep -F '"max_loss_ratio": 0' \
    "${REPOSITORY_ROOT}/test/zenoh/prepare_qualification.py"
  [ "${status}" -eq 0 ]
  run grep -F \
    'test/zenoh/test_transport_qualification.py' \
    "${FOUNDATION_VALIDATION}"
  [ "${status}" -eq 0 ]
  run grep -F '.schema_version == "transport-qualification-result.v1"' "${RUNNER}"
  [ "${status}" -eq 0 ]
  run grep -F '.verdict.status == "passed"' "${RUNNER}"
  [ "${status}" -eq 0 ]
  run grep -E \
    'acceptance-scenario|acceptance-run|build_acceptance_result|per_domain_result|gazebo_physics' \
    "${REPOSITORY_ROOT}/test/zenoh/prepare_qualification.py"
  [ "${status}" -eq 1 ]
  [ ! -e "${REPOSITORY_ROOT}/config/zenoh/acceptance-scenario.json" ]
  [ ! -e "${REPOSITORY_ROOT}/config/zenoh/channel-observation.jq" ]
}
