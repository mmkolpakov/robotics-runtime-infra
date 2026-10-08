#!/usr/bin/env bats

setup() {
  bats_require_minimum_version 1.5.0
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  COLLECTOR="${REPOSITORY_ROOT}/scripts/ci/foundation/collect-simulation-provider.sh"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI before these tests}"
  export ROBOTICS_FOUNDATION_PYTHON
  ROBOTICS_FOUNDATION_PYTHON="$(dirname "${ROBOTICS_CONTRACTS_CLI}")/python"
  export PROVIDER_TEST_ROOT="${BATS_TEST_TMPDIR}"
  export PROVIDER_TEST_WORLD="/opt/robotics_ws/install/worlds/empty.sdf"
  export PROVIDER_TEST_MODE=success ROBOTICS_SIMULATOR_SERVICE_NAMESPACE=/simulator
  export PROVIDER_TEST_IMAGE_ID="sha256:$(printf '%064d' 9)"
  export ROBOTICS_SIMULATION_LOCAL_IMAGE_ID="${PROVIDER_TEST_IMAGE_ID}"
  mkdir "${BATS_TEST_TMPDIR}/run"
  cp "${REPOSITORY_ROOT}/test/qualification/fixtures/acceptance-scenario.yaml" \
    "${BATS_TEST_TMPDIR}/run/scenario.yaml"
  cp "${REPOSITORY_ROOT}/test/qualification/fixtures/acceptance-run.json" \
    "${BATS_TEST_TMPDIR}/run/acceptance-run.json"
  cp "${REPOSITORY_ROOT}/ros_ws/src/robotics_runtime_infra/worlds/empty.sdf" \
    "${BATS_TEST_TMPDIR}/world.sdf"
  jq -n '{schema_version: "simulation-conformance.v1", status: "passed",
    service_namespace: "/simulator", steps: 5, step_size_ns: 1000000,
    clock: {playing_ns: 1000000, paused_ns: 2000000, stepped_ns: 7000000, resumed_ns: 8000000}}' \
    >"${BATS_TEST_TMPDIR}/observation.json"
  # Docker observations are fixtures here; the collector, retained files and
  # installed contracts writer are real. Live simulation remains a Linux gate.
  docker() {
    printf '%s\n' "$1" >>"${PROVIDER_TEST_ROOT}/docker-calls.txt"
    if [[ "$1" == inspect ]]; then
      [[ "$2" == --format && "$3" == '{{.Image}}' && "$4" == simulation ]] || return 64
      printf '%s\n' "$PROVIDER_TEST_IMAGE_ID"
      return
    fi
    if [[ "$1" == cp ]]; then
      [[ "$2" == "simulation:${PROVIDER_TEST_WORLD}" ]] || return 64
      cp "${PROVIDER_TEST_ROOT}/world.sdf" "$3"
      if [[ "${PROVIDER_TEST_MODE}" == world_changed && "$3" == */world-after.sdf ]]; then
        printf '\n' >>"$3"
      fi
      return
    fi
    [[ "$1" == exec && "$2" == simulation ]] || return 64
    shift 2
    case "$1" in
      readlink) printf '%s\n' "${PROVIDER_TEST_WORLD}"; return ;;
      test) [[ "$2" == -f && "$3" == "${PROVIDER_TEST_WORLD}" ]]; return ;;
      robotics-entrypoint) shift ;;
      *) return 64 ;;
    esac
    [[ "$1" != timeout ]] || shift 2
    case "$1" in
      ros2)
        if [[ "${PROVIDER_TEST_MODE}" == parameter_changed && -f "${PROVIDER_TEST_ROOT}/probed" ]]; then
          printf '/run/robotics/foreign.sdf\n'
        else
          printf '%s\n' "${PROVIDER_TEST_WORLD}"
        fi
        ;;
      gz) printf '8.11.0\n' ;;
      python3)
        touch "${PROVIDER_TEST_ROOT}/probed"
        if [[ "${PROVIDER_TEST_MODE}" == probe_failed ]]; then
          printf 'simulation control failed: step overshot\n' >&2
          return 42
        fi
        cat "${PROVIDER_TEST_ROOT}/observation.json"
        ;;
      *) return 64 ;;
    esac
  }
  export -f docker
  DESTINATION="${BATS_TEST_TMPDIR}/provider"
}

collect() {
  bash "${COLLECTOR}" simulation "${BATS_TEST_TMPDIR}/run" "${DESTINATION}" \
    "sha256:$(printf '%064d' 1)" "$@"
}

@test "simulation provider collector binds retained configuration and observations" {
  run collect
  [ "${status}" -eq 0 ]
  run "${ROBOTICS_CONTRACTS_CLI}" validate --quiet --schema conformance-result.v1 \
    "${DESTINATION}/conformance.json"
  [ "${status}" -eq 0 ]
  run jq -e --arg digest "$(sha256sum "${DESTINATION}/conformance.json" | cut -d' ' -f1)" \
    'length == 1 and .[0].conformance_result_sha256 == $digest' "${DESTINATION}/bindings.json"
  [ "${status}" -eq 0 ]
  cmp -s "${PROVIDER_TEST_ROOT}/world.sdf" "${DESTINATION}/world.sdf"
  run jq -e --arg identity "$PROVIDER_TEST_IMAGE_ID" \
    '.container_image_id == $identity' "${DESTINATION}/configuration.json"
  [ "${status}" -eq 0 ]
}

@test "sensor provider context uses the same qualified simulator collector" {
  cp "${REPOSITORY_ROOT}/test/accelerators/sensor-provider-scenario.yaml" \
    "${BATS_TEST_TMPDIR}/run/scenario.yaml"
  cp "${REPOSITORY_ROOT}/ros_ws/src/robotics_runtime_infra/worlds/camera.sdf" \
    "${PROVIDER_TEST_ROOT}/world.sdf"
  # The public writer rejects overwrites; create a fresh context for this scenario.
  rm -- "${BATS_TEST_TMPDIR}/run/acceptance-run.json"
  run -0 "$(dirname "${ROBOTICS_CONTRACTS_CLI}")/robotics-acceptance" create-run \
    --scenario "${BATS_TEST_TMPDIR}/run/scenario.yaml" \
    --output "${BATS_TEST_TMPDIR}/run/acceptance-run.json" \
    --domain qualification-domain=observer --time-authority sim_clock --time-source gazebo-clock
  run -0 collect
  run -0 jq -e --slurpfile context "${BATS_TEST_TMPDIR}/run/acceptance-run.json" \
    '.run_id == $context[0].run_id and .status == "passed"' "${DESTINATION}/conformance.json"
}

@test "simulator collector rejects a missing immutable container image ID" {
  export PROVIDER_TEST_IMAGE_ID=local/simulation:dev
  run collect
  [ "${status}" -eq 65 ]
  [[ "${output}" == *'immutable local image ID'* ]]
  [ ! -f "${PROVIDER_TEST_ROOT}/probed" ]
  [ ! -f "${DESTINATION}/bindings.json" ]
}

@test "simulator collector rejects a missing or invalid expected local image ID before probing" {
  local expected
  for expected in '' local/simulation:dev; do
    export ROBOTICS_SIMULATION_LOCAL_IMAGE_ID="${expected}"
    run collect
    [ "${status}" -eq 65 ]
    [[ "${output}" == *'expected simulator local image ID is missing or invalid'* ]]
    [ ! -d "${DESTINATION}" ]
    [ ! -f "${PROVIDER_TEST_ROOT}/probed" ]
  done
}

@test "simulator collector rejects a different valid local image ID before probing" {
  export ROBOTICS_SIMULATION_LOCAL_IMAGE_ID
  ROBOTICS_SIMULATION_LOCAL_IMAGE_ID="sha256:$(printf '%064d' 8)"
  run collect
  [ "${status}" -eq 65 ]
  [[ "${output}" == *'container local image ID does not match the selected image'* ]]
  [ ! -f "${PROVIDER_TEST_ROOT}/probed" ]
  [ ! -f "${DESTINATION}/world.sdf" ]
  [ ! -f "${DESTINATION}/configuration.json" ]
  [ ! -f "${DESTINATION}/bindings.json" ]
  [ ! -f "${DESTINATION}/conformance.json" ]
}

@test "simulation provider collector preserves a probe failure without bindings" {
  export PROVIDER_TEST_MODE=probe_failed
  run collect
  [ "${status}" -eq 42 ]
  [[ "${output}" == *'simulation control failed: step overshot'* ]]
  [ ! -f "${DESTINATION}/bindings.json" ]
  [ ! -f "${DESTINATION}/conformance.json" ]
}

@test "simulation provider collector rejects a world changed during the probe" {
  export PROVIDER_TEST_MODE=world_changed
  run collect
  [ "${status}" -eq 65 ]
  [[ "${output}" == *'world bytes changed during conformance'* ]]
  [ ! -f "${DESTINATION}/bindings.json" ]
}

@test "simulation provider collector rejects a world parameter changed during the probe" {
  export PROVIDER_TEST_MODE=parameter_changed
  run collect
  [ "${status}" -eq 65 ]
  [[ "${output}" == *'world parameter changed during conformance'* ]]
  [ ! -f "${DESTINATION}/bindings.json" ]
}

@test "simulation provider collector rejects paths outside runtime assets" {
  export PROVIDER_TEST_WORLD=/etc/shadow
  run collect
  [ "${status}" -eq 65 ]
  [[ "${output}" == *'outside the runtime asset directories'* ]]
  [ ! -f "${PROVIDER_TEST_ROOT}/probed" ]
  [ ! -f "${DESTINATION}/world.sdf" ]
}

@test "simulation provider collector cannot reuse an earlier successful binding" {
  mkdir "${DESTINATION}"
  printf 'previous\n' >"${DESTINATION}/bindings.json"
  run collect
  [ "${status}" -ne 0 ]
  [ "$(cat "${DESTINATION}/bindings.json")" = previous ]
  [ ! -f "${PROVIDER_TEST_ROOT}/probed" ]
}

prepare_registered_provider() {
  local schema="${BATS_TEST_TMPDIR}/registered-schema.json"
  cp "${REPOSITORY_ROOT}/examples/generic-consumer/scenario.yaml" "${BATS_TEST_TMPDIR}/run/scenario.yaml"
  cp "${REPOSITORY_ROOT}/examples/generic-consumer/inputs/extension.schema.json" "${schema}"
  SCHEMA_OPTION="https://example.org/robotics/generic-consumer.schema.json=${schema}"
  rm "${BATS_TEST_TMPDIR}/run/acceptance-run.json"
  "$(dirname "${ROBOTICS_CONTRACTS_CLI}")/robotics-acceptance" create-run \
    --scenario "${BATS_TEST_TMPDIR}/run/scenario.yaml" \
    --output "${BATS_TEST_TMPDIR}/run/acceptance-run.json" \
    --domain primary=observer --time-authority sim_clock --time-source gazebo-clock \
    --extension-schema "${SCHEMA_OPTION}"
}

@test "registered collector forwards exact selected schema bytes into the real provider writer" {
  prepare_registered_provider
  run collect --extension-schema "${SCHEMA_OPTION}"
  [ "${status}" -eq 0 ]
  [ -s "${DESTINATION}/conformance.json" ]
  [ -e "${PROVIDER_TEST_ROOT}/probed" ]
  run "${ROBOTICS_CONTRACTS_CLI}" validate --quiet --schema conformance-result.v1 "${DESTINATION}/conformance.json"
  [ "${status}" -eq 0 ]
}

@test "missing or changed registered schema refuses before any native collector effect" {
  prepare_registered_provider
  run collect
  [ "${status}" -ne 0 ]
  [[ "${output}" == *extension.validation_failed* ]]
  [ ! -e "${PROVIDER_TEST_ROOT}/docker-calls.txt" ]
  [ ! -e "${DESTINATION}" ]
  printf '\n' >>"${SCHEMA_OPTION#*=}"
  run collect --extension-schema "${SCHEMA_OPTION}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *schema\ digest\ does\ not\ match* ]]
  [ ! -e "${PROVIDER_TEST_ROOT}/docker-calls.txt" ]
  [ ! -e "${DESTINATION}" ]
}

@test "collector schema options cannot replace the trusted output or scenario" {
  run collect --output "${BATS_TEST_TMPDIR}/foreign"
  [ "${status}" -eq 64 ]
  [ ! -e "${PROVIDER_TEST_ROOT}/docker-calls.txt" ]
  [ ! -e "${DESTINATION}" ]
}
