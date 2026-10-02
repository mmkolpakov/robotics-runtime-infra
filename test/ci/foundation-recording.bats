#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI before these tests}"
  FOUNDATION_PYTHON="$(dirname "${ROBOTICS_CONTRACTS_CLI}")/python"
  # shellcheck source=scripts/ci/foundation/lib.sh
  source "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh"
  SCENARIO="${BATS_TEST_TMPDIR}/scenario.json"
}

@test "foundation recording uses the smoke scenario's 30-second limit" {
  run foundation_recording_duration "${FOUNDATION_PYTHON}" \
    "${REPOSITORY_ROOT}/test/acceptance/stepped-smoke.yaml"
  [ "${status}" -eq 0 ]
  [ "${output}" = 30 ]
}

@test "foundation recording honors a consumer's shorter segment limit" {
  printf '{"evidence_policy":{"max_segment_duration_sec":7}}\n' >"${SCENARIO}"
  run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
  [ "${status}" -eq 0 ]
  [ "${output}" = 7 ]
}

@test "foundation recording rounds fractional limits down to whole seconds" {
  printf '{"evidence_policy":{"max_segment_duration_sec":7.9}}\n' >"${SCENARIO}"
  run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
  [ "${status}" -eq 0 ]
  [ "${output}" = 7 ]
}

@test "foundation recording keeps the one-second boundary bounded" {
  printf '{"evidence_policy":{"max_segment_duration_sec":1}}\n' >"${SCENARIO}"
  run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
  [ "${status}" -eq 0 ]
  [ "${output}" = 1 ]
}

@test "foundation recording rejects durations that cannot produce a bounded segment" {
  local duration
  for duration in 0.5 0 -1 true '"30"' null; do
    printf '{"evidence_policy":{"max_segment_duration_sec":%s}}\n' \
      "${duration}" >"${SCENARIO}"
    run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'finite segment duration of at least 1 second'* ]]
  done
}

@test "foundation recording rejects a missing duration instead of using Compose's default" {
  printf '{"evidence_policy":{}}\n' >"${SCENARIO}"
  run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
  [ "${status}" -ne 0 ]
}

@test "foundation recording uses the contracts parser to reject duplicate policy keys" {
  printf 'evidence_policy:\n  max_segment_duration_sec: 30\n  max_segment_duration_sec: 60\n' \
    >"${SCENARIO}"
  run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
  [ "${status}" -ne 0 ]
}

prepare_orchestration_fixture() {
  FIXTURE="${BATS_TEST_TMPDIR}/orchestration"
  local scripts="${FIXTURE}/scripts/ci"
  local bin="${FIXTURE}/dependencies/robotics-runtime/.venv/bin"
  mkdir -p "${scripts}/foundation" "${bin}"
  cp "${REPOSITORY_ROOT}/scripts/ci/foundation/"{lib.sh,run-acceptance.sh,run-policy.sh} \
    "${scripts}/foundation/"
  : >"${scripts}/image-identity.sh"
  # Keep the real orchestration and duration parser; stop at the first Compose
  # call. Image lookup, host inventory and run creation are unit fixtures.
  # The policy spy retains the actual parsed input and can reject the run.
  cat >"${scripts}/lib.sh" <<'SH'
cosign() { :; }
lscpu() { printf '{}\n'; }
ci_image_identity() { printf '{"digest":"fixture","reference":"fixture"}\n'; }
ci_require_policy_allows() {
  [[ "$1" == policy/scenario.rego && "$2" == scenario ]] || return 65
  cp -- "$3" "${FOUNDATION_SCENARIO_POLICY_INPUT}"
  return "${FOUNDATION_SCENARIO_POLICY_STATUS}"
}
docker() {
  printf '%s\n' "${ROBOTICS_MAX_BAG_DURATION:-unset}" >"${FOUNDATION_RECORDING_ENV}"
  return 88
}
SH
  cat >"${bin}/python" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == -c ]]; then
  printf '{}\n'
else
  exec "${FOUNDATION_REAL_PYTHON}" "$@"
fi
SH
  printf '#!/usr/bin/env bash\nprintf "run-fixture\\n"\n' >"${bin}/robotics-acceptance"
  chmod +x "${bin}/python" "${bin}/robotics-acceptance"
  export FOUNDATION_REAL_PYTHON="${FOUNDATION_PYTHON}"
  export FOUNDATION_RECORDING_ENV="${BATS_TEST_TMPDIR}/compose-duration"
  export FOUNDATION_SCENARIO_POLICY_INPUT="${BATS_TEST_TMPDIR}/scenario-policy-input.json"
  export FOUNDATION_SCENARIO_POLICY_STATUS=0
  export ROBOTICS_FOUNDATION_SCENARIO="${SCENARIO}"
  export ROBOTICS_FOUNDATION_RUN_ID=recording-unit
  export ROBOTICS_FOUNDATION_ARTIFACT_DIR="${FIXTURE}/artifacts"
  export SIMULATION_IMAGE=fixture EVIDENCE_IMAGE=fixture
  export ROBOTICS_MAX_BAG_DURATION=60
}

@test "acceptance exports the scenario duration before Compose resolves recorder and sink" {
  prepare_orchestration_fixture
  printf '{"evidence_policy":{"max_segment_duration_sec":7}}\n' >"${SCENARIO}"
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -eq 88 ]
  jq -e '.evidence_policy.max_segment_duration_sec == 7' \
    "${FOUNDATION_SCENARIO_POLICY_INPUT}" >/dev/null
  [ "$(cat "${FOUNDATION_RECORDING_ENV}")" = 7 ]
}

@test "acceptance stops before Compose when the scenario policy rejects the run" {
  prepare_orchestration_fixture
  export FOUNDATION_SCENARIO_POLICY_STATUS=23
  printf '{"evidence_policy":{"max_segment_duration_sec":7}}\n' >"${SCENARIO}"
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -eq 23 ]
  jq -e '.evidence_policy.max_segment_duration_sec == 7' \
    "${FOUNDATION_SCENARIO_POLICY_INPUT}" >/dev/null
  [ ! -e "${FOUNDATION_RECORDING_ENV}" ]
}

@test "acceptance stops before Compose if the scenario duration cannot be configured" {
  prepare_orchestration_fixture
  printf '{"evidence_policy":{"max_segment_duration_sec":0.5}}\n' >"${SCENARIO}"
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -ne 0 ]
  [ "${status}" -ne 88 ]
  [[ "${output}" == *'finite segment duration of at least 1 second'* ]]
  [ ! -e "${FOUNDATION_RECORDING_ENV}" ]
}
