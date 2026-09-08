#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  export MOCK_ROS_SETUP="${BATS_TEST_TMPDIR}/setup.bash"
  export MOCK_ROS_BIN="${BATS_TEST_TMPDIR}/bin"
  export ROS_DISTRO=healthcheck-test
  export BASH_ENV="${BATS_TEST_TMPDIR}/bash-env"
  # Translate only the absolute ROS setup path for this host fixture. Execute
  # the checked-in entrypoint and Dockerfile command without rewriting either.
  cat >"${BASH_ENV}" <<'EOF'
source() {
  if [[ "$1" == /opt/ros/healthcheck-test/setup.bash ]]; then
    builtin source "${MOCK_ROS_SETUP}"
  else
    builtin source "$@"
  fi
}
EOF
  cat >"${MOCK_ROS_SETUP}" <<'EOF'
export AMENT_PREFIX_PATH=/fixture/ros
export PATH="${MOCK_ROS_BIN}:${PATH}"
EOF
  cat >"${MOCK_ROS_BIN}/ros2" <<'EOF'
#!/usr/bin/env bash
test "${AMENT_PREFIX_PATH:-}" = /fixture/ros || exit 21
test "$1 $2" = 'pkg prefix' || exit 22
test "$3" = cv_bridge || test "$3" = performance_test || exit 23
exit "${ROS_PROBE_STATUS:-0}"
EOF
  cat >"${MOCK_ROS_BIN}/gst-launch-1.0" <<'EOF'
#!/usr/bin/env bash
test "$1" = --version || exit 24
exit "${GST_PROBE_STATUS:-0}"
EOF
  chmod +x "${MOCK_ROS_BIN}/"*
  unset AMENT_PREFIX_PATH
}

healthcheck() {
  local stage="$1" json
  local -a probe
  json="$(awk -v stage="${stage}-runtime" '
    /^FROM / { active = ($NF == stage) }
    active && /^HEALTHCHECK / { check = 1; next }
    check && /CMD / { sub(/^ *CMD /, ""); print; exit }
  ' "${ROOT}/Dockerfile")"
  mapfile -t probe < <(jq -br '.[]' <<<"${json}")
  test "${probe[0]}" = /usr/local/bin/robotics-entrypoint || return 25
  bash "${ROOT}/docker/entrypoint.sh" "${probe[@]:1}"
}

@test "sensor and benchmark healthchecks get ROS environment from the real entrypoint" {
  run healthcheck sensor
  [ "${status}" -eq 0 ]
  run healthcheck benchmark
  [ "${status}" -eq 0 ]
}

@test "healthchecks propagate missing ROS package and GStreamer failures" {
  export ROS_PROBE_STATUS=31
  run healthcheck sensor
  [ "${status}" -eq 31 ]
  run healthcheck benchmark
  [ "${status}" -eq 31 ]
  unset ROS_PROBE_STATUS
  export GST_PROBE_STATUS=32
  run healthcheck sensor
  [ "${status}" -eq 32 ]
}

@test "ROS probe fails without sourcing the entrypoint environment" {
  run "${MOCK_ROS_BIN}/ros2" pkg prefix cv_bridge
  [ "${status}" -eq 21 ]
}
