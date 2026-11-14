"""Compose stock Waffle navigation with Gazebo Harmonic EGL rendering."""

from pathlib import Path

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import (
    AppendEnvironmentVariable,
    DeclareLaunchArgument,
    IncludeLaunchDescription,
)
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    bringup = Path(get_package_share_directory("nav2_bringup"))
    simulation = Path(get_package_share_directory("nav2_minimal_tb3_sim"))
    gazebo = Path(get_package_share_directory("ros_gz_sim"))
    world = LaunchConfiguration("world")
    return LaunchDescription(
        [
            DeclareLaunchArgument("world"),
            DeclareLaunchArgument("robot_sdf"),
            DeclareLaunchArgument("map"),
            AppendEnvironmentVariable(
                "GZ_SIM_RESOURCE_PATH", str(simulation / "models")
            ),
            AppendEnvironmentVariable("GZ_SIM_RESOURCE_PATH", str(simulation.parent)),
            IncludeLaunchDescription(
                PythonLaunchDescriptionSource(str(gazebo / "launch/gz_sim.launch.py")),
                launch_arguments={
                    "gz_args": ["-r -s --headless-rendering ", world],
                    "on_exit_shutdown": "true",
                }.items(),
            ),
            IncludeLaunchDescription(
                PythonLaunchDescriptionSource(
                    str(bringup / "launch/tb3_simulation_launch.py")
                ),
                launch_arguments={
                    "world": world,
                    "robot_sdf": LaunchConfiguration("robot_sdf"),
                    "map": LaunchConfiguration("map"),
                    "use_simulator": "False",
                    "headless": "True",
                    "use_rviz": "False",
                    "slam": "False",
                    "use_composition": "False",
                    "use_respawn": "False",
                }.items(),
            ),
        ]
    )
