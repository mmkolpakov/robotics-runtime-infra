#!/usr/bin/env bash
set -Eeuo pipefail

set +e
output="$(
  timeout 8 ros2 run demo_nodes_cpp listener \
    --ros-args \
    --enclave /robotics/observer \
    --remap __node:=robotics_acceptance_observer \
    --remap chatter:=/robotics/telemetry 2>&1
)"
status=$?
set -e
printf '%s\n' "${output}"
test "${status}" -eq 124
! grep -q 'I heard:' <<<"${output}"
