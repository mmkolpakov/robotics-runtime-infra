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
