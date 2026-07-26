#!/usr/bin/env bash
set -Eeuo pipefail

project="high-throughput-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
compose=(
  docker compose -p "${project}"
  -f compose.yaml
  -f compose.high-throughput.yaml
)
cleanup() {
  "${compose[@]}" --profile test \
    down --volumes --remove-orphans || true
}
trap cleanup EXIT
GZ_PARTITION="high-throughput-${GITHUB_RUN_ID}" \
ROS_DOMAIN_ID=88 \
  "${compose[@]}" --profile test \
  up --no-build --abort-on-container-exit \
  --exit-code-from data-plane-probe \
  simulation data-plane data-plane-probe
