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
from rosgraph_msgs.msg import Clock


def generate_test_description() -> launch.LaunchDescription:
    launch_file = (
        Path(get_package_share_directory("robotics_runtime_infra"))
        / "launch"
        / "headless.launch.py"
    )
    return launch.LaunchDescription(
        [
            launch.actions.SetEnvironmentVariable("GZ_PARTITION", f"clock-{os.getpid()}"),
            launch.actions.IncludeLaunchDescription(
                launch.launch_description_sources.PythonLaunchDescriptionSource(
                    str(launch_file)
                )
            ),
            launch_testing.actions.ReadyToTest(),
        ]
    )


class TestClock(unittest.TestCase):
    def test_clock_is_monotonic(self) -> None:
        rclpy.init()
        node = rclpy.create_node("clock_acceptance_test")
        samples: list[int] = []

        def receive(message: Clock) -> None:
            samples.append(message.clock.sec * 1_000_000_000 + message.clock.nanosec)

        subscription = node.create_subscription(Clock, "/clock", receive, 10)
        deadline = time.monotonic() + 60
        try:
            while len(samples) < 10 and time.monotonic() < deadline:
                rclpy.spin_once(node, timeout_sec=0.5)
            self.assertGreaterEqual(len(samples), 10)
            self.assertTrue(all(current > previous for previous, current in zip(samples, samples[1:])))
        finally:
            node.destroy_subscription(subscription)
            node.destroy_node()
            rclpy.shutdown()
