cmake_minimum_required(VERSION 3.16)
project(robotics_runtime_infra)

find_package(ament_cmake REQUIRED)
find_package(moveit_ros_planning_interface REQUIRED)
find_package(rclcpp REQUIRED)

add_executable(moveit_plan_probe src/moveit_plan_probe.cpp)
target_compile_features(moveit_plan_probe PRIVATE cxx_std_17)
ament_target_dependencies(
  moveit_plan_probe
  moveit_ros_planning_interface
  rclcpp
)

install(
  DIRECTORY config description launch worlds
  DESTINATION share/${PROJECT_NAME}
)
install(TARGETS moveit_plan_probe DESTINATION lib/${PROJECT_NAME})

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
  add_ros_isolated_launch_test(test/test_moveit.py TIMEOUT 240)
endif()

ament_package()
