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
    --profile playback
    --profile test
  )
  trap '"${compose[@]}" down --volumes --remove-orphans || true' EXIT

  export ROS_DOMAIN_ID="${domain_id}"
  if ((expect_failure)); then
    export ROBOTICS_PLAYBACK_READINESS_TOPIC=/never_present
    export ROBOTICS_PLAYBACK_READY_TIMEOUT_SEC=2
    export ROBOTICS_PLAYBACK_PROBE_TIMEOUT_SEC=4
  fi

  "${compose[@]}" up --no-build --detach playback playback-gate playback-probe
  "${compose[@]}" wait playback-gate playback-probe || true
  local gate_id
  local probe_id
  local gate_status
  local probe_status
  gate_id="$("${compose[@]}" ps --all --quiet playback-gate)"
  probe_id="$("${compose[@]}" ps --all --quiet playback-probe)"
  [[ -n "${gate_id}" && -n "${probe_id}" ]]
  gate_status="$(docker inspect --format '{{.State.ExitCode}}' "${gate_id}")"
  probe_status="$(docker inspect --format '{{.State.ExitCode}}' "${probe_id}")"

  if ((expect_failure)); then
    test "${gate_status}" -eq 1
    test "${probe_status}" -eq 124
    docker logs "${probe_id}" 2>&1 | grep -Eq '^data:' && return 1
    printf 'playback timeout fixture failed closed\n'
  else
    test "${gate_status}" -eq 0
    test "${probe_status}" -eq 0
    docker logs "${probe_id}" 2>&1 | grep -Eq '^data:'
  fi
)

run_case ready 87 0
run_case timeout 86 1
