#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  COMPOSE_FILE="${REPOSITORY_ROOT}/compose.zenoh.yaml"
  REPORT_FILTER="${REPOSITORY_ROOT}/config/zenoh/channel-observation.jq"
  RUNNER="${REPOSITORY_ROOT}/test/zenoh/run"
}

@test "Zenoh bridges allow the typed Trace Context topic" {
  local config

  for config in \
    "${REPOSITORY_ROOT}/config/zenoh/source.json5" \
    "${REPOSITORY_ROOT}/config/zenoh/destination.json5"; do
    run grep -c '"\^/robotics/trace_context\$"' "${config}"
    [ "${status}" -eq 0 ]
    [ "${output}" -eq 2 ]
    run grep -F '/robotics/qualification' "${config}"
    [ "${status}" -eq 1 ]
  done
}

@test "Zenoh probes write reports as the host user" {
  run grep -F \
    'user: "${ROBOTICS_HOST_UID:-1000}:${ROBOTICS_HOST_GID:-1000}"' \
    "${COMPOSE_FILE}"
  [ "${status}" -eq 0 ]

  run grep -E \
    'export ROBOTICS_HOST_(UID|GID)=.*id -[ug]' \
    "${RUNNER}"
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | wc -l)" -eq 2 ]
}

@test "Zenoh bridges inspect the canonical ROS distribution" {
  run grep -A1 '^  environment:$' "${COMPOSE_FILE}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ROS_DISTRO: jazzy"* ]]
}

@test "Zenoh report filter is executable and enforces the delivery threshold" {
  run jq -n \
    --arg message_type robotics_observability_msgs/msg/TraceContext \
    --arg traceparent 00-0123456789abcdef0123456789abcdef-0123456789abcdef-01 \
    --arg tracestate runtime=zenoh \
    --argjson sent 20 \
    --argjson received 20 \
    --argjson states 20 \
    --argjson minimum 10 \
    -f "${REPORT_FILTER}"
  [ "${status}" -eq 0 ]

  run jq -e '.status == "passed"' <<<"${output}"
  [ "${status}" -eq 0 ]

  run jq -n \
    --arg message_type robotics_observability_msgs/msg/TraceContext \
    --arg traceparent 00-0123456789abcdef0123456789abcdef-0123456789abcdef-01 \
    --arg tracestate runtime=zenoh \
    --argjson sent 20 \
    --argjson received 9 \
    --argjson states 9 \
    --argjson minimum 10 \
    -f "${REPORT_FILTER}"
  [ "${status}" -eq 0 ]

  run jq -e '.status == "failed"' <<<"${output}"
  [ "${status}" -eq 0 ]
}
