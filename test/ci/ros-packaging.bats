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
