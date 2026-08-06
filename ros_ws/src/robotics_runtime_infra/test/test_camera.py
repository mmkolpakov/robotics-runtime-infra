from __future__ import annotations

import math
import os
import unittest

import launch
import launch.actions
import launch.launch_description_sources
import launch_testing.actions
from launch.substitutions import PathJoinSubstitution
from launch_ros.substitutions import FindPackageShare
from launch_testing_ros import WaitForTopics
from sensor_msgs.msg import CameraInfo, Image


def generate_test_description() -> launch.LaunchDescription:
    return launch.LaunchDescription(
        [
            launch.actions.SetEnvironmentVariable(
                "GZ_PARTITION", f"camera-{os.getpid()}"
            ),
            launch.actions.SetEnvironmentVariable("LIBGL_ALWAYS_SOFTWARE", "1"),
            launch.actions.IncludeLaunchDescription(
                launch.launch_description_sources.PythonLaunchDescriptionSource(
                    PathJoinSubstitution(
                        [
                            FindPackageShare("robotics_runtime_infra"),
                            "launch",
                            "camera.launch.py",
                        ]
                    )
                ),
            ),
            launch_testing.actions.ReadyToTest(),
        ]
    )


class TestCamera(unittest.TestCase):
    def test_image_and_calibration_are_published(self) -> None:
        with WaitForTopics(
            [
                ("/camera/image", Image),
                ("/camera/camera_info", CameraInfo),
            ],
            timeout=90.0,
        ) as topics:
            images = topics.received_messages("/camera/image")
            calibration = topics.received_messages("/camera/camera_info")
            self.assertTrue(images)
            self.assertTrue(calibration)
            self.assertGreater(images[-1].width, 0)
            self.assertGreater(images[-1].height, 0)
            self.assertTrue(images[-1].data)
            self.assertTrue(all(math.isfinite(value) for value in calibration[-1].k))
            self.assertGreater(calibration[-1].k[0], 0.0)
            self.assertGreater(calibration[-1].k[4], 0.0)
