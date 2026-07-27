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

@test "Gazebo clock bridges use the standard CLOCK QoS profile" {
  local config=ros_ws/src/robotics_runtime_infra/config/clock_bridge.yaml
  local launch_file

  run grep -F 'qos_profile: CLOCK' "${config}"
  [ "${status}" -eq 0 ]

  for launch_file in \
    ros_ws/src/robotics_runtime_infra/launch/headless.launch.py \
    ros_ws/src/robotics_runtime_infra/launch/camera.launch.py \
    ros_ws/src/robotics_runtime_infra/launch/gpu_lidar.launch.py \
    ros_ws/src/robotics_runtime_infra/launch/joint_motion.launch.py; do
    run grep -F 'clock_bridge.yaml' "${launch_file}"
    [ "${status}" -eq 0 ]
    run grep -F '/clock@rosgraph_msgs/msg/Clock' "${launch_file}"
    [ "${status}" -eq 1 ]
  done

  run grep -F 'qos_profile=qos_profile_sensor_data' \
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
