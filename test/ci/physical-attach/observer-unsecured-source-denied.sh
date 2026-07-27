#!/usr/bin/env bash
set -Eeuo pipefail

set +e
output="$(
  timeout 8 ros2 topic echo \
    --no-daemon \
    --once \
    /robotics/telemetry \
    std_msgs/msg/String 2>&1
)"
status=$?
set -e
printf '%s\n' "${output}"
test "${status}" -eq 124
! grep -Eq '^data:' <<<"${output}"
