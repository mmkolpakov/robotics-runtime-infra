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
    .clock == {basis: "ros_time", sync_protocol: "sim_clock", offset_ms: 0, drift_ppm: 0} and
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

@test "stock simulation rejects clock declarations that contradict its ROS time" {
  local time_mode basis
  for time_mode in simulation_realtime simulation_stepped; do
    for basis in system_time ptp_time; do
      printf 'previous\n' >"${OUTPUT}"
      run env ROBOTICS_TIME_MODE="${time_mode}" ROBOTICS_CLOCK_BASIS="${basis}" \
        bash "${EMITTER}" "${OUTPUT}"
      assert_previous_output_preserved
      [[ "${output}" == *'simulation requires ros_time with sim_clock'* ]]
    done
    printf 'previous\n' >"${OUTPUT}"
    run env ROBOTICS_TIME_MODE="${time_mode}" ROBOTICS_CLOCK_PROTOCOL=none \
      bash "${EMITTER}" "${OUTPUT}"
    assert_previous_output_preserved
    [[ "${output}" == *'simulation requires ros_time with sim_clock'* ]]
  done
}

prepare_recorded_playback() {
  PLAYBACK_RUN="${BATS_TEST_TMPDIR}/playback"
  mkdir -p "${PLAYBACK_RUN}/configuration" "${PLAYBACK_RUN}/logs" "${PLAYBACK_RUN}/source"
  cp -R "${REPOSITORY_ROOT}/test/fixtures/playback/golden" "${PLAYBACK_RUN}/source/bag"
  cp -R "${REPOSITORY_ROOT}/config/playback" "${PLAYBACK_RUN}/source/qos"
  cp "${REPOSITORY_ROOT}/config/qualification/recorded-playback.json" "${PLAYBACK_RUN}/profile.json"
  printf '0.26.9-fixture\n' >"${PLAYBACK_RUN}/configuration/rosbag2-version.txt"
  printf 'resume accepted\n' >"${PLAYBACK_RUN}/logs/playback-gate.log"
  printf 'data: 42\n---\n' >"${PLAYBACK_RUN}/logs/playback-probe.log"
  local image_id path
  image_id="sha256:$(printf '%064d' 4)"
  jq -n --arg image "${image_id}" --arg log_sha256 \
    "$(sha256sum "${PLAYBACK_RUN}/logs/playback-probe.log" | cut -d' ' -f1)" \
    '{gate_exit_code: 0, probe_exit_code: 0, gate_logs_exit_code: 0, probe_logs_exit_code: 0,
      playback_image_id: $image, gate_image_id: $image, probe_image_id: $image,
      probe_log_sha256: $log_sha256}' >"${PLAYBACK_RUN}/observation.json"
  printf '{}\n' | tee "${PLAYBACK_RUN}/playback-image.json" "${PLAYBACK_RUN}/probe-image.json" \
    "${PLAYBACK_RUN}/compose-original.json" >"${PLAYBACK_RUN}/compose.json"
  while IFS= read -r -d '' path; do
    jq -cn --arg path "${path#"${PLAYBACK_RUN}/"}" \
      --arg sha256 "$(sha256sum "${path}" | cut -d' ' -f1)" --argjson size "$(stat -c '%s' "${path}")" \
      '{path: $path, sha256: $sha256, size_bytes: $size}'
  done < <(find "${PLAYBACK_RUN}/source" -type f -print0) >"${BATS_TEST_TMPDIR}/sources.jsonl"
  jq -n --arg image "${image_id}" --slurpfile sources "${BATS_TEST_TMPDIR}/sources.jsonl" \
    '{version: "0.26.9-fixture", expected_playback_image_id: $image,
      expected_probe_image_id: $image, sources: $sources}' >"${PLAYBACK_RUN}/configuration/provider.json"
  PLAYBACK_RESULT="${PLAYBACK_RUN}/conformance-result.json"
}

run_playback_provider() {
  run "${ROBOTICS_FOUNDATION_PYTHON:?use the installed foundation interpreter}" \
    "${REPOSITORY_ROOT}/scripts/ci/integration/create-playback-provider.py" \
    --run-dir "${PLAYBACK_RUN}" --host-run-dir "${PLAYBACK_RUN}" \
    --run-id run-7a858e79-f3a3-4c29-b51a-dbcf8c652e9d --subject-digest "${ROBOTICS_OCI_DIGEST}" \
    --output "${PLAYBACK_RESULT}"
}

@test "recorded playback retains its distinct clock and real recording source binding" {
  prepare_recorded_playback
  run_playback_provider
  [ "${status}" -eq 0 ]
  printf '%s\n' "${output}" >"${ROBOTICS_PROVIDER_BINDINGS_FILE}"
  local -a playback_environment
  run "${ROBOTICS_FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}/compose.playback.yaml" <<'PY'
import sys
from robotics_runtime_contracts import load_mapping
for name, value in load_mapping(sys.argv[1])["services"]["runtime-manifest"]["environment"].items():
    print(f"{name}={value}")
PY
  [ "${status}" -eq 0 ]
  mapfile -t playback_environment <<<"${output}"
  run env "${playback_environment[@]}" bash "${EMITTER}" "${OUTPUT}"
  [ "${status}" -eq 0 ]
  run jq -e --arg result_sha "$(sha256sum "${PLAYBACK_RESULT}" | cut -d' ' -f1)" '
    .execution.time_mode == "playback_clocked" and .clock.sync_protocol == "playback_clock" and
    .provider_bindings[0].provider.kind == "recording_source" and
    .provider_bindings[0].provider.implementation_id == "rosbag2_player" and
    .provider_bindings[0].capabilities == ["playback_probe_delivery"] and
    .provider_bindings[0].conformance_result_sha256 == $result_sha' "${OUTPUT}"
  [ "${status}" -eq 0 ]
  run "${ROBOTICS_CONTRACTS_CLI}" validate --quiet "${PLAYBACK_RESULT}"
  [ "${status}" -eq 0 ]
  run jq -e '.checks[0].observed_value == 1 and
    any(.evidence[]; .uri | endswith("/source/bag/golden_0.mcap"))' "${PLAYBACK_RESULT}"
  [ "${status}" -eq 0 ]
}

@test "playback provider refuses failed observations without replacing previous output" {
  local change
  for change in '.gate_exit_code = 1' '.probe_exit_code = 124' '.probe_logs_exit_code = 42' \
    'del(.probe_image_id)' '.playback_image_id = "sha256:bad"' '.gate_image_id = "sha256:bad"' '.probe_image_id = "sha256:bad"'; do
    prepare_recorded_playback
    jq "${change}" "${PLAYBACK_RUN}/observation.json" >"${BATS_TEST_TMPDIR}/changed.json"
    mv "${BATS_TEST_TMPDIR}/changed.json" "${PLAYBACK_RUN}/observation.json"
    if [[ "${change}" == 'del(.probe_image_id)' ]]; then
      jq 'del(.expected_probe_image_id)' "${PLAYBACK_RUN}/configuration/provider.json" \
        >"${BATS_TEST_TMPDIR}/changed.json"
      mv "${BATS_TEST_TMPDIR}/changed.json" "${PLAYBACK_RUN}/configuration/provider.json"
    fi
    printf 'previous\n' >"${PLAYBACK_RESULT}"
    run_playback_provider
    [ "${status}" -ne 0 ]
    [ "$(cat "${PLAYBACK_RESULT}")" = previous ]
    [[ "${output}" != '[{'* ]]
    rm -rf "${PLAYBACK_RUN}"
  done
}

@test "playback provider refuses missing data even with successful statuses and matching log hash" {
  prepare_recorded_playback
  printf 'no recorded message\n' >"${PLAYBACK_RUN}/logs/playback-probe.log"
  jq --arg sha "$(sha256sum "${PLAYBACK_RUN}/logs/playback-probe.log" | cut -d' ' -f1)" \
    '.probe_log_sha256 = $sha' "${PLAYBACK_RUN}/observation.json" >"${BATS_TEST_TMPDIR}/changed.json"
  mv "${BATS_TEST_TMPDIR}/changed.json" "${PLAYBACK_RUN}/observation.json"
  run_playback_provider
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'did not receive an Int32'* ]]
  [ ! -e "${PLAYBACK_RESULT}" ]
}

@test "playback provider refuses source drift and cannot overwrite retained inputs" {
  prepare_recorded_playback
  printf changed >>"${PLAYBACK_RUN}/source/bag/golden_0.mcap"
  run_playback_provider
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'differs from the executed snapshot'* ]]
  [ ! -e "${PLAYBACK_RESULT}" ]
  PLAYBACK_RESULT="${PLAYBACK_RUN}/source/bag/golden_0.mcap"
  local before
  before="$(sha256sum "${PLAYBACK_RESULT}")"
  run_playback_provider
  [ "${status}" -ne 0 ]
  [ "$(sha256sum "${PLAYBACK_RESULT}")" = "${before}" ]
}

@test "playback provider refuses metadata naming an MCAP absent from the executed snapshot" {
  prepare_recorded_playback
  local metadata="${PLAYBACK_RUN}/source/bag/metadata.yaml"
  sed -i 's/golden_0.mcap/not-retained.mcap/g' "${metadata}"
  jq --arg digest "$(sha256sum "${metadata}" | cut -d' ' -f1)" \
    --argjson size "$(stat -c '%s' "${metadata}")" '
    .sources |= map(if .path == "source/bag/metadata.yaml" then
      .sha256 = $digest | .size_bytes = $size else . end)
  ' "${PLAYBACK_RUN}/configuration/provider.json" >"${BATS_TEST_TMPDIR}/changed.json"
  mv "${BATS_TEST_TMPDIR}/changed.json" "${PLAYBACK_RUN}/configuration/provider.json"
  run_playback_provider
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'MCAP files differ from the selected bag metadata'* ]]
  [ ! -e "${PLAYBACK_RESULT}" ]
}
