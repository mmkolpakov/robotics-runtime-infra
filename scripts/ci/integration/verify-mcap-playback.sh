#!/usr/bin/env bash
set -Eeuo pipefail

run_case() (
  local name="$1"
  local domain_id="$2"
  local expect_failure="$3"
  local project="playback-${name}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"
  local compose=(
    docker compose -p "${project}"
    -f compose.yaml
    -f compose.playback.yaml
  )
  cleanup() {
    "${compose[@]}" --profile playback --profile test \
      down --volumes --remove-orphans || true
  }
  trap cleanup EXIT

  export ROS_DOMAIN_ID="${domain_id}"
  if ((expect_failure)); then
    export ROBOTICS_PLAYBACK_READINESS_TOPIC=/never_present
    export ROBOTICS_PLAYBACK_READY_TIMEOUT_SEC=2
    export ROBOTICS_PLAYBACK_PROBE_TIMEOUT_SEC=4
  fi

  "${compose[@]}" --profile playback --profile test \
    up --no-build --detach playback playback-gate playback-probe
  local status=0
  "${compose[@]}" --profile playback --profile test \
    wait playback-gate playback-probe || status=$?

  if ((expect_failure)); then
    if ((status == 0)); then
      printf 'playback timeout fixture unexpectedly passed\n' >&2
      return 1
    fi
    printf 'playback timeout fixture failed closed: %s\n' "${status}"
  else
    return "${status}"
  fi
)

run_case ready 87 0
run_case timeout 86 1
