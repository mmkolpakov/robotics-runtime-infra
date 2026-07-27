#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  ACCEPTANCE_PHASE="${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
  RUNTIME_MANIFEST_EMITTER="${REPOSITORY_ROOT}/docker/runtime/emit-runtime-manifest"
  LIBRARY="${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh"
  WORKFLOW="${REPOSITORY_ROOT}/.github/workflows/foundation-integration.yml"
  # shellcheck source=scripts/ci/foundation/lib.sh
  source "${LIBRARY}"
}

@test "project names are deterministic and collision scoped" {
  run foundation_project_names 12345 2

  [ "${status}" -eq 0 ]
  [ "${output}" = "$(cat <<'EOF'
foundation-12345-2
foundation-a-12345-2
foundation-b-12345-2
foundation-e2e-12345-2
EOF
)" ]
}

@test "unknown project kinds fail closed" {
  run foundation_project_name unsupported 12345 2

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown foundation project kind"* ]]
}

@test "required environment checks identify the missing input" {
  unset FOUNDATION_TEST_REQUIRED
  run foundation_require_env FOUNDATION_TEST_REQUIRED

  [ "${status}" -eq 1 ]
  [ "${output}" = \
    "required environment variable is unset: FOUNDATION_TEST_REQUIRED" ]
}

@test "every foundation phase is valid Bash" {
  local script

  for script in "${REPOSITORY_ROOT}"/scripts/ci/foundation/*.sh; do
    run bash -n "${script}"
    [ "${status}" -eq 0 ]
  done
}

@test "workflow delegates every run step to one phase script" {
  run awk '/^        run:/ { print }' "${WORKFLOW}"

  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | wc -l)" -eq 11 ]
  ! printf '%s\n' "${output}" | grep -Ev \
    '^[[:space:]]+run: bash scripts/ci/foundation/[a-z-]+\.sh$'
}

@test "workflow contains no multiline run blocks" {
  run grep -E '^[[:space:]]+run:[[:space:]]*[|>]' "${WORKFLOW}"

  [ "${status}" -eq 1 ]
}

@test "acceptance phase retains measured telemetry evidence and aggregation" {
  run grep -E \
    'runtime-metrics|evidence-sink artifact|robotics-acceptance aggregate' \
    "${ACCEPTANCE_PHASE}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"runtime-metrics"* ]]
  [[ "${output}" == *"evidence-sink artifact"* ]]
  [[ "${output}" == *"robotics-acceptance aggregate"* ]]
}

@test "acceptance telemetry spans the scenario measurement window" {
  run grep -E \
    'foundation_require_env EVIDENCE_IMAGE SIMULATION_IMAGE|graph_ready_sec|stable_for_sec|execution_sec|SECONDS < telemetry_deadline' \
    "${ACCEPTANCE_PHASE}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == \
    *"foundation_require_env EVIDENCE_IMAGE SIMULATION_IMAGE"* ]]
  [[ "${output}" == *"graph_ready_sec"* ]]
  [[ "${output}" == *"stable_for_sec"* ]]
  [[ "${output}" == *"execution_sec"* ]]
  [[ "${output}" == *"SECONDS < telemetry_deadline"* ]]
}

@test "acceptance metrics start after runtime readiness and before observation" {
  local collector_ready_line
  local metrics_line
  local observer_line

  collector_ready_line="$(
    grep -n 'http://127.0.0.1:13133/' "${ACCEPTANCE_PHASE}" |
      cut -d: -f1
  )"
  metrics_line="$(
    grep -n 'runtime-probe-publisher runtime-metrics' \
      "${ACCEPTANCE_PHASE}" |
      cut -d: -f1
  )"
  observer_line="$(
    grep -n '^observer="$(' "${ACCEPTANCE_PHASE}" |
      cut -d: -f1
  )"

  [ -n "${collector_ready_line}" ]
  [ -n "${metrics_line}" ]
  [ -n "${observer_line}" ]
  [ "${collector_ready_line}" -lt "${metrics_line}" ]
  [ "${metrics_line}" -lt "${observer_line}" ]
  run grep -F \
    'simulation simulation-stepper recorder otel-collector runtime-metrics' \
    "${ACCEPTANCE_PHASE}"
  [ "${status}" -eq 1 ]
}

@test "acceptance phase publishes diagnostics before enforcing observer status" {
  local publish_line
  local status_line

  run grep -E \
    'observer_status=.*docker wait|publish_acceptance_results|observer exited with status' \
    "${ACCEPTANCE_PHASE}"

  [ "${status}" -eq 0 ]
  publish_line="$(
    grep -n '^publish_acceptance_results$' "${ACCEPTANCE_PHASE}" |
      head -n 1 |
      cut -d: -f1
  )"
  status_line="$(
    grep -n '^if ((observer_status != 0)); then$' "${ACCEPTANCE_PHASE}" |
      cut -d: -f1
  )"
  [ -n "${publish_line}" ]
  [ -n "${status_line}" ]
  [ "${publish_line}" -lt "${status_line}" ]
}

@test "stepped foundation defaults to one explicit physics step" {
  local stepped_compose="${REPOSITORY_ROOT}/compose.stepped.yaml"
  local scenario="${REPOSITORY_ROOT}/test/acceptance/stepped-smoke.yaml"

  run grep -F \
    'ROBOTICS_STEPS_PER_TICK: "${ROBOTICS_STEPS_PER_TICK:-1}"' \
    "${stepped_compose}"
  [ "${status}" -eq 0 ]
  run grep -F \
    'ROBOTICS_STEP_INTERVAL_SEC: "${ROBOTICS_STEP_INTERVAL_SEC:-0.2}"' \
    "${stepped_compose}"
  [ "${status}" -eq 0 ]
  run grep -F 'max_skipped_steps: 0' "${scenario}"
  [ "${status}" -eq 0 ]
  run grep -F 'qos_profile: sensor_data' "${scenario}"
  [ "${status}" -eq 0 ]
  run grep -F 'max_loss_ratio: 0' "${scenario}"
  [ "${status}" -eq 0 ]
  run grep -F 'name: /robotics/runtime_probe' "${scenario}"
  [ "${status}" -eq 0 ]
  run grep -A2 '^  runtime-probe-publisher:$' \
    "${REPOSITORY_ROOT}/compose.observability.yaml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"profiles: [acceptance]"* ]]
  run grep -F 'ROBOTICS_MAX_BAG_SIZE=1048576' "${ACCEPTANCE_PHASE}"
  [ "${status}" -eq 0 ]
  run grep -F 'ROBOTICS_MAX_SEGMENT_SIZE_BYTES=2097152' \
    "${ACCEPTANCE_PHASE}"
  [ "${status}" -eq 0 ]
  run grep -F \
    '${ROBOTICS_MAX_SEGMENT_SIZE_BYTES:-1073741824}' \
    "${REPOSITORY_ROOT}/compose.evidence.yaml"
  [ "${status}" -eq 0 ]
  run grep -F \
    'EVIDENCE_MAX_SEGMENT_SIZE_BYTES: "${ROBOTICS_MAX_BAG_SIZE' \
    "${REPOSITORY_ROOT}/compose.evidence.yaml"
  [ "${status}" -eq 1 ]
}

@test "runtime manifest reads the canonical foundation repository keys" {
  run grep -E \
    '\.repositories\["robotics-(runtime-contracts|acceptance-harness)"\]\.version' \
    "${RUNTIME_MANIFEST_EMITTER}"

  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | wc -l)" -eq 2 ]
}
