#include <algorithm>
#include <chrono>
#include <cmath>
#include <exception>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <control_msgs/action/follow_joint_trajectory.hpp>
#include <moveit/move_group_interface/move_group_interface.hpp>
#include <rclcpp/rclcpp.hpp>
#include <rclcpp_action/rclcpp_action.hpp>

namespace
{
using FollowJointTrajectory = control_msgs::action::FollowJointTrajectory;

constexpr char kPlanningGroup[] = "slider";
constexpr char kJointName[] = "slider_joint";
constexpr char kControllerAction[] =
  "/joint_trajectory_controller/follow_joint_trajectory";
constexpr auto kControllerTimeout = std::chrono::seconds{60};
constexpr double kInvalidTarget = 0.8;
constexpr double kValidTarget = 0.3;
constexpr double kPositionTolerance = 0.05;
}  // namespace

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto node = rclcpp::Node::make_shared(
    "moveit_plan_probe",
    rclcpp::NodeOptions().automatically_declare_parameters_from_overrides(true));
  auto controller_client =
    rclcpp_action::create_client<FollowJointTrajectory>(node, kControllerAction);
  rclcpp::executors::SingleThreadedExecutor executor;
  executor.add_node(node);
  std::thread spinner([&executor]() {executor.spin();});

  int status = 0;
  try {
    moveit::planning_interface::MoveGroupInterface move_group(node, kPlanningGroup);
    move_group.setPlanningPipelineId("ompl");
    move_group.setPlannerId("RRTConnectkConfigDefault");
    move_group.setPlanningTime(10.0);
    move_group.setMaxVelocityScalingFactor(0.5);
    move_group.setMaxAccelerationScalingFactor(0.5);

    const bool controller_ready =
      controller_client->wait_for_action_server(kControllerTimeout);
    const auto initial_state =
      controller_ready ? move_group.getCurrentState(15.0) : nullptr;
    if (!controller_ready) {
      RCLCPP_ERROR(node->get_logger(), "Trajectory controller action server is unavailable");
      status = 12;
    } else if (!initial_state) {
      RCLCPP_ERROR(node->get_logger(), "Initial robot state is unavailable");
      status = 2;
    } else if (move_group.setJointValueTarget(std::vector<double>{kInvalidTarget})) {
      RCLCPP_ERROR(node->get_logger(), "Out-of-range target passed the bounds check");
      status = 3;
    // MoveIt retains a rejected joint target, so replace it before planning.
    } else if (!move_group.setJointValueTarget(std::vector<double>{kValidTarget})) {
      RCLCPP_ERROR(node->get_logger(), "Valid target failed the bounds check");
      status = 5;
    } else {
      move_group.setStartStateToCurrentState();
      moveit::planning_interface::MoveGroupInterface::Plan plan;
      const auto planned = move_group.plan(plan);
      const auto & trajectory = plan.trajectory.joint_trajectory;
      const auto joint = std::find(
        trajectory.joint_names.begin(), trajectory.joint_names.end(), kJointName);
      if (planned != moveit::core::MoveItErrorCode::SUCCESS) {
        RCLCPP_ERROR(node->get_logger(), "MoveIt planning failed");
        status = 6;
      } else if (trajectory.points.empty() || joint == trajectory.joint_names.end()) {
        RCLCPP_ERROR(node->get_logger(), "MoveIt returned an empty or incomplete trajectory");
        status = 7;
      } else if (
        move_group.execute(plan) != moveit::core::MoveItErrorCode::SUCCESS)
      {
        RCLCPP_ERROR(node->get_logger(), "MoveIt execution failed");
        status = 8;
      } else {
        const auto current = move_group.getCurrentState(10.0);
        std::vector<double> positions;
        if (!current) {
          RCLCPP_ERROR(node->get_logger(), "Current robot state is unavailable");
          status = 9;
        } else {
          current->copyJointGroupPositions(kPlanningGroup, positions);
          if (
            positions.size() != 1 ||
            std::abs(positions[0] - kValidTarget) > kPositionTolerance)
          {
            RCLCPP_ERROR(
              node->get_logger(),
              "Executed position is outside tolerance: expected %.3f, received %.3f",
              kValidTarget, positions.empty() ? std::nan("") : positions[0]);
            status = 10;
          }
        }
      }
    }
  } catch (const std::exception & error) {
    RCLCPP_ERROR(node->get_logger(), "MoveIt probe failed: %s", error.what());
    status = 11;
  }

  executor.cancel();
  spinner.join();
  rclcpp::shutdown();
  return status;
}
