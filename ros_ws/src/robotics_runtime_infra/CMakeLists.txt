cmake_minimum_required(VERSION 3.16)
project(robotics_runtime_infra)

find_package(ament_cmake REQUIRED)

install(
  DIRECTORY config description launch worlds
  DESTINATION share/${PROJECT_NAME}
)

if(BUILD_TESTING)
  find_package(ament_cmake_ros REQUIRED)
  find_package(launch_testing_ament_cmake REQUIRED)

  function(add_ros_isolated_launch_test path)
    set(RUNNER "${ament_cmake_ros_DIR}/run_test_isolated.py")
    add_launch_test("${path}" RUNNER "${RUNNER}" ${ARGN})
  endfunction()

  add_ros_isolated_launch_test(test/test_clock.py TIMEOUT 90)
  add_ros_isolated_launch_test(test/test_camera.py TIMEOUT 120)
  add_ros_isolated_launch_test(test/test_mcap.py TIMEOUT 120)
  add_ros_isolated_launch_test(test/test_joint_motion.py TIMEOUT 180)
endif()

ament_package()
