#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"

if [[ "${ROBOTICS_FOUNDATION_QUALIFY_PLAYBACK:-0}" == 1 &&
  "${ROBOTICS_RUNTIME_MODE:-source}" != source ]]; then
  printf 'same-job stock playback qualification requires source mode\n' >&2
  exit 64
fi

base_run_id="$(foundation_run_id)"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
run_a="${base_run_id}-acceptance-a"
run_b="${base_run_id}-acceptance-b"
project_a="$(foundation_project_name acceptance "${run_a}" "${run_attempt}")"
project_b="$(foundation_project_name acceptance "${run_b}" "${run_attempt}")"
artifact_a="${root}/artifacts/${project_a}"
artifact_b="${root}/artifacts/${project_b}"
rm -rf "${artifact_a}" "${artifact_b}"
mkdir -p "${artifact_a}" "${artifact_b}"

run_acceptance() (
  export ROBOTICS_FOUNDATION_RUN_ID="$1"
  export ROBOTICS_FOUNDATION_ARTIFACT_DIR="$2"
  export ROS_DOMAIN_ID="$3"
  export GZ_PARTITION="$4"
  bash "${script_dir}/run-acceptance.sh"
)

run_acceptance "${run_a}" "${artifact_a}" 51 "${project_a}" &
pid_a=$!
run_acceptance "${run_b}" "${artifact_b}" 52 "${project_b}" &
pid_b=$!

status_a=0
status_b=0
wait "${pid_a}" || status_a=$?
wait "${pid_b}" || status_b=$?
cleanup_status=0
project_b_status=0
foundation_assert_project_clean "${project_a}" || cleanup_status=$?
foundation_assert_project_clean "${project_b}" || project_b_status=$?
if ((status_a != 0 || status_b != 0)); then
  printf 'parallel acceptance failed: a=%s b=%s\n' "${status_a}" "${status_b}" >&2
  exit 1
fi
if ((cleanup_status != 0)); then
  exit "${cleanup_status}"
fi
if ((project_b_status != 0)); then
  exit "${project_b_status}"
fi

mkdir -p "${root}/artifacts"
cp -a "${artifact_a}/." "${root}/artifacts/"


if [[ "${ROBOTICS_FOUNDATION_QUALIFY_PLAYBACK:-0}" == 1 ]]; then
  source_run="${root}/runs/${project_a}"
  prepared="${root}/runs/${project_a}-playback-inputs"
  # Reuse the exact coordinator built and observed by this job's installed ROS gate.
  coordinator_record="${root}/artifacts/installed-ros/installed-ros-${GITHUB_RUN_ID:?same-job coordinator required}-${GITHUB_RUN_ATTEMPT:?same-job attempt required}/coordinator-images.json"
  coordinator_image="$(jq -er '
    map(.Id) | unique | select(length == 1) | .[0]
    | select(test("^sha256:[a-f0-9]{64}$"))
  ' "${coordinator_record}")"
  [[ "$(docker image inspect --format '{{.Id}}' "${coordinator_image}")" == "${coordinator_image}" ]]
  # Select that image only for these finite jobs, preserving the stock ROS entrypoint.
  SIMULATION_IMAGE="${coordinator_image}" ROBOTICS_RUN_DIR="${source_run}" docker compose \
    -f "${root}/compose.yaml" --profile acceptance run --rm --no-deps --pull never \
    --entrypoint /usr/local/bin/robotics-entrypoint \
    --user "$(id -u):$(id -g)" --volume "${root}:/tooling:ro" \
    runtime-manifest /opt/contracts/bin/python /tooling/test/ci/prepare-playback-inputs.test.py
  # Prepare from the genuine finalized first stock phase, without rewriting it.
  SIMULATION_IMAGE="${coordinator_image}" ROBOTICS_RUN_DIR="${source_run}" docker compose \
    -f "${root}/compose.yaml" --profile acceptance run --rm --no-deps --pull never \
    --entrypoint /usr/local/bin/robotics-entrypoint \
    --user "$(id -u):$(id -g)" \
    --volume "${source_run}:/source:ro" \
    --volume "${source_run}:/run/robotics:ro" \
    --volume "${root}/runs:/prepared" \
    --volume "${root}/scripts/ci/integration/prepare-playback-inputs.py:/tmp/prepare-playback-inputs.py:ro" \
    runtime-manifest /opt/contracts/bin/python /tmp/prepare-playback-inputs.py \
    --source-run-dir /source --output "/prepared/${project_a}-playback-inputs" \
    --host-output "${prepared}"
  ROBOTICS_FOUNDATION_SCENARIO="${prepared}/scenario.json" \
    ROBOTICS_FOUNDATION_PLAYBACK_INPUTS="${prepared}" \
    run_acceptance "${base_run_id}-recorded-playback" \
      "${root}/artifacts/playback" 54 "${base_run_id}-recorded-playback"
fi
