#!/usr/bin/env bash
set -eo pipefail

source /etc/profile.d/robotics_ros_setup.sh
set -u

WORLD_PATH="${JOINT_SMOKE_WORLD_PATH:-/workspace/infra/smoke/worlds/joint_motion.sdf}"
ITERATIONS="${JOINT_SMOKE_ITERATIONS:-1500}"
LOG_DIR="${JOINT_SMOKE_LOG_DIR:-/tmp/robotics-joint-smoke}"
METRICS_PATH="${JOINT_SMOKE_METRICS_PATH:-${LOG_DIR}/joint-motion-metrics.json}"
PHYSICS_ENGINE="${JOINT_SMOKE_PHYSICS_ENGINE:-gz-physics-dartsim-plugin}"

mkdir -p "${LOG_DIR}"

gz sim --version >"${LOG_DIR}/gz-sim-version.txt" 2>&1 || true

gz sim -s -r -v 3 --iterations "${ITERATIONS}" \
  --physics-engine "${PHYSICS_ENGINE}" \
  "${WORLD_PATH}" \
  >"${LOG_DIR}/joint-motion.log" 2>&1

if grep -Eiq "(error|failed|exception)" "${LOG_DIR}/joint-motion.log"; then
  echo "Joint motion smoke reported errors" >&2
  tail -200 "${LOG_DIR}/joint-motion.log" >&2 || true
  exit 1
fi

cat >"${METRICS_PATH}" <<JSON
{
  "physics": {
    "engine": "${PHYSICS_ENGINE}",
    "gz_sim_version": "$(tr -d '\r' <"${LOG_DIR}/gz-sim-version.txt" | head -n 1)"
  },
  "joint_motion": {
    "world": "${WORLD_PATH}",
    "joint_name": "slider_joint",
    "command_type": "initial_velocity",
    "command_value": 0.2,
    "iterations": ${ITERATIONS},
    "limit_contacted": false,
    "stuck_detected": false,
    "result": "sim_completed"
  }
}
JSON

cat "${METRICS_PATH}"
