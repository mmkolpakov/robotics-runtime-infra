#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
  # shellcheck source=scripts/ci/lib.sh
  source scripts/ci/lib.sh
  ci_set_compose_fixture_env

  FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${FAKE_BIN}"
  # The fake ros2 decides the outcome, including a stop by timeout (124).
  cat >"${FAKE_BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  cat >"${FAKE_BIN}/ros2" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_ROS2_OUTPUT}"
exit "${FAKE_ROS2_STATUS}"
EOF
  chmod +x "${FAKE_BIN}/timeout" "${FAKE_BIN}/ros2"
}

# Compose config keeps $$ escapes; the container receives a single $.
negative_command() {
  local model
  model="$(
    docker compose -f compose.yaml -f compose.security.yaml \
      --profile '*' config --format json
  )"
  jq -er --arg service "$1" '
    .services[$service].command
    | select(.[0:4] == ["bash", "-Eeuo", "pipefail", "-c"])
    | .[4]
    | gsub("[$][$]"; "$")
  ' <<<"${model}"
}

# run_negative SERVICE STATUS OUTPUT
run_negative() {
  local script
  script="$(negative_command "$1")"
  run env PATH="${FAKE_BIN}:${PATH}" FAKE_ROS2_STATUS="$2" FAKE_ROS2_OUTPUT="$3" \
    bash -Eeuo pipefail -c "${script}"
}

publishing_talker="[INFO] [rcl]: Found security directory: /security/enclaves/talker
[INFO] [talker]: Publishing: 'Hello World: 1'"

@test "missing enclave check accepts the enforced initialization failure" {
  run_negative secure-missing-enclave 134 \
    "terminate called after throwing an instance of 'rclcpp::exceptions::RCLError'
  what():  failed to initialize rcl: SECURITY ERROR: directory '/security/enclaves/missing' does not exist., at ./src/rcl/security.c:202
[ros2run]: Aborted"
  [ "${status}" -eq 0 ]
}

@test "missing enclave check rejects a node that starts" {
  run_negative secure-missing-enclave 124 "${publishing_talker}"
  [ "${status}" -ne 0 ]

  run_negative secure-missing-enclave 124 \
    "[WARN] [rcl]: SECURITY ERROR: directory '/security/enclaves/missing' does not exist.
[INFO] [talker]: Publishing: 'Hello World: 1'"
  [ "${status}" -ne 0 ]
}

@test "missing enclave check rejects an unrelated failure" {
  run_negative secure-missing-enclave 1 "Package 'demo_nodes_cpp' not found"
  [ "${status}" -ne 0 ]
}

@test "denied publisher checks accept the enforced access-control failure" {
  local service

  for service in secure-denied-remap secure-observer-denied-command; do
    run_negative "${service}" 134 \
      "[SECURITY Error] rt/forbidden topic not found in allow rule.
terminate called after throwing an instance of 'rclcpp::exceptions::RCLError'
  what():  could not create publisher: create_publisher() could not create data writer, at ./src/publisher.cpp:275, at ./src/rcl/publisher.c:117
[ros2run]: Aborted"
    [ "${status}" -eq 0 ]
  done
}

@test "denied publisher checks reject a talker that publishes" {
  local service

  for service in secure-denied-remap secure-observer-denied-command; do
    run_negative "${service}" 124 "${publishing_talker}
[WARN] [talker]: permission file reloaded"
    [ "${status}" -ne 0 ]
  done
}
