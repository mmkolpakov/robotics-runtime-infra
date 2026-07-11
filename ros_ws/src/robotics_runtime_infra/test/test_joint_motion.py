from __future__ import annotations

import os
import time
import unittest
from pathlib import Path

import launch
import launch.actions
import launch.launch_description_sources
import launch_testing.actions
import rclpy
from ament_index_python.packages import get_package_share_directory
from control_msgs.action import FollowJointTrajectory
from controller_manager_msgs.srv import ListControllers
from rclpy.action import ActionClient
from rclpy.duration import Duration
from sensor_msgs.msg import JointState
from trajectory_msgs.msg import JointTrajectoryPoint


def generate_test_description() -> launch.LaunchDescription:
    launch_file = (
        Path(get_package_share_directory("robotics_runtime_infra"))
        / "launch"
        / "joint_motion.launch.py"
    )
    return launch.LaunchDescription(
        [
            launch.actions.SetEnvironmentVariable("GZ_PARTITION", f"joint-{os.getpid()}"),
            launch.actions.IncludeLaunchDescription(
                launch.launch_description_sources.PythonLaunchDescriptionSource(
                    str(launch_file)
                )
            ),
            launch_testing.actions.ReadyToTest(),
        ]
    )


class TestJointMotion(unittest.TestCase):
    def test_controller_moves_joint(self) -> None:
        rclpy.init()
        node = rclpy.create_node("joint_motion_acceptance_test")
        positions: list[float] = []

        def receive(message: JointState) -> None:
            if "slider_joint" in message.name:
                positions.append(message.position[message.name.index("slider_joint")])

        subscription = node.create_subscription(JointState, "/joint_states", receive, 10)
        client = ActionClient(
            node,
            FollowJointTrajectory,
            "/joint_trajectory_controller/follow_joint_trajectory",
        )
        controller_client = node.create_client(
            ListControllers,
            "/controller_manager/list_controllers",
        )
        try:
            self.assertTrue(controller_client.wait_for_service(timeout_sec=90))
            deadline = time.monotonic() + 90
            controller_active = False
            while not controller_active and time.monotonic() < deadline:
                future = controller_client.call_async(ListControllers.Request())
                rclpy.spin_until_future_complete(node, future, timeout_sec=5)
                if not future.done():
                    future.cancel()
                    continue
                response = future.result()
                controller_active = response is not None and any(
                    controller.name == "joint_trajectory_controller"
                    and controller.state == "active"
                    for controller in response.controller
                )
                if not controller_active:
                    time.sleep(0.5)
            self.assertTrue(controller_active)
            self.assertTrue(client.wait_for_server(timeout_sec=90))
            deadline = time.monotonic() + 30
            while not positions and time.monotonic() < deadline:
                rclpy.spin_once(node, timeout_sec=0.5)
            self.assertTrue(positions)
            initial = positions[-1]

            goal = FollowJointTrajectory.Goal()
            goal.trajectory.joint_names = ["slider_joint"]
            point = JointTrajectoryPoint()
            point.positions = [0.3]
            point.time_from_start = Duration(seconds=2).to_msg()
            goal.trajectory.points = [point]

            goal_future = client.send_goal_async(goal)
            rclpy.spin_until_future_complete(node, goal_future, timeout_sec=15)
            goal_handle = goal_future.result()
            self.assertIsNotNone(goal_handle)
            self.assertTrue(goal_handle.accepted)
            result_future = goal_handle.get_result_async()
            rclpy.spin_until_future_complete(node, result_future, timeout_sec=30)
            self.assertIsNotNone(result_future.result())

            deadline = time.monotonic() + 15
            while (not positions or abs(positions[-1] - initial) <= 0.1) and time.monotonic() < deadline:
                rclpy.spin_once(node, timeout_sec=0.5)
            self.assertGreater(abs(positions[-1] - initial), 0.1)
        finally:
            node.destroy_client(controller_client)
            client.destroy()
            node.destroy_subscription(subscription)
            node.destroy_node()
            rclpy.shutdown()
