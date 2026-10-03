#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  source "${ROOT}/scripts/ci/foundation/lib.sh"
  CONSUMER="${BATS_TEST_TMPDIR}/consumer"
  mkdir -p "${CONSUMER}/inputs"
  printf 'original bytes\n' >"${CONSUMER}/inputs/artifact file.txt"
  printf '{"type":"object"}\n' >"${CONSUMER}/inputs/schema.json"
  ARGUMENTS="${CONSUMER}/artifact-arguments.txt"
}

@test "empty optional arguments preserve the stock inventory vector" {
  FOUNDATION_ARTIFACT_ARGUMENTS=(stale)
  foundation_load_artifact_arguments "${CONSUMER}" ""
  [ "${#FOUNDATION_ARTIFACT_ARGUMENTS[@]}" -eq 0 ]
}

@test "artifact and extension paths retain spaces and internal aliases" {
  ln -s "inputs/artifact file.txt" "${CONSUMER}/artifact-alias"
  printf '%s\n' --artifact 'other_evidence:consumer/data=artifact-alias' \
    --extension-schema 'https://example.org/schema.json=inputs/schema.json' >"${ARGUMENTS}"
  foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
  [ "${#FOUNDATION_ARTIFACT_ARGUMENTS[@]}" -eq 4 ]
  [ "${FOUNDATION_ARTIFACT_ARGUMENTS[1]}" = "other_evidence:consumer/data=${CONSUMER}/inputs/artifact file.txt" ]
  [ "${FOUNDATION_ARTIFACT_ARGUMENTS[3]}" = "https://example.org/schema.json=${CONSUMER}/inputs/schema.json" ]
  [ "$(cat "${CONSUMER}/inputs/artifact file.txt")" = 'original bytes' ]
}

@test "literal shell text in a subject never executes" {
  cd "${BATS_TEST_TMPDIR}"
  printf '%s\n' --artifact 'other_evidence:$(touch injected)=inputs/schema.json' >"${ARGUMENTS}"
  foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
  [[ "${FOUNDATION_ARTIFACT_ARGUMENTS[1]}" == 'other_evidence:$(touch injected)='* ]]
  [ ! -e injected ]
}

@test "consumer flags cannot select output or verification trust" {
  local option
  for option in --output --bundle --key --policy --trusted-root --scenario; do
    printf '%s\n' "${option}" inputs/schema.json >"${ARGUMENTS}"
    run foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
    [ "${status}" -eq 64 ]
    [[ "${output}" == *'unsupported consumer artifact argument'* ]]
  done
}

@test "an incomplete argument pair is rejected" {
  printf '%s\n' --artifact >"${ARGUMENTS}"
  run foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *'requires a value'* ]]
}

@test "the final argument does not require a trailing newline" {
  printf '%s\n%s' --artifact 'other_evidence:data=inputs/schema.json' >"${ARGUMENTS}"
  foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
  [ "${#FOUNDATION_ARTIFACT_ARGUMENTS[@]}" -eq 2 ]
}

@test "sibling prefixes and symlinks leaving the consumer are rejected" {
  mkdir -p "${CONSUMER}-foreign"
  printf 'foreign\n' >"${CONSUMER}-foreign/data"
  ln -s "${CONSUMER}-foreign/data" "${CONSUMER}/outside"
  local path
  for path in "../consumer-foreign/data" outside; do
    printf '%s\n' --artifact "other_evidence:data=${path}" >"${ARGUMENTS}"
    run foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
    [ "${status}" -eq 64 ]
    [[ "${output}" == *'outside its repository'* ]]
  done
}

@test "the arguments file cannot escape through a symlink" {
  printf '%s\n' --artifact 'other_evidence:data=inputs/schema.json' \
    >"${BATS_TEST_TMPDIR}/outside-arguments"
  ln -s "${BATS_TEST_TMPDIR}/outside-arguments" "${ARGUMENTS}"
  run foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
  [ "${status}" -eq 64 ]
}

@test "directories and absent artifact paths are rejected" {
  local path
  for path in inputs inputs/absent.json; do
    printf '%s\n' --artifact "other_evidence:data=${path}" >"${ARGUMENTS}"
    run foundation_load_artifact_arguments "${CONSUMER}" "${ARGUMENTS}"
    [ "${status}" -eq 64 ]
  done
}

@test "raw and symlink-target control characters cannot select a trimmed filename" {
  printf 'different newline file\n' >"${CONSUMER}/inputs/schema.json"$'\n'
  run foundation_consumer_file "${CONSUMER}" "inputs/schema.json"$'\n'
  [ "${status}" -eq 64 ]
  ln -s "inputs/schema.json"$'\n' "${CONSUMER}/newline-alias"
  run foundation_consumer_file "${CONSUMER}" newline-alias
  [ "${status}" -eq 64 ]
  [ "$(cat "${CONSUMER}/inputs/schema.json")" = '{"type":"object"}' ]
}

@test "portable explanation writes relative reports in the caller directory" {
  local python="${ROBOTICS_FOUNDATION_PYTHON:?use the installed foundation interpreter}"
  local caller="${BATS_TEST_TMPDIR}/caller with spaces"
  mkdir -p "${caller}/reports relative"
  "${python}" -I - "${ROOT}" "${caller}/retained package" <<'PY'
import hashlib
import json
import shutil
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping, validate_role

root, package = map(Path, sys.argv[1:])
subjects = package / "subjects"
product = subjects / "products/robot-description"
manifest_path = "examples/neutral-robot/sim/robot-description.json"
manifest = load_mapping(root / manifest_path)
for relative in (
    manifest_path,
    manifest["description"]["path"],
    f"{manifest['package']['path']}/package.xml",
):
    target = product / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / relative, target)
scenario = load_mapping(root / "examples/neutral-robot/scenario.yaml")
runtime = load_mapping(root / "test/qualification/fixtures/runtime-manifest.json")
runtime["workload"]["robot_description"] = {
    "sha256": hashlib.sha256((product / manifest_path).read_bytes()).hexdigest()
}
validate_role(scenario, "acceptance_scenario")
validate_role(runtime, "runtime_manifest")
for relative, document in (
    ("scenario.json", scenario),
    ("runtime-manifests/primary.json", runtime),
):
    target = subjects / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(document), encoding="utf-8")
(package / "qualification-arguments.txt").write_text(
    "--artifact\nscenario:scenario.json=subjects/scenario.json\n"
    "--artifact\nruntime_manifest:runtime-manifests/primary.json=subjects/runtime-manifests/primary.json\n"
    f"--artifact\nother_evidence:products/robot-description/{manifest_path}=subjects/products/robot-description/{manifest_path}\n",
    encoding="utf-8",
)
PY
  cd "${caller}"
  local before
  before="$(find 'retained package' -type f -exec sha256sum {} + | sort)"
  run foundation_explain_qualification 'retained package' \
    'reports relative/explain.json' simulator "${python}" -I -m robotics_acceptance_harness.cli
  [ "${status}" -eq 0 ]
  [ "${PWD}" = "${caller}" ]
  jq -e '.selected == true and
    .description_path == "ros_ws/src/robotics_runtime_infra/description/neutral_robot.urdf"' \
    'reports relative/explain.robot-description.json' >/dev/null
  jq -e '.execution.data_source == "simulator"' 'reports relative/explain.json' >/dev/null
  run foundation_explain_qualification 'retained package' \
    "${caller}/absolute.json" simulator "${python}" -I -m robotics_acceptance_harness.cli
  [ "${status}" -eq 0 ]
  cmp 'reports relative/explain.json' absolute.json
  cmp 'reports relative/explain.robot-description.json' absolute.robot-description.json
  [ "$(find 'retained package' -type f -exec sha256sum {} + | sort)" = "${before}" ]

  printf '\n' >>'retained package/subjects/products/robot-description/ros_ws/src/robotics_runtime_infra/description/neutral_robot.urdf'
  run foundation_explain_qualification 'retained package' \
    'reports relative/rejected.json' simulator "${python}" -I -m robotics_acceptance_harness.cli
  [ "${status}" -ne 0 ]
  [ ! -e 'reports relative/rejected.json' ]
}
