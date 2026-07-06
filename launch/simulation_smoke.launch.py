from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    world = LaunchConfiguration("world")

    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "world",
                default_value="/workspace/infra/smoke/worlds/empty.sdf",
                description="SDF world used by the headless simulation smoke check.",
            ),
            ExecuteProcess(
                cmd=["gz", "sim", "-s", "-r", world],
                output="screen",
            ),
            ExecuteProcess(
                cmd=[
                    "ros2",
                    "run",
                    "ros_gz_bridge",
                    "parameter_bridge",
                    "/clock@rosgraph_msgs/msg/Clock[gz.msgs.Clock",
                ],
                output="screen",
            ),
        ]
    )
