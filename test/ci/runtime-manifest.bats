#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  EMITTER="${REPOSITORY_ROOT}/docker/runtime/emit-runtime-manifest"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI before these tests}"
  export ROBOTICS_CONTRACTS_CLI
  export ROBOTICS_FOUNDATION_LOCK="${REPOSITORY_ROOT}/foundation.repos"
  export ROBOTICS_RUNTIME_ID=fixture.runtime
  export ROBOTICS_OCI_DIGEST="sha256:$(printf '%064d' 1)"
  export ROBOTICS_OCI_REFERENCE="ghcr.io/example/runtime@${ROBOTICS_OCI_DIGEST}"
  export ROBOTICS_INFRA_REVISION="$(printf '%040d' 2)"
  export ROBOTICS_HOST_PLATFORM_FILE="${BATS_TEST_TMPDIR}/host.json"
  export ROBOTICS_PROVIDER_BINDINGS_FILE="${BATS_TEST_TMPDIR}/providers.json"
  export ROS_DISTRO=jazzy ROS_DOMAIN_ID=042 RMW_IMPLEMENTATION=rmw_fastrtps_cpp
  export FASTRTPS_DEFAULT_PROFILES_FILE="${BATS_TEST_TMPDIR}/middleware.xml"
  export RUNTIME_TEST_OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
  export RUNTIME_TEST_ROS_STATUS=0
  printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"${RUNTIME_TEST_OS_RELEASE_FILE}"
  printf '<profiles/>\n' >"${FASTRTPS_DEFAULT_PROFILES_FILE}"
  jq -n '{os: "fixture_host", os_version: "test", architecture: "x86_64",
    kernel: "fixture-host-kernel"}' >"${ROBOTICS_HOST_PLATFORM_FILE}"
  jq -n --arg digest "$(printf '%064d' 3)" '[{
    target_id: "simulation-primary",
    provider: {kind: "simulator", implementation_id: "gz_sim", version: "8.10.0",
      configuration_sha256: $digest},
    qualification_profile_sha256: $digest, conformance_result_sha256: $digest,
    capabilities: ["simulated_physics"]
  }]' >"${ROBOTICS_PROVIDER_BINDINGS_FILE}"
  # Only OS/package observations are fixtures. Serialization and validation use
  # the actual installed contracts CLI; real ROS/image coverage is a separate gate.
  source() {
    if [[ "$1" == /etc/os-release ]]; then
      builtin source "${RUNTIME_TEST_OS_RELEASE_FILE}"
    else
      builtin source "$@"
    fi
  }
  ros2() {
    [[ "$#" -eq 5 && "$1" == pkg && "$2" == xml &&
      "$3" == rmw_fastrtps_cpp && "$4" == --tag && "$5" == version ]] || return 64
    [[ "${RUNTIME_TEST_ROS_STATUS}" -eq 0 ]] || return "${RUNTIME_TEST_ROS_STATUS}"
    printf '8.4.1-fixture-package'
  }
  export -f source ros2
  OUTPUT="${BATS_TEST_TMPDIR}/runtime.json"
}

assert_previous_output_preserved() {
  [ "${status}" -ne 0 ]
  [ "$(cat "${OUTPUT}")" = previous ]
  [ -z "$(find "${BATS_TEST_TMPDIR}" -name '.runtime-*' -print -quit)" ]
}

@test "runtime producer uses the contracts writer and observed v1 fields" {
  run bash "${EMITTER}" "${OUTPUT}"
  [ "${status}" -eq 0 ]
  run "${ROBOTICS_CONTRACTS_CLI}" validate --quiet "${OUTPUT}"
  [ "${status}" -eq 0 ]
  if [[ "$(uname -s)" == Linux ]]; then
    [ "$(stat -c '%a' "${OUTPUT}")" = 444 ]
  fi
  run jq -e --arg digest "${ROBOTICS_OCI_DIGEST}" '
    .schema_version == "runtime-manifest.v1" and .execution_subject.digest == $digest and
    .host_platform.os == "fixture_host" and .execution_platform.os == "ubuntu" and
    .ros.domain_id == 42 and .ros.rmw_version == "8.4.1-fixture-package" and
    .components.contracts_revision == .components.harness_revision and
    .provider_bindings[0].target_id == "simulation-primary" and
    (.data_plane.middleware_configuration_sha256 | length) == 64 and
    (has("oci_image") or has("gazebo") or has("host") | not)' "${OUTPUT}"
  [ "${status}" -eq 0 ]
}

@test "runtime producer leaves existing output intact when bindings are missing" {
  printf 'previous\n' >"${OUTPUT}"
  printf '[]\n' >"${ROBOTICS_PROVIDER_BINDINGS_FILE}"
  run bash "${EMITTER}" "${OUTPUT}"
  assert_previous_output_preserved
  [[ "${output}" == *provider_bindings* ]]
}

@test "runtime producer rejects out of range ROS domains through contracts validation" {
  printf 'previous\n' >"${OUTPUT}"
  export ROS_DOMAIN_ID=233
  run bash "${EMITTER}" "${OUTPUT}"
  assert_previous_output_preserved
  [[ "${output}" == *domain_id* ]]
}

@test "runtime producer rejects concatenated provider documents" {
  printf 'previous\n' >"${OUTPUT}"
  printf '[]\n[]\n' >"${ROBOTICS_PROVIDER_BINDINGS_FILE}"
  run bash "${EMITTER}" "${OUTPUT}"
  assert_previous_output_preserved
  [[ "${output}" == *'expected one provider bindings array'* ]]
}

@test "runtime producer requires an installed RMW version" {
  printf 'previous\n' >"${OUTPUT}"
  export RUNTIME_TEST_ROS_STATUS=42
  run bash "${EMITTER}" "${OUTPUT}"
  [ "${status}" -eq 42 ]
  assert_previous_output_preserved
}
