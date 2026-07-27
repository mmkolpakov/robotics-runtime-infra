#!/usr/bin/env bash
set -Eeuo pipefail

test -r /authorization-output/runtime-manifest.json
test -r /authorization-output/execution-verification.json
set +e
output="$(
  timeout 10 ros2 topic pub \
    /cmd_vel \
    std_msgs/msg/String \
    '{data: blocked}' \
    --once \
    --node-name robotics_acceptance_observer \
    --wait-matching-subscriptions 0 2>&1
)"
status=$?
set -e
printf '%s\n' "${output}"
test "${status}" -ne 0
grep -Eqi 'permission|not allowed|denied|create publisher' <<<"${output}"
