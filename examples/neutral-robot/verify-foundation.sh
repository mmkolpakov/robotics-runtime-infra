#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${root}"
artifact_dir="${ROBOTICS_FOUNDATION_ARTIFACT_DIR:-artifacts/neutral-robot}"
mkdir -p -- "${artifact_dir}/negative"
python="${root}/dependencies/robotics-runtime/.venv/bin/python"
"${python}" - "${artifact_dir}/negative/scenario.yaml" <<'PY'
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping
import json
scenario = load_mapping("examples/neutral-robot/scenario.yaml")
scenario["workload"]["robot_description_sha256"] = "0" * 64
Path(sys.argv[1]).write_text(json.dumps(scenario), encoding="utf-8")
PY
# Exercise the real canonical runner in the same job as the positive robot.
set +e
ROBOTICS_FOUNDATION_SCENARIO="${artifact_dir}/negative/scenario.yaml"   ROBOTICS_FOUNDATION_ARTIFACT_ARGUMENTS_FILE=examples/neutral-robot/artifact-arguments.txt   ROBOTICS_FOUNDATION_ARTIFACT_DIR="${artifact_dir}/negative"   ROBOTICS_FOUNDATION_RUN_ID="${GITHUB_RUN_ID:-local}-robot-wrong-digest"   bash scripts/ci/foundation/run-acceptance.sh >"${artifact_dir}/negative/admission.log" 2>&1
status=$?
set -e
[[ "${status}" == 65 ]]
grep -F 'robot-description admission: scenario robot-description digest must select one retained manifest'   "${artifact_dir}/negative/admission.log" >/dev/null
test ! -e "${artifact_dir}/negative/acceptance-results"
test ! -e "${artifact_dir}/negative/robot-readiness"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'   '<testsuite name="robot-description-admission" tests="1" failures="0"><testcase name="wrong-manifest-digest-before-producers-and-observer"/></testsuite>'   >"${artifact_dir}/negative/junit.xml"
ROBOTICS_FOUNDATION_SCENARIO=examples/neutral-robot/scenario.yaml   ROBOTICS_FOUNDATION_ARTIFACT_ARGUMENTS_FILE=examples/neutral-robot/artifact-arguments.txt   ROBOTICS_FOUNDATION_ARTIFACT_DIR="${artifact_dir}"   ROBOTICS_FOUNDATION_RUN_ID="${GITHUB_RUN_ID:-local}-neutral-robot"   ROBOTICS_STEP_INTERVAL_SEC=0.01   bash scripts/ci/foundation/run-acceptance.sh
