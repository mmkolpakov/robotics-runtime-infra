#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  ACCEPTANCE_PHASE="${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
  ACCEPTANCE_ISOLATION_PHASE="${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance-isolation.sh"
  RUNTIME_MANIFEST_EMITTER="${REPOSITORY_ROOT}/docker/runtime/emit-runtime-manifest"
  LIBRARY="${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh"
  WORKFLOW="${REPOSITORY_ROOT}/.github/workflows/foundation-integration.yml"
  FOUNDATION_COMPOSE="${REPOSITORY_ROOT}/compose.foundation.yaml"
  QUALIFICATION_POLICY="${REPOSITORY_ROOT}/trust/qualification-policy.json"
  QUALIFICATION_ROOT="${REPOSITORY_ROOT}/trust/qualification.trusted-root.json"
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

@test "local and explicit foundation run identities are collision scoped" {
  ROBOTICS_FOUNDATION_RUN_ID=review-42 run foundation_run_id
  [ "${status}" -eq 0 ]
  [ "${output}" = "review-42" ]

  unset ROBOTICS_FOUNDATION_RUN_ID GITHUB_RUN_ID
  run foundation_run_id
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ ^local-[0-9]+$ ]]
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
  [ "$(printf '%s\n' "${output}" | wc -l)" -ge 11 ]
  ! printf '%s\n' "${output}" | grep -Ev \
    '^[[:space:]]+run: bash scripts/ci/foundation/[a-z-]+\.sh$'
}

@test "workflow contains no multiline run blocks" {
  run grep -E '^[[:space:]]+run:[[:space:]]*[|>]' "${WORKFLOW}"

  [ "${status}" -eq 1 ]
}

@test "required workflow reports a check for every pull request and main push" {
  run grep -E '^  pull_request:$' "${WORKFLOW}"
  [ "${status}" -eq 0 ]

  run grep -E '^  push:$' "${WORKFLOW}"
  [ "${status}" -eq 0 ]

  run grep -E '^[[:space:]]+paths:' "${WORKFLOW}"
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

@test "full acceptance isolation uses separate domains artifacts and projects" {
  run grep -E \
    'ROBOTICS_FOUNDATION_RUN_ID|ROBOTICS_FOUNDATION_ARTIFACT_DIR|ROS_DOMAIN_ID|GZ_PARTITION|foundation_assert_project_clean' \
    "${ACCEPTANCE_ISOLATION_PHASE}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ROBOTICS_FOUNDATION_RUN_ID"* ]]
  [[ "${output}" == *"ROBOTICS_FOUNDATION_ARTIFACT_DIR"* ]]
  [[ "${output}" == *"ROS_DOMAIN_ID"* ]]
  [[ "${output}" == *"GZ_PARTITION"* ]]
  [[ "${output}" == *"foundation_assert_project_clean"* ]]
}

@test "acceptance metrics start after runtime readiness and before observation" {
  local collector_ready_line
  local metrics_line
  local observer_line

  collector_ready_line="$(
    grep -n 'collector_health_address=.*port otel-collector 13133' \
      "${ACCEPTANCE_PHASE}" |
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
  run grep -F 'ROBOTICS_METRICS_EXPORT_INTERVAL_MS=200' \
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

@test "foundation binds the runtime manifest to the mounted Fast DDS profile" {
  run grep -F -- '-f compose.foundation.yaml' "${ACCEPTANCE_PHASE}"
  [ "${status}" -eq 0 ]
  run grep -F \
    'FASTRTPS_DEFAULT_PROFILES_FILE: /etc/robotics/fastdds/udp-only.xml' \
    "${FOUNDATION_COMPOSE}"
  [ "${status}" -eq 0 ]
  run grep -F \
    '.data_plane.fastdds_profile_sha256 == $digest' \
    "${ACCEPTANCE_PHASE}"
  [ "${status}" -eq 0 ]
  run grep -F \
    'other_evidence:fastdds-profile.xml=' \
    "${ACCEPTANCE_PHASE}"
  [ "${status}" -eq 0 ]
}

@test "ordinary foundation CI signs and verifies with real Cosign" {
  run grep -F \
    'sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6' \
    "${WORKFLOW}"
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | wc -l)" -eq 2 ]
  run grep -F 'cosign-release: v3.1.1' "${WORKFLOW}"
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | wc -l)" -eq 2 ]
  run grep -F \
    'bash scripts/ci/foundation/sign-ephemeral-qualification.sh' \
    "${ACCEPTANCE_PHASE}"
  [ "${status}" -eq 0 ]
  run grep -F \
    'scripts/qualification/verify-bundle' \
    "${ACCEPTANCE_PHASE}"
  [ "${status}" -eq 0 ]
}

@test "trusted keyless qualification is restricted to canonical main" {
  run grep -F \
    "github.repository == 'mmkolpakov/robotics-runtime-infra'" \
    "${WORKFLOW}"
  [ "${status}" -eq 0 ]
  run grep -F "github.ref == 'refs/heads/main'" "${WORKFLOW}"
  [ "${status}" -eq 0 ]
  run grep -F 'id-token: write' "${WORKFLOW}"
  [ "${status}" -eq 0 ]
  run jq -e '
    .certificate_identities == [
      "https://github.com/mmkolpakov/robotics-runtime-infra/.github/workflows/foundation-integration.yml@refs/heads/main"
    ] and
    .certificate_oidc_issuer ==
      "https://token.actions.githubusercontent.com"
  ' "${QUALIFICATION_POLICY}"
  [ "${status}" -eq 0 ]
}

@test "qualification policy pins the distributed Sigstore trusted root" {
  run jq -e \
    --arg digest "$(sha256sum "${QUALIFICATION_ROOT}" | cut -d' ' -f1)" \
    '.trusted_root_sha256 == $digest' \
    "${QUALIFICATION_POLICY}"
  [ "${status}" -eq 0 ]
  run grep -R -E \
    -- '--certificate-identity-regexp|--insecure-ignore-tlog' \
    "${REPOSITORY_ROOT}/scripts/ci/foundation/run-keyless-qualification.sh"
  [ "${status}" -eq 1 ]
  run grep -R -E \
    -- '--certificate-identity-regexp' \
    "${REPOSITORY_ROOT}/scripts/ci/foundation" \
    "${REPOSITORY_ROOT}/scripts/qualification"
  [ "${status}" -eq 1 ]
}
