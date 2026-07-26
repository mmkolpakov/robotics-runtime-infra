#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  ACCEPTANCE_PHASE="${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
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

@test "acceptance phase retains telemetry evidence and aggregation" {
  run grep -E \
    'foundation-(metrics|traces)\.jq|evidence-sink artifact|acceptance-observer aggregate' \
    "${ACCEPTANCE_PHASE}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"foundation-metrics.jq"* ]]
  [[ "${output}" == *"foundation-traces.jq"* ]]
  [[ "${output}" == *"evidence-sink artifact"* ]]
  [[ "${output}" == *"acceptance-observer aggregate"* ]]
}
