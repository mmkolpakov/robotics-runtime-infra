#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  : "${ROBOTICS_FOUNDATION_PYTHON:?use the installed foundation interpreter}"
  WORKSPACE="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${WORKSPACE}/consumer" "${WORKSPACE}/tooling/scripts/qualification"
  export QUALIFICATION_ARGV_RECORD="${BATS_TEST_TMPDIR}/arguments.txt"
  cat >"${WORKSPACE}/tooling/scripts/qualification/verify-bundle" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${QUALIFICATION_ARGV_RECORD}"
SH
  chmod +x "${WORKSPACE}/tooling/scripts/qualification/verify-bundle"
  printf '%s\n' --bundle downloaded.sigstore.json --key downloaded.pub \
    >"${WORKSPACE}/consumer/arguments.txt"
  "${ROBOTICS_FOUNDATION_PYTHON}" - \
    "${REPOSITORY_ROOT}/.github/workflows/reusable-verify-qualification.yml" \
    "${BATS_TEST_TMPDIR}/verify-step.sh" <<'PY'
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping

workflow = load_mapping(sys.argv[1])
steps = workflow["jobs"]["verify"]["steps"]
commands = [
    step["run"] for step in steps
    if step.get("name") == "Verify the retained qualification package"
]
assert len(commands) == 1
Path(sys.argv[2]).write_text(commands[0], encoding="utf-8")
PY
  "${ROBOTICS_FOUNDATION_PYTHON}" - \
    "${REPOSITORY_ROOT}/.github/actions/verify-published-consumer/action.yml" \
    "${BATS_TEST_TMPDIR}" <<'PY'
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping

action = load_mapping(sys.argv[1])
steps = action["runs"]["steps"]
assert len(steps) == 2
for name, step in zip(("install-published", "verify-published"), steps, strict=True):
    Path(sys.argv[2], f"{name}.sh").write_text(step["run"], encoding="utf-8")
PY
  PUBLISHED_CONSUMER="${WORKSPACE}/temp/qualification-consumer"
  PACKAGE="${PUBLISHED_CONSUMER}/package"
  mkdir -p "${PUBLISHED_CONSUMER}/reports" "${PACKAGE}" \
    "${WORKSPACE}/tooling/scripts/ci/foundation"
  printf '%s\n' --bundle downloaded.sigstore.json --key downloaded.pub \
    >"${PACKAGE}/qualification-arguments.txt"
  export QUALIFICATION_EXPLAIN_RECORD="${BATS_TEST_TMPDIR}/explain-arguments.txt"
  cat >"${WORKSPACE}/tooling/scripts/ci/foundation/lib.sh" <<'SH'
foundation_explain_qualification() {
  printf '%s\n' "$@" >"${QUALIFICATION_EXPLAIN_RECORD}"
}
SH
}

run_workflow_verifier() {
  cd "${WORKSPACE}"
  run env GITHUB_WORKSPACE="${WORKSPACE}" ARGUMENTS_FILE=arguments.txt \
    BUNDLE=independent.sigstore.json PUBLIC_KEY="${PUBLIC_KEY}" \
    POLICY="${POLICY}" TRUSTED_ROOT="${TRUSTED_ROOT}" \
    bash -e "${BATS_TEST_TMPDIR}/verify-step.sh"
  [ "${status}" -eq 0 ]
}

@test "retained verifier keeps the selected bundle and public key authoritative" {
  PUBLIC_KEY=independent.pub POLICY= TRUSTED_ROOT=
  run_workflow_verifier
  run tail -n 4 "${QUALIFICATION_ARGV_RECORD}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = --bundle ]
  [ "${lines[1]}" = independent.sigstore.json ]
  [ "${lines[2]}" = --key ]
  [ "${lines[3]}" = independent.pub ]
}

@test "retained verifier keeps independent policy and root after downloaded options" {
  printf '%s\n' --bundle downloaded.sigstore.json \
    --trusted-root downloaded-root.json --policy downloaded-policy.json \
    >"${WORKSPACE}/consumer/arguments.txt"
  PUBLIC_KEY= POLICY=independent-policy.json TRUSTED_ROOT=independent-root.json
  run_workflow_verifier
  run tail -n 6 "${QUALIFICATION_ARGV_RECORD}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = --bundle ]
  [ "${lines[1]}" = independent.sigstore.json ]
  [ "${lines[2]}" = --trusted-root ]
  [ "${lines[3]}" = independent-root.json ]
  [ "${lines[4]}" = --policy ]
  [ "${lines[5]}" = independent-policy.json ]
}

run_published_consumer_verifier() {
  run env RUNNER_TEMP="${WORKSPACE}/temp" \
    TOOLING_DIRECTORY="${WORKSPACE}/tooling" PACKAGE_DIRECTORY="${PACKAGE}" \
    AUTHENTICATION="${AUTHENTICATION}" EXPECTED_EXECUTION_TYPE=simulator \
    bash -e "${BATS_TEST_TMPDIR}/verify-published.sh"
  [ "${status}" -eq 0 ]
}

@test "published consumer keeps the selected ephemeral bundle and key authoritative" {
  AUTHENTICATION=ephemeral
  run_published_consumer_verifier
  run tail -n 4 "${QUALIFICATION_ARGV_RECORD}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = --bundle ]
  [ "${lines[1]}" = "${PACKAGE}/qualification.sigstore.json" ]
  [ "${lines[2]}" = --key ]
  [ "${lines[3]}" = "${PACKAGE}/qualification.pub" ]
  run tail -n 5 "${QUALIFICATION_EXPLAIN_RECORD}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = simulator ]
  [ "${lines[1]}" = "${PUBLISHED_CONSUMER}/venv/bin/python" ]
  [ "${lines[2]}" = -I ]
  [ "${lines[3]}" = -m ]
  [ "${lines[4]}" = robotics_acceptance_harness.cli ]
}

@test "published consumer keeps its tooling policy and root after downloaded options" {
  printf '%s\n' --bundle downloaded.sigstore.json \
    --trusted-root downloaded-root.json --policy downloaded-policy.json \
    >"${PACKAGE}/qualification-arguments.txt"
  AUTHENTICATION=keyless
  run_published_consumer_verifier
  run tail -n 6 "${QUALIFICATION_ARGV_RECORD}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = --bundle ]
  [ "${lines[1]}" = "${PACKAGE}/qualification.keyless.sigstore.json" ]
  [ "${lines[2]}" = --trusted-root ]
  [ "${lines[3]}" = "${WORKSPACE}/tooling/trust/qualification.trusted-root.json" ]
  [ "${lines[4]}" = --policy ]
  [ "${lines[5]}" = "${WORKSPACE}/tooling/trust/qualification-policy.json" ]
}

@test "published consumer rejects unknown authentication before installation or verification" {
  run env AUTHENTICATION=unknown bash -e "${BATS_TEST_TMPDIR}/install-published.sh"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"unsupported qualification authentication"* ]]
  run env RUNNER_TEMP="${WORKSPACE}/temp" \
    TOOLING_DIRECTORY="${WORKSPACE}/tooling" PACKAGE_DIRECTORY="${PACKAGE}" \
    AUTHENTICATION=unknown EXPECTED_EXECUTION_TYPE=simulator \
    bash -e "${BATS_TEST_TMPDIR}/verify-published.sh"
  [ "${status}" -eq 64 ]
  [ ! -e "${QUALIFICATION_ARGV_RECORD}" ]
  [ ! -e "${QUALIFICATION_EXPLAIN_RECORD}" ]
}
