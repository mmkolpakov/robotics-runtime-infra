#!/usr/bin/env bash
set -e

# shellcheck source=/dev/null
source "/opt/ros/${ROS_DISTRO}/setup.bash"

if [[ -f /opt/robotics_ws/install/setup.bash ]]; then
  # shellcheck source=/dev/null
  source /opt/robotics_ws/install/setup.bash
fi

exec "$@"
