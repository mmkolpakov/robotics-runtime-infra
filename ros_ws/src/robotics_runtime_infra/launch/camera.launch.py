from __future__ import annotations

from launch import LaunchDescription
from launch.actions import IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description() -> LaunchDescription:
    world = PathJoinSubstitution(
        [FindPackageShare("robotics_runtime_infra"), "worlds", "camera.sdf"]
    )
    headless_launch = PathJoinSubstitution(
        [
            FindPackageShare("robotics_runtime_infra"),
            "launch",
            "headless.launch.py",
        ]
    )

    return LaunchDescription(
        [
            IncludeLaunchDescription(
                PythonLaunchDescriptionSource(headless_launch),
                launch_arguments={
                    "world": world,
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
        ]
    )
