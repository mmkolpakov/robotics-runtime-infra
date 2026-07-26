#!/usr/bin/env bash
set -Eeuo pipefail

test -r /authorization-output/runtime-manifest.json
test -r /authorization-output/execution-verification.json
set +e
output="$(
  timeout 10 ros2 run demo_nodes_cpp talker \
    --ros-args \
    --enclave /robotics/observer \
    --remap __node:=robotics_acceptance_observer \
    --remap chatter:=/cmd_vel 2>&1
)"
status=$?
set -e
printf '%s\n' "${output}"
test "${status}" -ne 0
grep -Eqi 'permission|not allowed|denied|create publisher' <<<"${output}"
