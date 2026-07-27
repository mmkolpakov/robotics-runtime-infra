#!/usr/bin/env bash
set -Eeuo pipefail

test -r /authorization-output/runtime-manifest.json
test -r /authorization-output/execution-verification.json
test -r /evidence/hardware-time.otlp.json
set +e
output="$(
  timeout 20 ros2 topic echo \
    --no-daemon \
    --once \
    /robotics/telemetry \
    std_msgs/msg/String 2>&1
)"
status=$?
set -e
printf '%s\n' "${output}"
if test "${status}" -ne 0; then
  exit "${status}"
fi
grep -Eq '^data:' <<<"${output}"
