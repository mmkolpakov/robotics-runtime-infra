from __future__ import annotations

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, EmitEvent, RegisterEventHandler
from launch.event_handlers import OnProcessExit
from launch.events import Shutdown
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description() -> LaunchDescription:
    world = LaunchConfiguration("world")
    simulator_name = LaunchConfiguration("simulator_name")
    verbosity_level = LaunchConfiguration("verbosity_level")
    default_world = PathJoinSubstitution(
        [FindPackageShare("robotics_runtime_infra"), "worlds", "empty.sdf"]
    )
    clock_bridge_config = PathJoinSubstitution(
        [
            FindPackageShare("robotics_runtime_infra"),
            "config",
            "clock_bridge.yaml",
        ]
    )

    simulator = Node(
        package="ros_gz_sim",
        executable="gzserver",
        name=simulator_name,
        parameters=[
            {
                "verbosity_level": verbosity_level,
                "world_sdf_file": world,
            }
        ],
        output="screen",
    )

    return LaunchDescription(
        [
            DeclareLaunchArgument("world", default_value=default_world),
            DeclareLaunchArgument("simulator_name", default_value="simulator"),
            DeclareLaunchArgument("verbosity_level", default_value="2"),
            simulator,
            RegisterEventHandler(
                OnProcessExit(
                    target_action=simulator,
                    on_exit=[EmitEvent(event=Shutdown(reason="Gazebo server exited"))],
                )
            ),
            Node(
                package="ros_gz_bridge",
                executable="parameter_bridge",
                parameters=[{"config_file": clock_bridge_config}],
                output="screen",
            ),
        ]
    )
