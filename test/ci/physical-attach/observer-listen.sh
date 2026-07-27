#!/usr/bin/env bash
set -Eeuo pipefail

test -r /authorization-output/runtime-manifest.json
test -r /authorization-output/execution-verification.json
test -r /evidence/hardware-time.otlp.json
listener_log="$(mktemp)"
trap 'rm -f -- "${listener_log}"' EXIT
set +e
set +o pipefail
timeout 20 ros2 run demo_nodes_cpp listener \
  --ros-args \
  --enclave /robotics/observer \
  --remap __node:=robotics_acceptance_observer \
  --remap chatter:=/robotics/telemetry 2>&1 |
  tee "${listener_log}" |
  grep --fixed-strings --max-count=1 'I heard:'
status=$?
set -o pipefail
set -e
if test "${status}" -ne 0; then
  cat "${listener_log}" >&2
  exit "${status}"
fi
