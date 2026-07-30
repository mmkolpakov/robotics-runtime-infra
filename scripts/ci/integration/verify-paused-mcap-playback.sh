#!/usr/bin/env bash
set -Eeuo pipefail

project="playback-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
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
export ROS_DOMAIN_ID=87
"${compose[@]}" \
  --profile playback --profile test \
  up --no-build --detach \
  playback playback-gate playback-probe
"${compose[@]}" \
  --profile playback --profile test \
  wait playback-gate playback-probe
