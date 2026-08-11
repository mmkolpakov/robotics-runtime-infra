#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  LIBRARY="${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh"
  CI_LIBRARY="${REPOSITORY_ROOT}/scripts/ci/lib.sh"
  WORKFLOW="${REPOSITORY_ROOT}/.github/workflows/foundation-integration.yml"
  REUSABLE_WORKFLOW="${REPOSITORY_ROOT}/.github/workflows/reusable-qualify.yml"
  ACCEPTANCE_SCRIPT="${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
  KEYLESS_SCRIPT="${REPOSITORY_ROOT}/scripts/ci/foundation/run-keyless-qualification.sh"
  VALIDATION_SCRIPT="${REPOSITORY_ROOT}/scripts/ci/foundation/validate-foundation.sh"
  INTEGRATION_PROJECT="${REPOSITORY_ROOT}/tooling/foundation/pyproject.toml"
  INTEGRATION_LOCK="${REPOSITORY_ROOT}/tooling/foundation/uv.lock"
  QUALIFICATION_POLICY="${REPOSITORY_ROOT}/trust/qualification-policy.json"
  QUALIFICATION_ROOT="${REPOSITORY_ROOT}/trust/qualification.trusted-root.json"
  # shellcheck source=scripts/ci/foundation/lib.sh
  source "${LIBRARY}"
  # shellcheck source=scripts/ci/lib.sh
  source "${CI_LIBRARY}"
}

@test "runtime foundation owns the joint Python lock" {
  [ -f "${INTEGRATION_PROJECT}" ]
  [ -f "${INTEGRATION_LOCK}" ]
  run grep -F 'foundation_project=tooling/foundation' "${VALIDATION_SCRIPT}"
  [ "${status}" -eq 0 ]
  run grep -E 'uv sync --project .*dependencies/robotics-' "${VALIDATION_SCRIPT}"
  [ "${status}" -eq 1 ]
  run grep -F 'robotics-acceptance-harness' "${INTEGRATION_PROJECT}"
  [ "${status}" -eq 0 ]
  run grep -F 'robotics-runtime-contracts' "${INTEGRATION_PROJECT}"
  [ "${status}" -eq 0 ]
}

@test "undefined policy queries fail closed" {
  ci_opa() {
    printf '{"result":[]}\n'
  }

  run ci_require_policy_allows policy.rego missing input.json

  [ "${status}" -ne 0 ]
}

@test "consumer path validation resolves symlinks" {
  local consumer="${BATS_TEST_TMPDIR}/consumer"
  local outside="${BATS_TEST_TMPDIR}/outside"
  mkdir -p "${consumer}" "${outside}"
  ln -s "${outside}" "${consumer}/escape"
  jq -n --arg source "${consumer}/escape" '{
    services: {
      product: {
        volumes: [{type: "bind", source: $source, target: "/workspace/data"}]
      }
    }
  }' >"${BATS_TEST_TMPDIR}/model.json"

  run ci_require_model_paths_within_root \
    "${BATS_TEST_TMPDIR}/model.json" "${consumer}"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"escapes its repository"* ]]
}

@test "consumer source validation resolves config symlinks before Compose" {
  local consumer="${BATS_TEST_TMPDIR}/consumer-source"
  local outside="${BATS_TEST_TMPDIR}/outside-source"
  mkdir -p "${consumer}" "${outside}"
  touch "${outside}/settings.yaml"
  ln -s "${outside}" "${consumer}/escape"
  jq -n '{
    services: {},
    configs: {settings: {file: "escape/settings.yaml"}}
  }' >"${BATS_TEST_TMPDIR}/source-model.json"

  run ci_require_source_paths_within_root \
    "${BATS_TEST_TMPDIR}/source-model.json" "${consumer}"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"escapes its repository"* ]]
}

@test "reusable qualification treats the consumer as an isolated Compose project" {
  run grep -F 'compose_project:' "${REUSABLE_WORKFLOW}"
  [ "${status}" -eq 0 ]
  run grep -F 'compose_overlay' "${REUSABLE_WORKFLOW}"
  [ "${status}" -eq 1 ]
  run grep -F 'policy/foundation.rego' "${ACCEPTANCE_SCRIPT}"
  [ "${status}" -eq 0 ]
  run grep -F 'policy/consumer_compose_source.rego' "${ACCEPTANCE_SCRIPT}"
  [ "${status}" -eq 0 ]
  run grep -F 'COMPOSE_DISABLE_ENV_FILE=1' "${ACCEPTANCE_SCRIPT}"
  [ "${status}" -eq 0 ]
  run grep -F 'project_directory' "${ACCEPTANCE_SCRIPT}"
  [ "${status}" -eq 0 ]
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
