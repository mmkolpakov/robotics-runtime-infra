from __future__ import annotations

from pathlib import Path

from ament_index_python.packages import get_package_share_directory
from controller_manager.launch_utils import (
    generate_controllers_spawner_launch_description,
)
from launch import LaunchDescription
from launch.actions import IncludeLaunchDescription, RegisterEventHandler
from launch.event_handlers import OnProcessExit
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import Command, FindExecutable, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description() -> LaunchDescription:
    share = Path(get_package_share_directory("robotics_runtime_infra"))
    world = share / "worlds" / "empty.sdf"
    description = share / "description" / "joint_motion.urdf.xacro"
    controllers = share / "config" / "joint_controllers.yaml"
    clock_bridge_config = share / "config" / "clock_bridge.yaml"
    robot_description = Command(
        [
            FindExecutable(name="xacro"),
            " ",
            str(description),
            " controllers_file:=",
            str(controllers),
        ]
    )

    gazebo = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            PathJoinSubstitution(
                [FindPackageShare("ros_gz_sim"), "launch", "gz_sim.launch.py"]
            )
        ),
        launch_arguments={
            "gz_args": f"-s -r -v 2 {world}",
            "on_exit_shutdown": "true",
        }.items(),
    )
    robot_state_publisher = Node(
        package="robot_state_publisher",
        executable="robot_state_publisher",
        parameters=[{"robot_description": robot_description, "use_sim_time": True}],
        output="screen",
    )
    spawn_robot = Node(
        package="ros_gz_sim",
        executable="create",
        arguments=["-topic", "robot_description", "-name", "joint_motion_probe"],
        output="screen",
    )
    controllers_start = generate_controllers_spawner_launch_description(
        ["joint_state_broadcaster", "joint_trajectory_controller"],
        extra_spawner_args=["--controller-manager-timeout", "45"],
    )
    start_controllers_after_spawn = RegisterEventHandler(
        OnProcessExit(
            target_action=spawn_robot,
            on_exit=controllers_start.entities,
        )
    )
    clock_bridge = Node(
        package="ros_gz_bridge",
        executable="parameter_bridge",
        parameters=[{"config_file": str(clock_bridge_config)}],
        output="screen",
    )

    return LaunchDescription(
        [
            gazebo,
            robot_state_publisher,
            spawn_robot,
            start_controllers_after_spawn,
            clock_bridge,
        ]
    )
