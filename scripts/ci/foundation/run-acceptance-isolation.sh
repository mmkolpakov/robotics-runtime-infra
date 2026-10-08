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


cleanup_prepared_parent() {
  local original_status=$? retained_status=0 actual
  trap - EXIT
  if [[ -n "${prepared_parent:-}" ]]; then
    actual="$(realpath -e -- "${prepared_parent}")" || retained_status=65
    [[ ! -L "${prepared_parent}" && "${actual}" == "${prepared_parent}" &&
      "${actual%/*}" == "${caller_root}" &&
      "${actual##*/}" =~ ^\.robotics-playback\.[a-zA-Z0-9]{6}$ ]] || retained_status=65
    if ((retained_status == 0)); then
      mkdir -p "${artifact_a}/playback-preparation" || retained_status=$?
    fi
    if ((retained_status == 0)); then
      cp -a -- "${prepared_parent}/." "${artifact_a}/playback-preparation/" || retained_status=$?
    fi
    # Retain diagnostics first; a failed copy leaves the issued input untouched.
    if ((retained_status == 0)); then
      rm -rf -- "${prepared_parent}" || retained_status=$?
    fi
  fi
  if ((original_status != 0)); then return "${original_status}"; fi
  return "${retained_status}"
}

if [[ "${ROBOTICS_FOUNDATION_QUALIFY_PLAYBACK:-0}" == 1 ]]; then
  source_run="${root}/runs/${project_a}"
  prepared="${root}/runs/${project_a}-playback-inputs"
  source_package="${artifact_a}/qualification"
  # Authenticate the same portable bytes immediately before replay selection.
  source_authentication_sha="$(sha256sum "${source_package}/qualification.sigstore.json" "${source_package}/qualification.pub")"
  source_statement_sha="$(jq -er '.dsseEnvelope.payload' "${source_package}/qualification.sigstore.json" | base64 --decode | sha256sum | cut -d' ' -f1)"
  (
    cd "${source_package}"
    mapfile -t portable_inputs <qualification-arguments.txt
    ROBOTICS_CONTRACTS_CLI="${root}/dependencies/robotics-runtime/.venv/bin/robotics-contracts" \
    "${root}/scripts/qualification/verify-bundle" "${portable_inputs[@]}" \
      --bundle qualification.sigstore.json --key qualification.pub
  )
  [[ "$(sha256sum "${source_package}/qualification.sigstore.json" "${source_package}/qualification.pub")" == "${source_authentication_sha}" ]]
  [[ "$(sha256sum "${source_package}/qualification-statement.json" | cut -d' ' -f1)" == "${source_statement_sha}" ]]
  source_schema_arguments=()
  source_schema_mounts=()
  replay_argument_file=""
  caller_root="$(realpath -e "${ROBOTICS_FOUNDATION_CONSUMER_ROOT:-${root}}")"
  if [[ -d "${source_run}/configuration/extension-schemas" ]]; then
    # Reuse selected portable options from the completed original package.
    source_package="${artifact_a}/qualification"
    foundation_load_artifact_arguments "${source_package}" "${source_package}/qualification-arguments.txt"
    for ((index=0; index<${#FOUNDATION_ARTIFACT_ARGUMENTS[@]}; index+=2)); do
      [[ "${FOUNDATION_ARTIFACT_ARGUMENTS[index]}" == --extension-schema ]] || continue
      value="${FOUNDATION_ARTIFACT_ARGUMENTS[index+1]}"
      path="${value#*=}"
      source_schema_arguments+=(--extension-schema "${value%%=*}=/source-package${path#"${source_package}"}")
    done
    ((${#source_schema_arguments[@]})) || {
      printf 'completed source package lacks its selected schema registry\n' >&2
      exit 65
    }
    source_schema_mounts=(--volume "${source_package}:/source-package:ro")
    # An external caller keeps its own confined replay files and service paths.
    case "${prepared}" in "${caller_root}"/*) ;;
      *)
        prepared_parent="$(mktemp -d "${caller_root}/.robotics-playback.XXXXXX")"
        trap cleanup_prepared_parent EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        prepared="${prepared_parent}/inputs"
        ;;
    esac
  fi
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
    --volume "$(dirname "${prepared}"):/prepared" \
    "${source_schema_mounts[@]}" \
    --volume "${root}/scripts/ci/integration/prepare-playback-inputs.py:/tmp/prepare-playback-inputs.py:ro" \
    runtime-manifest /opt/contracts/bin/python /tmp/prepare-playback-inputs.py \
    --source-run-dir /source --output "/prepared/$(basename "${prepared}")" \
    --host-output "${prepared}" --source-statement-sha256 "${source_statement_sha}" "${source_schema_arguments[@]}"
  if ((${#source_schema_arguments[@]})); then
    # Preserve caller artifact options; only schema sources use retained replay bytes.
    foundation_load_artifact_arguments "${caller_root}" "${ROBOTICS_FOUNDATION_ARTIFACT_ARGUMENTS_FILE:-}"
    replay_argument_file="${prepared}/artifact-arguments.txt"
    : >"${replay_argument_file}"
    for ((index=0; index<${#FOUNDATION_ARTIFACT_ARGUMENTS[@]}; index+=2)); do
      [[ "${FOUNDATION_ARTIFACT_ARGUMENTS[index]}" != --extension-schema ]] || continue
      printf '%s\n' "${FOUNDATION_ARTIFACT_ARGUMENTS[index]}" "${FOUNDATION_ARTIFACT_ARGUMENTS[index+1]}" >>"${replay_argument_file}"
    done
    cat "${prepared}/extension-schema-arguments.txt" >>"${replay_argument_file}"
    foundation_load_artifact_arguments "${caller_root}" "${replay_argument_file}"
    chmod 0444 "${replay_argument_file}"
  fi
  ROBOTICS_FOUNDATION_ARTIFACT_ARGUMENTS_FILE="${replay_argument_file:-${ROBOTICS_FOUNDATION_ARTIFACT_ARGUMENTS_FILE:-}}" \
  ROBOTICS_FOUNDATION_SCENARIO="${prepared}/scenario.json" \
    ROBOTICS_FOUNDATION_PLAYBACK_INPUTS="${prepared}" \
    run_acceptance "${base_run_id}-recorded-playback" \
      "${root}/artifacts/playback" 54 "${base_run_id}-recorded-playback"
fi
