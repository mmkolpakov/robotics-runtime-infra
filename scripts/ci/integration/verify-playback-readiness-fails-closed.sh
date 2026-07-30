#!/usr/bin/env bash
set -Eeuo pipefail

project="playback-negative-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
compose=(
  docker compose -p "${project}"
  -f compose.yaml
  -f compose.playback.yaml
)
cleanup() {
  "${compose[@]}" --profile playback --profile test \
    down --volumes --remove-orphans || true
}
trap cleanup EXIT
export ROS_DOMAIN_ID=86
export ROBOTICS_PLAYBACK_READINESS_TOPIC=/never_present
export ROBOTICS_PLAYBACK_READY_TIMEOUT_SEC=2
export ROBOTICS_PLAYBACK_PROBE_TIMEOUT_SEC=4
"${compose[@]}" \
  --profile playback --profile test \
  up --no-build --detach \
  playback playback-gate playback-probe
set +e
"${compose[@]}" \
  --profile playback --profile test \
  wait playback-gate playback-probe
status=$?
set -e
if (( status == 0 )); then
  printf 'playback timeout fixture unexpectedly passed\n' >&2
  exit 1
fi
printf 'playback timeout fixture failed closed: %s\n' "${status}"
