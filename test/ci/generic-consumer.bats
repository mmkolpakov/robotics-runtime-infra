#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  # shellcheck source=scripts/ci/foundation/lib.sh
  source "${ROOT}/scripts/ci/foundation/lib.sh"
  PYTHON="${ROBOTICS_FOUNDATION_PYTHON:?use the installed foundation interpreter}"
  CONTRACTS="${PYTHON%/*}/robotics-contracts"
  HARNESS="${PYTHON%/*}/robotics-acceptance"
  SCENARIO="${ROOT}/examples/generic-consumer/scenario.yaml"
  OWNED="${BATS_TEST_TMPDIR}/owned"
  mkdir -p "${OWNED}"
  foundation_load_artifact_arguments "${ROOT}" "${ROOT}/examples/generic-consumer/artifact-arguments.txt"
  foundation_stage_extension_schemas "${OWNED}"
}

@test "generic caller registers original schema and opaque bytes through the public argument file" {
  local input="${ROOT}/examples/generic-consumer/inputs/opaque.bin"
  local schema="${ROOT}/examples/generic-consumer/inputs/extension.schema.json"
  [ "${#FOUNDATION_ARTIFACT_ARGUMENTS[@]}" -eq 4 ]
  [ "${FOUNDATION_ARTIFACT_ARGUMENTS[3]}" = "other_evidence:consumer/opaque.bin=${input}" ]
  cmp "${schema}" "${FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS[1]#*=}"
  run "${CONTRACTS}" validate --schema acceptance-scenario.v1 "${SCENARIO}" \
    "${FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS[@]}"
  [ "${status}" -eq 0 ]
  run "${HARNESS}" create-run --scenario "${SCENARIO}" --output "${OWNED}/run.json" \
    --domain primary=observer --time-authority sim_clock --time-source gazebo-clock \
    "${FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS[@]}"
  [ "${status}" -eq 0 ]
  [ -s "${OWNED}/run.json" ]
  [ "$(sha256sum "${input}" | cut -d' ' -f1)" = 50e02f4d9a97debab32bd2388182d81707c6b6e8d533ac702c313a791694ad23 ]
}

@test "generic caller missing registry refuses public run creation before output" {
  run "${HARNESS}" create-run --scenario "${SCENARIO}" --output "${OWNED}/refused.json" \
    --domain primary=observer --time-authority sim_clock --time-source gazebo-clock
  [ "${status}" -ne 0 ]
  [[ "${output}" == *schema\ document\ was\ not\ supplied* ]]
  [ ! -e "${OWNED}/refused.json" ]
}

@test "generic caller wrong digest and payload refuse public semantic validation" {
  local mode
  for mode in digest payload; do
    "${PYTHON}" -I - "${SCENARIO}" "${OWNED}/${mode}.json" "${mode}" <<'PY'
import json
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping

scenario = dict(load_mapping(sys.argv[1]))
if sys.argv[3] == "digest":
    scenario["extension_schemas"][0]["sha256"] = "0" * 64
else:
    scenario["extensions"]["org.example.generic-consumer.probe"]["marker"] = "wrong"
Path(sys.argv[2]).write_text(json.dumps(scenario))
PY
    run "${HARNESS}" create-run --scenario "${OWNED}/${mode}.json" \
      --output "${OWNED}/refused-${mode}.json" --domain primary=observer \
      --time-authority sim_clock --time-source gazebo-clock "${FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS[@]}"
    [ "${status}" -ne 0 ]
    if [[ "${mode}" == digest ]]; then
      [[ "${output}" == *schema\ digest\ does\ not\ match* ]]
    else
      [[ "${output}" == *generic-caller-v1* ]]
    fi
    [ ! -e "${OWNED}/refused-${mode}.json" ]
  done
}

@test "shared native document validator uses the selected public schema options" {
  run foundation_validate_document "${PYTHON}" "${SCENARIO}" "${FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS[@]}"
  [ "${status}" -eq 0 ]
  run foundation_validate_document "${PYTHON}" "${SCENARIO}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *extension.validation_failed* ]]
}

@test "replay parent translates selected package schemas read-only and confines retained caller options" {
  local consumer="${BATS_TEST_TMPDIR}/external caller"
  local source_run="${BATS_TEST_TMPDIR}/source run"
  local artifact_a="${BATS_TEST_TMPDIR}/original artifact"
  local root="${BATS_TEST_TMPDIR}/tooling"
  local project_a=registered-source
  mkdir -p "${consumer}/inputs" "${source_run}/configuration/extension-schemas" \
    "${artifact_a}/qualification/extension-schemas" "${root}/runs"
  local package="${artifact_a}/qualification"
  local uri=https://example.org/robotics/generic-consumer.schema.json
  cp "${ROOT}/examples/generic-consumer/inputs/extension.schema.json" "${package}/extension-schemas/original schema.json"
  printf '%s\n' --extension-schema "${uri}=extension-schemas/original schema.json" >"${package}/qualification-arguments.txt"
  cp "${ROOT}/examples/generic-consumer/inputs/opaque.bin" "${consumer}/inputs/original.bin"
  cp "${ROOT}/examples/generic-consumer/inputs/extension.schema.json" "${consumer}/inputs/mutable-schema.json"
  printf '%s\n' --artifact 'other_evidence:consumer/opaque.bin=inputs/original.bin' \
    --extension-schema "${uri}=inputs/mutable-schema.json" >"${consumer}/original-arguments.txt"
  export ROBOTICS_FOUNDATION_CONSUMER_ROOT="${consumer}"
  export ROBOTICS_FOUNDATION_ARTIFACT_ARGUMENTS_FILE="${consumer}/original-arguments.txt"
  local prepared="${root}/runs/${project_a}-playback-inputs"
  local script="${ROOT}/scripts/ci/foundation/run-acceptance-isolation.sh"
  local selection="${BATS_TEST_TMPDIR}/actual-selection.sh"
  awk '
    /^  source_schema_arguments=\(\)/ {capture=1}
    /^  # Reuse the exact coordinator/ {if(capture) exit}
    capture {print}
  ' "${script}" >"${selection}"
  # These current production variables are consumed by the extracted call site.
  # shellcheck disable=SC1090
  source "${selection}"
  # Variables are assigned by the actual extracted production source above.
  # shellcheck disable=SC2154
  [ "${source_schema_arguments[0]}" = --extension-schema ]
  [ "${source_schema_arguments[1]}" = "${uri}=/source-package/extension-schemas/original schema.json" ]
  # shellcheck disable=SC2154
  [ "${source_schema_mounts[0]}" = --volume ]
  [ "${source_schema_mounts[1]}" = "${package}:/source-package:ro" ]
  [[ "${prepared}" == "${consumer}/"* ]]
  mkdir -p "${prepared}/source/capture/extension-schemas"
  cp "${package}/extension-schemas/original schema.json" "${prepared}/source/capture/extension-schemas/retained.json"
  printf '%s\n' --extension-schema "${uri}=${prepared}/source/capture/extension-schemas/retained.json" \
    >"${prepared}/extension-schema-arguments.txt"
  printf 'changed after capture\n' >"${consumer}/inputs/mutable-schema.json"
  local merge="${BATS_TEST_TMPDIR}/actual-merge.sh"
  awk '
    /^  if \(\(\$\{#source_schema_arguments/ {capture=1}
    /^  ROBOTICS_FOUNDATION_ARTIFACT_ARGUMENTS_FILE=/ {if(capture) exit}
    capture {print}
  ' "${script}" >"${merge}"
  [ -s "${merge}" ]
  # shellcheck source=/dev/null
  source "${merge}"
  [ "${FOUNDATION_ARTIFACT_ARGUMENTS[0]}" = --artifact ]
  [ "${FOUNDATION_ARTIFACT_ARGUMENTS[1]}" = "other_evidence:consumer/opaque.bin=${consumer}/inputs/original.bin" ]
  [ "${FOUNDATION_ARTIFACT_ARGUMENTS[2]}" = --extension-schema ]
  [ "${FOUNDATION_ARTIFACT_ARGUMENTS[3]}" = "${uri}=${prepared}/source/capture/extension-schemas/retained.json" ]
  # shellcheck disable=SC2154
  [ "$(stat -c %a "${replay_argument_file}")" = 444 ]
  cmp "${ROOT}/examples/generic-consumer/inputs/extension.schema.json" \
    "${FOUNDATION_ARTIFACT_ARGUMENTS[3]#*=}"
}

@test "external playback nonce retains bytes and closes on success and original failure" {
  local function_file="${BATS_TEST_TMPDIR}/cleanup.sh"
  awk '/^cleanup_prepared_parent\(\) / {capture=1} /^if \[\[/ {if(capture) exit} capture {print}' \
    "${ROOT}/scripts/ci/foundation/run-acceptance-isolation.sh" >"${function_file}"
  local status_code
  for status_code in 0 17; do
    local caller_root="${BATS_TEST_TMPDIR}/caller-${status_code}"
    local artifact_a="${BATS_TEST_TMPDIR}/artifact-${status_code}"
    mkdir -p "${caller_root}"
    local prepared_parent
    prepared_parent="$(mktemp -d "${caller_root}/.robotics-playback.XXXXXX")"
    printf 'retained opaque bytes\n' >"${prepared_parent}/input.bin"
    run bash -c 'set -Eeuo pipefail; source "$1"; caller_root=$2; artifact_a=$3; prepared_parent=$4; trap cleanup_prepared_parent EXIT; exit "$5"' \
      cleanup "${function_file}" "${caller_root}" "${artifact_a}" "${prepared_parent}" "${status_code}"
    [ "${status}" -eq "${status_code}" ]
    [ ! -e "${prepared_parent}" ]
    [ "$(cat "${artifact_a}/playback-preparation/input.bin")" = "retained opaque bytes" ]
  done
}

@test "external playback cleanup refuses foreign directory and preserves original error" {
  local function_file="${BATS_TEST_TMPDIR}/cleanup.sh"
  awk '/^cleanup_prepared_parent\(\) / {capture=1} /^if \[\[/ {if(capture) exit} capture {print}' \
    "${ROOT}/scripts/ci/foundation/run-acceptance-isolation.sh" >"${function_file}"
  local caller_root="${BATS_TEST_TMPDIR}/caller"
  local foreign="${BATS_TEST_TMPDIR}/foreign"
  mkdir -p "${caller_root}" "${foreign}"
  printf 'foreign\n' >"${foreign}/keep"
  local original_status
  for original_status in 0 17; do
    run bash -c 'set -Eeuo pipefail; source "$1"; caller_root=$2; artifact_a=$3; prepared_parent=$4; trap cleanup_prepared_parent EXIT; exit "$5"' \
      cleanup "${function_file}" "${caller_root}" "${BATS_TEST_TMPDIR}/artifacts" "${foreign}" "${original_status}"
    if ((original_status == 0)); then [ "${status}" -eq 65 ]; else [ "${status}" -eq 17 ]; fi
    [ -f "${foreign}/keep" ]
    [ ! -e "${BATS_TEST_TMPDIR}/artifacts/playback-preparation" ]
  done
}

@test "external playback retention failure is nonzero and keeps issued input bytes" {
  local function_file="${BATS_TEST_TMPDIR}/cleanup.sh"
  awk '/^cleanup_prepared_parent\(\) / {capture=1} /^if \[\[/ {if(capture) exit} capture {print}' \
    "${ROOT}/scripts/ci/foundation/run-acceptance-isolation.sh" >"${function_file}"
  local caller_root="${BATS_TEST_TMPDIR}/caller"
  local artifact_a="${BATS_TEST_TMPDIR}/blocked-artifact"
  mkdir -p "${caller_root}"
  printf 'not a directory\n' >"${artifact_a}"
  local prepared_parent
  prepared_parent="$(mktemp -d "${caller_root}/.robotics-playback.XXXXXX")"
  printf 'original input\n' >"${prepared_parent}/input.bin"
  run bash -c 'set -Eeuo pipefail; source "$1"; caller_root=$2; artifact_a=$3; prepared_parent=$4; trap cleanup_prepared_parent EXIT; exit 0' \
    cleanup "${function_file}" "${caller_root}" "${artifact_a}" "${prepared_parent}"
  [ "${status}" -ne 0 ]
  [ "$(cat "${prepared_parent}/input.bin")" = "original input" ]
}
