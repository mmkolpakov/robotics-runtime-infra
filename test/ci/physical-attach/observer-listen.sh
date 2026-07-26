#!/usr/bin/env bash
set -Eeuo pipefail

test -r /authorization-output/runtime-manifest.json
test -r /authorization-output/execution-verification.json
test -r /evidence/hardware-time.otlp.json
timeout 20 ros2 run demo_nodes_cpp listener \
  --ros-args \
  --enclave /robotics/observer \
  --remap __node:=robotics_acceptance_observer \
  --remap chatter:=/robotics/telemetry 2>&1 |
  grep --max-count=1 'I heard:'
