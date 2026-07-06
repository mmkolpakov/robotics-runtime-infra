#!/usr/bin/env bash
set -eo pipefail

source /etc/profile.d/robotics_ros_setup.sh

WORLD_PATH="${SMOKE_WORLD_PATH:-/workspace/infra/smoke/worlds/empty.sdf}"
LAUNCH_PATH="${SMOKE_LAUNCH_PATH:-/workspace/launch/simulation_smoke.launch.py}"
CLOCK_TOPIC="${SMOKE_CLOCK_TOPIC:-/clock}"
MAVROS_STATE_TOPIC="${SMOKE_MAVROS_STATE_TOPIC:-/mavros/state}"
MAVROS_FCU_URL="${SMOKE_MAVROS_FCU_URL:-udp://:14540@}"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-45}"
LOG_DIR="${SMOKE_LOG_DIR:-/tmp/robotics-smoke}"

mkdir -p "${LOG_DIR}"

pids=()

cleanup() {
  for pid in "${pids[@]}"; do
    kill "${pid}" >/dev/null 2>&1 || true
  done
  wait >/dev/null 2>&1 || true
}

wait_for_topic() {
  local topic="$1"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))

  until ros2 topic list | grep -Fx "${topic}" >/dev/null; do
    if ((SECONDS >= deadline)); then
      echo "Timed out waiting for ${topic}" >&2
      echo "--- launch.log ---" >&2
      tail -200 "${LOG_DIR}/launch.log" >&2 || true
      echo "--- mavros.log ---" >&2
      tail -200 "${LOG_DIR}/mavros.log" >&2 || true
      return 1
    fi
    sleep 1
  done
}

trap cleanup EXIT

ros2 launch "${LAUNCH_PATH}" world:="${WORLD_PATH}" >"${LOG_DIR}/launch.log" 2>&1 &
pids+=("$!")

wait_for_topic "${CLOCK_TOPIC}"

ros2 run mavros mavros_node --ros-args \
  -p fcu_url:="${MAVROS_FCU_URL}" \
  >"${LOG_DIR}/mavros.log" 2>&1 &
pids+=("$!")

wait_for_topic "${MAVROS_STATE_TOPIC}"

ros2 topic list | sort
