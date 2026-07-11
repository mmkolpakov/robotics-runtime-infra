from __future__ import annotations

import math
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
from launch.substitutions import PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare
from sensor_msgs.msg import CameraInfo, Image


def generate_test_description() -> launch.LaunchDescription:
    world = (
        Path(get_package_share_directory("robotics_runtime_infra"))
        / "worlds"
        / "camera.sdf"
    )
    return launch.LaunchDescription(
        [
            launch.actions.SetEnvironmentVariable("GZ_PARTITION", f"camera-{os.getpid()}"),
            launch.actions.SetEnvironmentVariable("LIBGL_ALWAYS_SOFTWARE", "1"),
            launch.actions.IncludeLaunchDescription(
                launch.launch_description_sources.PythonLaunchDescriptionSource(
                    PathJoinSubstitution(
                        [FindPackageShare("ros_gz_sim"), "launch", "gz_sim.launch.py"]
                    )
                ),
                launch_arguments={
                    "gz_args": f"-s -r -v 2 {world}",
                    "on_exit_shutdown": "true",
                }.items(),
            ),
            Node(
                package="ros_gz_bridge",
                executable="parameter_bridge",
                arguments=[
                    "/camera/image@sensor_msgs/msg/Image[gz.msgs.Image",
                    "/camera/camera_info@sensor_msgs/msg/CameraInfo[gz.msgs.CameraInfo",
                ],
                output="screen",
            ),
            launch_testing.actions.ReadyToTest(),
        ]
    )


class TestCamera(unittest.TestCase):
    def test_image_and_calibration_are_published(self) -> None:
        rclpy.init()
        node = rclpy.create_node("camera_acceptance_test")
        images: list[Image] = []
        calibration: list[CameraInfo] = []
        image_sub = node.create_subscription(Image, "/camera/image", images.append, 10)
        info_sub = node.create_subscription(
            CameraInfo,
            "/camera/camera_info",
            calibration.append,
            10,
        )
        deadline = time.monotonic() + 90
        try:
            while (not images or not calibration) and time.monotonic() < deadline:
                rclpy.spin_once(node, timeout_sec=0.5)
            self.assertTrue(images)
            self.assertTrue(calibration)
            self.assertGreater(images[-1].width, 0)
            self.assertGreater(images[-1].height, 0)
            self.assertTrue(images[-1].data)
            self.assertTrue(all(math.isfinite(value) for value in calibration[-1].k))
            self.assertGreater(calibration[-1].k[0], 0.0)
            self.assertGreater(calibration[-1].k[4], 0.0)
        finally:
            node.destroy_subscription(image_sub)
            node.destroy_subscription(info_sub)
            node.destroy_node()
            rclpy.shutdown()
