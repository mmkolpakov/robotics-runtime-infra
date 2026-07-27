cmake_minimum_required(VERSION 3.16)
project(robotics_runtime_infra)

find_package(ament_cmake REQUIRED)
find_package(control_msgs REQUIRED)
find_package(moveit_ros_planning_interface REQUIRED)
find_package(rclcpp REQUIRED)
find_package(rclcpp_action REQUIRED)

add_executable(moveit_plan_probe src/moveit_plan_probe.cpp)
target_compile_features(moveit_plan_probe PRIVATE cxx_std_17)
ament_target_dependencies(
  moveit_plan_probe
  control_msgs
  moveit_ros_planning_interface
  rclcpp
  rclcpp_action
)

install(
  DIRECTORY config description launch worlds
  DESTINATION share/${PROJECT_NAME}
)
install(TARGETS moveit_plan_probe DESTINATION lib/${PROJECT_NAME})

if(BUILD_TESTING)
  find_package(launch_testing_ament_cmake REQUIRED)

  add_launch_test(
    test/test_clock.py
    ENV "ROS_DOMAIN_ID=121"
    TIMEOUT 90
  )
  add_launch_test(
    test/test_camera.py
    ENV "ROS_DOMAIN_ID=122"
    TIMEOUT 120
  )
  add_launch_test(
    test/test_mcap.py
    ENV "ROS_DOMAIN_ID=123"
    TIMEOUT 120
  )
  add_launch_test(
    test/test_joint_motion.py
    ENV "ROS_DOMAIN_ID=124"
    TIMEOUT 180
  )
  add_launch_test(
    test/test_moveit.py
    ENV "ROS_DOMAIN_ID=125"
    TIMEOUT 240
  )
endif()

ament_package()
