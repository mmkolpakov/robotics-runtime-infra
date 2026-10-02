#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
}

@test "ament Python packages follow the ROS 2 package template" {
  package=ros_ws/src/robotics_observability/package.xml

  run grep -F '<build_type>ament_python</build_type>' "${package}"
  [ "${status}" -eq 0 ]

  run grep -F '<buildtool_depend>ament_python</buildtool_depend>' "${package}"
  [ "${status}" -eq 1 ]

  run grep -F 'extras_require={"test": ["pytest"]}' \
    ros_ws/src/robotics_observability/setup.py
  [ "${status}" -eq 0 ]
}

@test "locked OpenTelemetry dependencies are excluded once from rosdep" {
  local dependency

  for dependency in \
    opentelemetry-api \
    opentelemetry-exporter-otlp-proto-http \
    opentelemetry-sdk; do
    run grep -F \
      "<exec_depend>python3-${dependency}-pip</exec_depend>" \
      ros_ws/src/robotics_observability/package.xml
    [ "${status}" -eq 0 ]

    run grep -F "${dependency}==1.44.0" docker/python/observability.lock
    [ "${status}" -eq 0 ]

    [ "$(grep -Fc "python3-${dependency}-pip" Dockerfile)" -eq 1 ]
  done
}

@test "runtime image tests include the observability package" {
  run grep -F 'robotics_observability' compose.yaml

  [ "${status}" -eq 0 ]
}

@test "simulation conformance reuses the selected runtime image" {
  expected_image=example.invalid/robotics/simulation:test
  run env \
    ROBOTICS_DOMAIN_ID=0 \
    ROBOTICS_RUN_ID=run-compose-model-test \
    SIMULATION_IMAGE="${expected_image}" \
    docker compose \
    -f compose.yaml \
    -f compose.simulation-conformance.yaml \
    --profile simulation-conformance \
    config --format json
  [ "${status}" -eq 0 ]

  run jq -e --arg image "${expected_image}" '
    .services.simulation.image == $image and
    .services["simulation-conformance"].image == $image
  ' <<<"${output}"
  [ "${status}" -eq 0 ]
}

@test "edge runtime carries the typed trace context without build tooling" {
  run grep -F \
    'FROM edge-runtime-base AS edge-runtime-interfaces' \
    Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    'COPY --from=edge-runtime-interfaces /opt/robotics_ws/install /opt/robotics_ws/install' \
    Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    'robotics_observability_msgs/msg/TraceContext > /dev/null' \
    Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    '<exec_depend>rosidl_default_runtime</exec_depend>' \
    docker/rosdeps/edge/package.xml
  [ "${status}" -eq 0 ]
}

@test "Gazebo clock bridges configure queued reliable delivery for stepped observation" {
  local config=ros_ws/src/robotics_runtime_infra/config/clock_bridge.yaml
  # The live test_clock subscriber requests reliable delivery. Here retain the
  # packaging check that every launch selects its shared bridge configuration.
  run grep -F 'publisher_queue: 1000' "${config}"
  [ "${status}" -eq 0 ]
  run grep -E '^[[:space:]]*qos_profile: CLOCK' "${config}"
  [ "${status}" -eq 1 ]

  run grep -F 'clock_bridge.yaml' \
    ros_ws/src/robotics_runtime_infra/launch/headless.launch.py
  [ "${status}" -eq 0 ]
  run grep -F '/clock@rosgraph_msgs/msg/Clock' \
    ros_ws/src/robotics_runtime_infra/launch/headless.launch.py
  [ "${status}" -eq 1 ]

  run grep -F 'headless.launch.py' \
    ros_ws/src/robotics_runtime_infra/launch/joint_motion.launch.py
  [ "${status}" -eq 0 ]
  run grep -F 'clock_bridge.yaml' \
    ros_ws/src/robotics_runtime_infra/launch/joint_motion.launch.py
  [ "${status}" -eq 1 ]

  run grep -F 'headless.launch.py' \
    ros_ws/src/robotics_runtime_infra/launch/camera.launch.py
  [ "${status}" -eq 0 ]
  run grep -F 'clock_bridge.yaml' \
    ros_ws/src/robotics_runtime_infra/launch/camera.launch.py
  [ "${status}" -eq 1 ]

  # EGL rendering remains a Gazebo-specific adapter and owns its clock bridge.
  run grep -F 'headless.launch.py' \
    ros_ws/src/robotics_runtime_infra/launch/gpu_lidar.launch.py
  [ "${status}" -eq 1 ]
  run grep -F 'clock_bridge.yaml' \
    ros_ws/src/robotics_runtime_infra/launch/gpu_lidar.launch.py
  [ "${status}" -eq 0 ]

  run grep -F 'qos_profile=QoSProfile(depth=1000, reliability=ReliabilityPolicy.RELIABLE)' \
    ros_ws/src/robotics_runtime_infra/test/test_clock.py
  [ "${status}" -eq 0 ]
}

@test "launch tests use distinct ROS domains" {
  cmake=ros_ws/src/robotics_runtime_infra/CMakeLists.txt

  [ "$(grep -Ec 'ENV "ROS_DOMAIN_ID=[0-9]+"' "${cmake}")" -eq 5 ]
  [ "$(
    grep -Eo 'ROS_DOMAIN_ID=[0-9]+' "${cmake}" |
      sort -u |
      wc -l
  )" -eq 5 ]
}

prepare_playback_transport() {
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir "${bin}"
  export PATH="${bin}:${PATH}"
  export PLAYBACK_TRACE="${BATS_TEST_TMPDIR}/docker-trace"
  export PLAYBACK_LARGE_DOMAIN=87 PLAYBACK_NEGATIVE_DATA=0 PLAYBACK_LOG_FAILURE_DOMAIN=none
  cat >"${bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${PLAYBACK_TRACE}"
case "$1" in
  compose)
    while (($#)); do
      case "$1" in
        ps) printf '%s-%s\n' "${ROS_DOMAIN_ID}" "${@: -1}"; exit 0 ;;
        up | wait | down) exit 0 ;;
      esac
      shift
    done
    exit 64
    ;;
  inspect)
    case "${@: -1}" in
      86-playback-gate) printf '1\n' ;;
      86-playback-probe) printf '124\n' ;;
      *) printf '0\n' ;;
    esac
    ;;
  logs)
    if [[ "${ROS_DOMAIN_ID}" == 87 || "${PLAYBACK_NEGATIVE_DATA}" == 1 ]]; then
      printf 'data: 42\n'
    fi
    if [[ "${ROS_DOMAIN_ID}" == "${PLAYBACK_LARGE_DOMAIN}" ]]; then
      printf '%262144s\n' ''
    fi
    [[ "${ROS_DOMAIN_ID}" != "${PLAYBACK_LOG_FAILURE_DOMAIN}" ]] || exit 42
    ;;
  *) exit 64 ;;
esac
SH
  chmod +x "${bin}/docker"
}

@test "MCAP playback accepts data before a log tail larger than the pipe buffer" {
  prepare_playback_transport
  run bash scripts/ci/integration/verify-mcap-playback.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'playback timeout fixture failed closed'* ]]
  [ "$(grep -c '^logs ' "${PLAYBACK_TRACE}")" -eq 2 ]
  [ "$(grep -c ' down --volumes --remove-orphans$' "${PLAYBACK_TRACE}")" -eq 2 ]
}

@test "MCAP playback timeout rejects data before a log tail larger than the pipe buffer" {
  prepare_playback_transport
  run env PLAYBACK_LARGE_DOMAIN=86 PLAYBACK_NEGATIVE_DATA=1 \
    bash scripts/ci/integration/verify-mcap-playback.sh
  [ "${status}" -eq 1 ]
  [[ "${output}" != *'playback timeout fixture failed closed'* ]]
  [ "$(grep -c '^logs 86-playback-probe$' "${PLAYBACK_TRACE}")" -eq 1 ]
  [ "$(grep -c ' down --volumes --remove-orphans$' "${PLAYBACK_TRACE}")" -eq 2 ]
}

@test "MCAP playback preserves failed log retrieval even after matching data" {
  prepare_playback_transport
  run env PLAYBACK_LARGE_DOMAIN=86 PLAYBACK_NEGATIVE_DATA=1 PLAYBACK_LOG_FAILURE_DOMAIN=86 \
    bash scripts/ci/integration/verify-mcap-playback.sh
  [ "${status}" -eq 42 ]
  [[ "${output}" != *'playback timeout fixture failed closed'* ]]
  [ "$(grep -c '^logs 86-playback-probe$' "${PLAYBACK_TRACE}")" -eq 1 ]
  [ "$(grep -c ' down --volumes --remove-orphans$' "${PLAYBACK_TRACE}")" -eq 2 ]
}
