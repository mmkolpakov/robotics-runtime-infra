#!/usr/bin/env bash
# Verifies the simulation image has every package and tool this stack
# depends on. Runs as the image's default CMD, e.g. via
# `docker compose run --rm simulation` (`make compose-smoke`).
set -eo pipefail

# `-u` is intentionally not set: the ROS 2 `setup.bash` chain this sources
# references variables (e.g. AMENT_TRACE_SETUP_FILES) that are expected to
# be unset on a fresh shell.
# shellcheck disable=SC1091
source /etc/profile.d/robotics_ros_setup.sh

required_ros_packages=(
  mavros
  mavros_extras
  mavros_msgs
  moveit_ros_move_group
  controller_manager
  ros2_control
  joint_trajectory_controller
  ros_gz_bridge
  ros_gz_sim
  rosbag2_storage_mcap
)

installed_ros_packages="$(ros2 pkg list)"
for package in "${required_ros_packages[@]}"; do
  if ! grep -qx "${package}" <<< "${installed_ros_packages}"; then
    echo "healthcheck: missing ROS package '${package}'" >&2
    exit 1
  fi
done

python3 -c "
import cv2
from cv_bridge import CvBridge

CvBridge()
print(cv2.__version__)
"

gz sim --help > /tmp/gz_help.txt
ros2 bag record -s mcap --help > /tmp/rosbag_mcap_help.txt
ros2 control --help > /tmp/ros2_control_help.txt
aws --version | grep -E '^aws-cli/2\.35\.17 ' > /tmp/aws_cli_version.txt

for report in /tmp/gz_help.txt /tmp/rosbag_mcap_help.txt /tmp/ros2_control_help.txt /tmp/aws_cli_version.txt; do
  test -s "${report}"
done

echo "healthcheck: ok"
