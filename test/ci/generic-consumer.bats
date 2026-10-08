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
