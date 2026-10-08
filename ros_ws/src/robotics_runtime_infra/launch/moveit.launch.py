from __future__ import annotations

from pathlib import Path

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch_ros.actions import SetParameter
from moveit_configs_utils.launches import generate_move_group_launch

from robotics_runtime_infra.moveit_configuration import joint_motion_moveit_config


def generate_launch_description() -> LaunchDescription:
    share = Path(get_package_share_directory("robotics_runtime_infra"))
    moveit_config = joint_motion_moveit_config()
    move_group_launch = generate_move_group_launch(moveit_config)

    return LaunchDescription(
        [
            SetParameter(name="use_sim_time", value=True),
            IncludeLaunchDescription(
                PythonLaunchDescriptionSource(
                    str(share / "launch" / "joint_motion.launch.py")
                )
            ),
            *move_group_launch.entities,
        ]
    )
