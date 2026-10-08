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
  INTEGRATION_PROJECT="${REPOSITORY_ROOT}/foundation.repos"
  INTEGRATION_LOCK="${REPOSITORY_ROOT}/config/foundation-lock.json"
  QUALIFICATION_POLICY="${REPOSITORY_ROOT}/trust/qualification-policy.json"
  QUALIFICATION_ROOT="${REPOSITORY_ROOT}/trust/qualification.trusted-root.json"
  # shellcheck source=scripts/ci/foundation/lib.sh
  source "${LIBRARY}"
  # shellcheck source=scripts/ci/lib.sh
  source "${CI_LIBRARY}"
}

@test "runtime foundation imports one workspace and derives the package lock" {
  run jq -e '.repositories | keys == ["robotics-runtime"]' "${INTEGRATION_PROJECT}"
  [ "${status}" -eq 0 ]
  run jq -e '.workspace.uv_lock_sha256 | test("^[a-f0-9]{64}$")' "${INTEGRATION_LOCK}"
  [ "${status}" -eq 0 ]
  run grep -F 'foundation_project=dependencies/robotics-runtime' "${VALIDATION_SCRIPT}"
  [ "${status}" -eq 0 ]
  run jq -e '.packages.contracts.distribution == "robotics-runtime-contracts" and
    .packages.harness.distribution == "robotics-acceptance-harness"' "${INTEGRATION_LOCK}"
  [ "${status}" -eq 0 ]
}

@test "undefined policy queries fail closed" {
  ci_opa() {
    printf '{"result":[]}\n'
  }

  run ci_require_policy_allows policy.rego missing input.json

  [ "${status}" -ne 0 ]
}

@test "source import preserves a dirty checkout before invoking vcs" {
  local fixture="${BATS_TEST_TMPDIR}/import-fixture"
  local checkout="${fixture}/dependencies/robotics-runtime"
  mkdir -p "${fixture}/scripts/ci/foundation" "${checkout}"
  cp "${REPOSITORY_ROOT}/scripts/ci/foundation/import-sources.sh" \
    "${fixture}/scripts/ci/foundation/import-sources.sh"
  git -C "${checkout}" init --quiet
  printf 'original\n' >"${checkout}/input.txt"
  git -C "${checkout}" add input.txt
  git -C "${checkout}" -c user.name=Fixture \
    -c user.email=fixture@example.invalid commit --quiet -m fixture
  printf 'local edit\n' >"${checkout}/input.txt"

  run bash "${fixture}/scripts/ci/foundation/import-sources.sh"

  [ "${status}" -eq 65 ]
  [[ "${output}" == *"has local changes"* ]]
  [ "$(cat "${checkout}/input.txt")" = "local edit" ]
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
  # Match the literal production call site, without expanding its variables.
  # shellcheck disable=SC2016
  run grep -F 'foundation_render_consumer_model "${consumer_root}" "${consumer_file}"' "${ACCEPTANCE_SCRIPT}"
  [ "${status}" -eq 0 ]
  run grep -F 'COMPOSE_DISABLE_ENV_FILE=1' "${LIBRARY}"
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
  done
  run grep -F 'mapfile -t qualification_inputs <qualification-arguments.txt' "${KEYLESS_SCRIPT}"
  [ "${status}" -eq 0 ]
  run grep -F "'artifacts/qualification/'" "${WORKFLOW}"
  [ "${status}" -eq 0 ]
}

@test "foundation evidence uses a guarded upload ID and an attempt-scoped archive" {
  local python="${ROBOTICS_FOUNDATION_PYTHON:?use the installed foundation interpreter}"
  run "${python}" -I - "${WORKFLOW}" <<'PY'
import os
import subprocess
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping

jobs = load_mapping(Path(sys.argv[1]))["jobs"]
foundation = jobs["foundation"]
upload = next(step for step in foundation["steps"]
              if step.get("id") == "upload-foundation-evidence")
assert foundation["outputs"]["evidence-artifact-id"] == (
    "${{ steps.upload-foundation-evidence.outputs.artifact-id }}")
assert upload["with"]["name"] == (
    "foundation-reports-${{ github.sha }}-${{ github.run_attempt }}")
assert upload["if"] == "always()"
assert upload["with"]["path"] == "artifacts/"
assert upload["with"]["if-no-files-found"] == "error"
assert not upload["with"].get("overwrite", False)
consumer = jobs["trusted-keyless-qualification"]
assert consumer["needs"] == "foundation"
steps = consumer["steps"]
index = next(i for i, step in enumerate(steps)
             if step.get("uses", "").startswith("actions/download-artifact@"))
guard, download = steps[index - 1], steps[index]
assert guard["env"]["EVIDENCE_ARTIFACT_ID"] == (
    "${{ needs.foundation.outputs.evidence-artifact-id }}")
assert download["with"] == {
    "artifact-ids": "${{ needs.foundation.outputs.evidence-artifact-id }}",
    "path": "artifacts"}
assert "${{" not in guard["run"]
for artifact_id in ("11279763969", "", "0", "-1", "1,2", "1.0", "1\n2", "1; exit 0"):
    result = subprocess.run(
        ["bash", "-e", "-o", "pipefail", "-c", guard["run"]],
        env={**os.environ, "EVIDENCE_ARTIFACT_ID": artifact_id},
        capture_output=True, text=True, check=False)
    assert result.returncode == (0 if artifact_id == "11279763969" else 64), (
        artifact_id, result.returncode, result.stdout, result.stderr)
    assert result.stdout == ""
    if result.returncode:
        assert "must be one positive integer" in result.stderr
PY
  printf '%s\n' "${output}"
  [ "${status}" -eq 0 ]
}
