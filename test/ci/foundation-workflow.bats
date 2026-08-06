#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  LIBRARY="${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh"
  WORKFLOW="${REPOSITORY_ROOT}/.github/workflows/foundation-integration.yml"
  ACCEPTANCE_SCRIPT="${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
  KEYLESS_SCRIPT="${REPOSITORY_ROOT}/scripts/ci/foundation/run-keyless-qualification.sh"
  QUALIFICATION_POLICY="${REPOSITORY_ROOT}/trust/qualification-policy.json"
  QUALIFICATION_ROOT="${REPOSITORY_ROOT}/trust/qualification.trusted-root.json"
  # shellcheck source=scripts/ci/foundation/lib.sh
  source "${LIBRARY}"
}

@test "project names are deterministic and collision scoped" {
  run foundation_project_name runtime 12345 2
  [ "${status}" -eq 0 ]
  [ "${output}" = foundation-12345-2 ]

  run foundation_project_name acceptance 12345 2
  [ "${status}" -eq 0 ]
  [ "${output}" = foundation-e2e-12345-2 ]
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

@test "required workflow reports a check for every pull request and main push" {
  run grep -E '^  pull_request:$' "${WORKFLOW}"
  [ "${status}" -eq 0 ]

  run grep -E '^  push:$' "${WORKFLOW}"
  [ "${status}" -eq 0 ]

  run grep -E '^[[:space:]]+paths:' "${WORKFLOW}"
  [ "${status}" -eq 1 ]
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
    "${KEYLESS_SCRIPT}"
  [ "${status}" -eq 1 ]
  run grep -R -E \
    -- '--certificate-identity-regexp' \
    "${REPOSITORY_ROOT}/scripts/ci/foundation" \
    "${REPOSITORY_ROOT}/scripts/qualification"
  [ "${status}" -eq 1 ]
}

@test "keyless qualification receives retained runtime configuration evidence" {
  local artifact
  for artifact in host-topology.json runtime-resources.json; do
    run grep -F -- \
      "other_evidence:${artifact}=\${run_dir}/configuration/${artifact}" \
      "${ACCEPTANCE_SCRIPT}"
    [ "${status}" -eq 0 ]
    run grep -F -- \
      "\"\${run_dir}/configuration/${artifact}\" \"\${artifact_dir}/\"" \
      "${ACCEPTANCE_SCRIPT}"
    [ "${status}" -eq 0 ]
    run grep -F -- \
      "other_evidence:${artifact}=artifacts/${artifact}" \
      "${KEYLESS_SCRIPT}"
    [ "${status}" -eq 0 ]
  done
}
