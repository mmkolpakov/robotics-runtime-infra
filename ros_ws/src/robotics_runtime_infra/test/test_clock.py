from __future__ import annotations

import os
import time
import unittest
from pathlib import Path

import launch
import launch.actions
import launch.launch_description_sources
import launch_testing.actions
from ament_index_python.packages import get_package_share_directory
from launch_testing_ros import WaitForTopics
from rosgraph_msgs.msg import Clock


def generate_test_description() -> launch.LaunchDescription:
    launch_file = (
        Path(get_package_share_directory("robotics_runtime_infra"))
        / "launch"
        / "headless.launch.py"
    )
    return launch.LaunchDescription(
        [
            launch.actions.SetEnvironmentVariable(
                "GZ_PARTITION", f"clock-{os.getpid()}"
            ),
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
        with WaitForTopics(
            [("/clock", Clock)],
            timeout=60.0,
            messages_received_buffer_length=10,
        ) as topics:
            deadline = time.monotonic() + 10.0
            messages = topics.received_messages("/clock")
            while len(messages) < 10 and time.monotonic() < deadline:
                time.sleep(0.1)
                messages = topics.received_messages("/clock")
            samples = [
                message.clock.sec * 1_000_000_000 + message.clock.nanosec
                for message in messages
            ]
            self.assertGreaterEqual(len(samples), 10)
            self.assertTrue(
                all(
                    current > previous
                    for previous, current in zip(samples, samples[1:])
                )
            )
