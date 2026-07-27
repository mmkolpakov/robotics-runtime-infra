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
}

@test "locked Python dependency is excluded once from rosdep installation" {
  run grep -F '<exec_depend>python3-opentelemetry-api-pip</exec_depend>' \
    ros_ws/src/robotics_observability/package.xml
  [ "${status}" -eq 0 ]

  run grep -F 'opentelemetry-api==1.44.0' docker/python/observability.lock
  [ "${status}" -eq 0 ]

  [ "$(grep -Fc -- '--skip-keys python3-opentelemetry-api-pip' Dockerfile)" -eq 1 ]
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
