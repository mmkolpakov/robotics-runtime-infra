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
from launch_ros.actions import Node


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
            Node(
                package="robot_state_publisher",
                executable="robot_state_publisher",
                name="robot_state_publisher",
                namespace="",
                output="screen",
                parameters=[
                    {
                        "use_sim_time": True,
                        "robot_description": (
                            simulation / "urdf/turtlebot3_waffle.urdf"
                        ).read_text(),
                    }
                ],
                remappings=[("/tf", "tf"), ("/tf_static", "tf_static")],
            ),
            IncludeLaunchDescription(
                PythonLaunchDescriptionSource(
                    str(simulation / "launch/spawn_tb3.launch.py")
                ),
                launch_arguments={
                    "namespace": "",
                    "use_sim_time": "True",
                    "robot_name": "turtlebot3_waffle",
                    "robot_sdf": LaunchConfiguration("robot_sdf"),
                    "x_pose": "-2.00",
                    "y_pose": "-0.50",
                    "z_pose": "0.01",
                    "roll": "0.00",
                    "pitch": "0.00",
                    "yaw": "0.00",
                }.items(),
            ),
            IncludeLaunchDescription(
                PythonLaunchDescriptionSource(
                    str(bringup / "launch/bringup_launch.py")
                ),
                launch_arguments={
                    "namespace": "",
                    "use_namespace": "False",
                    "slam": "False",
                    "map": LaunchConfiguration("map"),
                    "use_localization": "True",
                    "use_sim_time": "true",
                    "params_file": str(bringup / "params/nav2_params.yaml"),
                    "autostart": "true",
                    "use_composition": "False",
                    "use_respawn": "False",
                }.items(),
            ),
        ]
    )
