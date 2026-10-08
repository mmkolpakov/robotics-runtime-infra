from __future__ import annotations

from pathlib import Path

from ament_index_python.packages import get_package_share_directory
from moveit_configs_utils import MoveItConfigs, MoveItConfigsBuilder


def joint_motion_moveit_config() -> MoveItConfigs:
    share = Path(get_package_share_directory("robotics_runtime_infra"))
    controllers = share / "config" / "joint_controllers.yaml"
    return (
        MoveItConfigsBuilder(
            "joint_motion_probe",
            package_name="robotics_runtime_infra",
        )
        .robot_description(
            file_path="description/joint_motion.urdf.xacro",
            mappings={"controllers_file": str(controllers)},
        )
        .robot_description_semantic(file_path="config/joint_motion.srdf")
        .robot_description_kinematics(file_path="config/kinematics.yaml")
        .joint_limits(file_path="config/joint_limits.yaml")
        .trajectory_execution(
            file_path="config/moveit_controllers.yaml",
            moveit_manage_controllers=False,
        )
        .planning_pipelines(
            default_planning_pipeline="ompl",
            pipelines=["ompl"],
            load_all=False,
        )
        .planning_scene_monitor(
            publish_robot_description=True,
            publish_robot_description_semantic=True,
        )
        .to_moveit_configs()
    )
