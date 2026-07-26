from __future__ import annotations

import os
import unittest
from pathlib import Path

import launch
import launch.actions
import launch.launch_description_sources
import launch_testing.actions
import launch_testing.asserts
from ament_index_python.packages import get_package_share_directory
from launch_ros.actions import Node


def generate_test_description() -> tuple[launch.LaunchDescription, dict[str, Node]]:
    launch_file = (
        Path(get_package_share_directory("robotics_runtime_infra"))
        / "launch"
        / "moveit.launch.py"
    )
    probe = Node(
        package="robotics_runtime_infra",
        executable="moveit_plan_probe",
        output="screen",
        parameters=[{"use_sim_time": True}],
    )
    return (
        launch.LaunchDescription(
            [
                launch.actions.SetEnvironmentVariable(
                    "GZ_PARTITION",
                    f"moveit-{os.getpid()}",
                ),
                launch.actions.IncludeLaunchDescription(
                    launch.launch_description_sources.PythonLaunchDescriptionSource(
                        str(launch_file)
                    )
                ),
                probe,
                launch_testing.actions.ReadyToTest(),
            ]
        ),
        {"probe": probe},
    )


class TestMoveIt(unittest.TestCase):
    def test_plan_is_executed(
        self,
        proc_info: launch_testing.ProcInfoHandler,
        probe: Node,
    ) -> None:
        proc_info.assertWaitForShutdown(probe, timeout=180)
        launch_testing.asserts.assertExitCodes(proc_info, process=probe)
