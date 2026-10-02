#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

readonly evidence_metrics_segment_index=900000
observer_mode="${ROBOTICS_FOUNDATION_OBSERVER:-embedded}"
case "${observer_mode}" in
  embedded|edge-attach) ;;
  *) printf 'unknown foundation observer: %s\n' "${observer_mode}" >&2; exit 64 ;;
esac

root="$(foundation_repository_root)"
cd "${root}"
readonly foundation_bin="${root}/dependencies/robotics-runtime/.venv/bin"
# shellcheck source=scripts/ci/lib.sh
source "${root}/scripts/ci/lib.sh"
# shellcheck source=scripts/ci/image-identity.sh
source "${root}/scripts/ci/image-identity.sh"
# shellcheck source=scripts/ci/foundation/released-mode.sh
source "${script_dir}/released-mode.sh"
# shellcheck source=scripts/ci/foundation/run-policy.sh
source "${script_dir}/run-policy.sh"

command -v cosign >/dev/null 2>&1 || {
  printf 'cosign is required for foundation qualification\n' >&2
  exit 69
}

run_id="$(foundation_run_id)"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
project="$(foundation_project_name acceptance "${run_id}" "${run_attempt}")"
artifact_dir="$(foundation_artifact_dir "${root}" "${project}")"
run_dir="${root}/runs/${project}"
scenario_source="${ROBOTICS_FOUNDATION_SCENARIO:-examples/minimal-consumer/scenario.yaml}"
[[ -f "${scenario_source}" ]] || {
  printf 'foundation scenario does not exist: %s\n' "${scenario_source}" >&2
  exit 66
}
rm -rf "${run_dir}"
mkdir -p \
  "${run_dir}/bags" \
  "${run_dir}/configuration" \
  "${run_dir}/evidence/recordings" \
  "${run_dir}/results" \
  "${run_dir}/logs" \
  "${artifact_dir}"
cp "${scenario_source}" "${run_dir}/scenario.yaml"
consumer_root="${ROBOTICS_FOUNDATION_CONSUMER_ROOT:-${root}}"
foundation_prepare_execution_mode "${consumer_root}" "${artifact_dir}/release"
foundation_require_env EVIDENCE_IMAGE SIMULATION_IMAGE
compose_environment=()
if [[ "${ROBOTICS_RUNTIME_MODE}" == released ]]; then
  export ROBOTICS_INFRA_REVISION="${ROBOTICS_RELEASE_SOURCE_SHA}"
  compose_environment=(--env-file "${ROBOTICS_RELEASE_LOCK_SNAPSHOT}")
  bash "${script_dir}/verify-image-lock.sh"
fi
foundation_load_artifact_arguments "${consumer_root}" \
  "${ROBOTICS_FOUNDATION_ARTIFACT_ARGUMENTS_FILE:-}"
foundation_require_scenario_policy "${foundation_bin}/python" \
  "${run_dir}/scenario.yaml" "runs/${project}/scenario-policy-input.json"
cp "${run_dir}/scenario-policy-input.json" "${artifact_dir}/"
# Use the public parser for YAML; this also rejects duplicate scenario keys.
data_source="$("${foundation_bin}/python" - "${run_dir}/scenario.yaml" <<'PY'
import sys
from robotics_runtime_contracts import load_mapping
print(load_mapping(sys.argv[1]).get("execution", {}).get("data_source", "simulator"))
PY
)"
time_authority=sim_clock
time_source=gazebo-clock
case "${data_source}" in
  simulator) ;;
  recording_playback)
    [[ "${observer_mode}" == embedded ]] || {
      printf 'stock playback requires the embedded live observer\n' >&2; exit 64;
    }
    playback_inputs="${ROBOTICS_FOUNDATION_PLAYBACK_INPUTS:?prepared playback inputs are required}"
    cp -a -- "${playback_inputs}/source" "${run_dir}/source"
    cp -- "${playback_inputs}/dataset-manifest.json" "${run_dir}/dataset-manifest.json"
    cp -- "${playback_inputs}/playback-inputs.json" "${run_dir}/configuration/playback-inputs.json"
    cp -- "${root}/config/qualification/recorded-playback.json" "${run_dir}/profile.json"
    foundation_validate_document "${foundation_bin}/python" "${run_dir}/dataset-manifest.json"
    time_authority=playback_clock
    time_source=rosbag2-player-clock
    ;;
  *) printf 'unsupported foundation data source: %s\n' "${data_source}" >&2; exit 64 ;;
esac
lscpu --json >"${run_dir}/configuration/host-topology.json"
"${foundation_bin}/python" -c '
import json
import platform
release = platform.freedesktop_os_release()
print(json.dumps({"os": release["ID"], "os_version": release["VERSION_ID"],
                  "architecture": platform.machine(), "kernel": platform.release()}))
' >"${run_dir}/configuration/host-platform.json"

export ROBOTICS_RUN_ID
ROBOTICS_RUN_ID="$(
  "${foundation_bin}/robotics-acceptance" create-run \
    --scenario "${run_dir}/scenario.yaml" \
    --output "${run_dir}/acceptance-run.json" \
    --domain primary=observer \
    --time-authority "${time_authority}" \
    --time-source "${time_source}"
)"
export ROBOTICS_DOMAIN_ID=primary
foundation_validate_document \
  "${foundation_bin}/python" \
  "${run_dir}/acceptance-run.json"

export ROBOTICS_RUN_DIR="${run_dir}"
export ROBOTICS_BAG_DIR="${run_dir}/bags"
# The recorder executes the retained capture configuration, not mutable defaults.
mkdir -p "${run_dir}/configuration/capture"
cp -- "${root}/config/recording/qos-overrides.yaml" \
  "${root}/config/recording/mcap-writer.yaml" "${run_dir}/configuration/capture/"
export ROBOTICS_RECORDING_CONFIG_DIR="${run_dir}/configuration/capture"
export ROBOTICS_EVIDENCE_DIR="${run_dir}/evidence"
export ROBOTICS_HOST_TOPOLOGY_CONFIG=/run/robotics/configuration/host-topology.json
export ROBOTICS_RUNTIME_RESOURCES_CONFIG=/run/robotics/configuration/runtime-resources.json
export ROBOTICS_MAX_BAG_SIZE=1048576
# Compose uses this for both recorder rotation and evidence-sink validation.
# Its 60-second default exceeds the stepped-smoke scenario's 30-second gate.
export ROBOTICS_MAX_BAG_DURATION
ROBOTICS_MAX_BAG_DURATION="$(
  foundation_recording_duration "${foundation_bin}/python" "${run_dir}/scenario.yaml"
)"
export ROBOTICS_MAX_SEGMENT_SIZE_BYTES=2097152
export ROBOTICS_METRICS_EXPORT_INTERVAL_MS=200
topic_configuration="$(
  foundation_scenario_topics "${foundation_bin}/python" "${run_dir}/scenario.yaml"
)"
export ROBOTICS_METRICS_TOPIC ROBOTICS_RECORD_REGEX
ROBOTICS_METRICS_TOPIC="$(jq -er '.metrics_topic' <<<"${topic_configuration}")"
ROBOTICS_RECORD_REGEX="$(jq -er '.record_regex' <<<"${topic_configuration}")"
if [[ "${data_source}" == recording_playback ]]; then
  export ROBOTICS_DATASET_DIR="${run_dir}/source"
  export ROBOTICS_PLAYBACK_BAG=/datasets/bag
  export ROBOTICS_PLAYBACK_CONFIG_DIR="${run_dir}/source/qos"
  export ROBOTICS_PLAYBACK_READINESS_TOPIC="${ROBOTICS_METRICS_TOPIC}"
  export ROBOTICS_TIME_SOURCE_ID="${time_source}"
  export ROBOTICS_PLAYBACK_RATE ROBOTICS_PLAYBACK_CLOCK_HZ ROBOTICS_PLAYBACK_START_OFFSET
  ROBOTICS_PLAYBACK_RATE="$(jq -er '.rate' "${run_dir}/configuration/playback-inputs.json")"
  ROBOTICS_PLAYBACK_CLOCK_HZ="$(jq -er '.clock_hz' "${run_dir}/configuration/playback-inputs.json")"
  ROBOTICS_PLAYBACK_START_OFFSET="$(jq -er '.start_offset_sec' "${run_dir}/configuration/playback-inputs.json")"
fi
export ROBOTICS_SIMULATION_OCI_DIGEST
export ROBOTICS_SIMULATION_OCI_REFERENCE
export ROBOTICS_SIMULATION_LOCAL_IMAGE_ID
simulation_identity="$(
  ci_image_identity "${SIMULATION_IMAGE}" "${ROBOTICS_RUNTIME_MODE:-source}"
)"
ROBOTICS_SIMULATION_OCI_DIGEST="$(jq -er '.digest' <<<"${simulation_identity}")"
ROBOTICS_SIMULATION_OCI_REFERENCE="$(jq -er '.reference' <<<"${simulation_identity}")"
ROBOTICS_SIMULATION_LOCAL_IMAGE_ID="$(jq -er '.local_image_id' <<<"${simulation_identity}")"

profiles=(
  --profile stepped
  --profile record
  --profile acceptance
  --profile evidence
  --profile observability
)
extra_services=()
if [[ -n "${ROBOTICS_FOUNDATION_EXTRA_SERVICES:-}" ]]; then
  while IFS= read -r service; do
    [[ -z "${service}" ]] && continue
    [[ "${service}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || {
      printf 'invalid foundation service name: %s\n' "${service}" >&2
      exit 64
    }
    extra_services+=("${service}")
  done <<<"${ROBOTICS_FOUNDATION_EXTRA_SERVICES}"
fi
foundation_files=(
  compose.yaml
  compose.foundation.yaml
  compose.stepped.yaml
  compose.record.yaml
  compose.evidence.yaml
  compose.observability.yaml
)
if [[ "${data_source}" == recording_playback ]]; then
  foundation_files=(compose.yaml compose.foundation.yaml compose.record.yaml
    compose.evidence.yaml compose.observability.yaml compose.playback.yaml
    compose.foundation-playback.yaml)
  profiles=(--profile playback --profile test --profile record --profile acceptance
    --profile evidence --profile observability)
fi
if [[ "${ROBOTICS_RUNTIME_MODE}" == released ]]; then
  foundation_files+=(compose.released.yaml)
fi
foundation_compose=(docker compose "${compose_environment[@]}" -p "${project}")
foundation_paths=()
for file in "${foundation_files[@]}"; do
  foundation_paths+=("${root}/${file}")
  foundation_compose+=(-f "${root}/${file}")
done
foundation_model="${run_dir}/foundation-compose.json"
consumer_source_model="${run_dir}/consumer-compose-source.json"
consumer_model="${run_dir}/consumer-compose.json"
resolved_model="${run_dir}/resolved-compose.json"
policy_input="${run_dir}/foundation-policy-input.json"
"${foundation_compose[@]}" "${profiles[@]}" config --format json >"${foundation_model}"
jq -n '{services: {}}' >"${consumer_model}"
jq -n '{services: {}}' >"${consumer_source_model}"
compose=("${foundation_compose[@]}")
if [[ -n "${ROBOTICS_FOUNDATION_COMPOSE_PROJECT:-}" ]]; then
  consumer_file="$(realpath -e "${ROBOTICS_FOUNDATION_COMPOSE_PROJECT}")"
  consumer_root="$(realpath -e "${consumer_root}")"
  case "${consumer_file}" in
    "${consumer_root}"/*) ;;
    *)
      printf 'consumer Compose model is outside its repository: %s\n' \
        "${consumer_file}" >&2
      exit 64
      ;;
  esac
  consumer_relative="$(realpath --relative-to="${consumer_root}" "${consumer_file}")"
  ci_yq_from_root "${consumer_root}" \
    -o=json "/input/${consumer_relative}" >"${consumer_source_model}"
  if [[ "${ROBOTICS_RUNTIME_MODE}" == released ]] &&
    ! jq -e 'all(.services[]; has("build") | not)' "${consumer_source_model}" >/dev/null; then
    printf 'released consumer Compose source must not declare builds\n' >&2
    exit 65
  fi
  consumer_source_relative="$(
    realpath --relative-to="${root}" "${consumer_source_model}"
  )"
  ci_require_policy_allows \
    policy/consumer_compose_source.rego \
    consumer_compose_source \
    "${consumer_source_relative}"
  ci_require_source_paths_within_root \
    "${consumer_source_model}" "${consumer_root}"
  env -i \
    PATH="${PATH}" \
    HOME="${HOME}" \
    PWD="${CI_REPO_ROOT}" \
    COMPOSE_DISABLE_ENV_FILE=1 \
    docker compose "${compose_environment[@]}" \
    --project-directory "${consumer_root}" \
    -f "${consumer_file}" \
    config --no-normalize --format json >"${consumer_model}"
  ci_require_model_paths_within_root "${consumer_model}" "${consumer_root}"
  wrapper="${run_dir}/compose.json"
  jq -n \
    --arg root "${root}" \
    --argjson foundation_paths "$(printf '%s\n' "${foundation_paths[@]}" | jq -Rsc 'split("\n")[:-1]')" \
    --arg consumer_file "${consumer_model}" \
    --arg consumer_root "${consumer_root}" \
    '{
      include: [
        {
          path: $foundation_paths,
          project_directory: $root
        },
        {path: $consumer_file, project_directory: $consumer_root}
      ],
      services: {}
    }' >"${wrapper}"
  compose=(docker compose "${compose_environment[@]}" -p "${project}" -f "${wrapper}")
fi
"${compose[@]}" "${profiles[@]}" config --format json >"${resolved_model}"
if ((${#extra_services[@]})); then
  allowed_services="$(printf '%s\n' "${extra_services[@]}" | jq -Rsc 'split("\n")[:-1]')"
else
  allowed_services='[]'
fi
jq -n \
  --slurpfile foundation "${foundation_model}" \
  --slurpfile consumer "${consumer_model}" \
  --slurpfile resolved "${resolved_model}" \
  --arg consumer_root "${consumer_root}" \
  --argjson allowed_services "${allowed_services}" \
  '{
    foundation: $foundation[0],
    consumer: $consumer[0],
    resolved: $resolved[0],
    consumer_root: $consumer_root,
    allowed_services: $allowed_services
  }' >"${policy_input}"
policy_input_relative="$(realpath --relative-to="${root}" "${policy_input}")"
resolved_model_relative="$(realpath --relative-to="${root}" "${resolved_model}")"
ci_require_policy_allows policy/foundation.rego foundation "${policy_input_relative}"
ci_require_policy_allows policy/compose.rego compose "${resolved_model_relative}"
foundation_require_release_images_policy "${resolved_model}" \
  "runs/${project}/release-images-policy-input.json"
cp "${run_dir}/release-images-policy-input.json" "${artifact_dir}/"
if [[ "${ROBOTICS_RUNTIME_MODE}" == released ]]; then
  chmod 0444 "${resolved_model}"
  compose=(docker compose "${compose_environment[@]}" -p "${project}" -f "${resolved_model}")
  FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS+=(
    --artifact "other_evidence:configuration/compose-resolved.json=${resolved_model}"
  )
fi
if [[ "${ROBOTICS_RUNTIME_MODE}" == released && ${#extra_services[@]} -gt 0 ]]; then
  extra_images="$(jq -er --args '
    .services as $services |
    def dependencies($name):
      if $services | has($name) then
        $name, (($services[$name].depends_on // {} | keys[]) | dependencies(.))
      else error("unknown requested consumer service: " + $name) end;
    [$ARGS.positional[] | dependencies(.) | $services[.].image] | unique[]
  ' "${extra_services[@]}" <"${resolved_model}")"
  while IFS= read -r image; do
    foundation_prepare_released_image "${image}"
  done <<<"${extra_images}"
fi
observer=""
attached_compose=()
publish_acceptance_results() {
  mkdir -p "${artifact_dir}/acceptance-results"
  sudo cp -a "${run_dir}/results/." "${artifact_dir}/acceptance-results/"
  sudo chown -R "$(id -u):$(id -g)" "${artifact_dir}/acceptance-results"
}
publish_failure_evidence() {
  local destination="${artifact_dir}/acceptance-evidence"
  local source
  mkdir -p "${destination}"
  for source in \
    "${run_dir}/evidence/metrics.otlp.jsonl" \
    "${run_dir}/evidence/evidence-index.json" \
    "${run_dir}/evidence/summaries" \
    "${run_dir}/scenario.yaml"; do
    if [[ -e "${source}" ]]; then
      sudo cp -a "${source}" "${destination}/"
    fi
  done
  sudo chown -R "$(id -u):$(id -g)" "${destination}"
}
cleanup() {
  local status=$?
  local cleanup_status=0
  local project_status=0
  trap - EXIT
  # A recorded observer failure precedes result publication failures.
  if [[ "${observer_status:-}" =~ ^[1-9][0-9]{0,2}$ ]] &&
    ((observer_status <= 255)); then
    status="${observer_status}"
  fi
  foundation_compose_logs \
    "${artifact_dir}/foundation-e2e.cleanup.log" \
    "${compose[@]}" "${profiles[@]}"
  if ((status != 0)); then
    publish_acceptance_results || true
    publish_failure_evidence || true
  fi
  if [[ -n "${observer}" ]]; then
    docker logs "${observer}" \
      > "${artifact_dir}/foundation-observer.cleanup.log" 2>&1 || true
  fi
  if ((${#attached_compose[@]})); then
    foundation_compose_logs \
      "${artifact_dir}/edge-attach.log" "${attached_compose[@]}"
    foundation_cleanup_project "${project}-attach" \
      "${attached_compose[@]}" || cleanup_status=$?
  fi
  foundation_cleanup_project "${project}" \
    "${compose[@]}" "${profiles[@]}" || project_status=$?
  if ((status != 0)); then
    exit "${status}"
  fi
  if ((cleanup_status != 0)); then
    exit "${cleanup_status}"
  fi
  exit "${project_status}"
}
trap cleanup EXIT

collect_playback_provider() {
  local gate probe path version
  mkdir -p "${artifact_dir}/provider"
  cp -- "${run_dir}/resolved-compose.json" "${artifact_dir}/provider/compose.json"
  cp -- "${run_dir}/foundation-compose.json" "${artifact_dir}/provider/compose-original.json"
  printf '%s\n' "${simulation_identity}" | tee "${artifact_dir}/provider/playback-image.json" \
    >"${artifact_dir}/provider/probe-image.json"
  docker run --rm --pull never "${ROBOTICS_SIMULATION_LOCAL_IMAGE_ID}" \
    ros2 pkg xml rosbag2_transport --tag version \
    >"${artifact_dir}/provider/rosbag2-version.txt"
  version="$(cat "${artifact_dir}/provider/rosbag2-version.txt")"
  for path in compose.json compose-original.json playback-image.json probe-image.json; do
    sudo install -o 1000 -g 1000 -m 0644 "${artifact_dir}/provider/${path}" "${run_dir}/${path}"
  done
  sudo install -o 1000 -g 1000 -m 0644 "${artifact_dir}/provider/rosbag2-version.txt" \
    "${run_dir}/configuration/rosbag2-version.txt"
  while IFS= read -r -d '' path; do
    jq -cn --arg path "${path#"$run_dir/"}" \
      --arg sha256 "$(sha256sum "${path}" | cut -d' ' -f1)" \
      --argjson size "$(stat -c '%s' "${path}")" \
      '{path: $path, sha256: $sha256, size_bytes: $size}'
  done < <(find "${run_dir}/source" -type f -print0 | sort -z) \
    >"${artifact_dir}/provider/sources.jsonl"
  jq -n --arg version "${version}" --arg image "${ROBOTICS_SIMULATION_LOCAL_IMAGE_ID}" \
    --arg topic "${ROBOTICS_METRICS_TOPIC}" --slurpfile model "${run_dir}/compose.json" \
    --slurpfile sources "${artifact_dir}/provider/sources.jsonl" \
    '{version: $version, topic: $topic, message_type: "std_msgs/msg/UInt64",
      expected_playback_image_id: $image, expected_probe_image_id: $image,
      playback_command: $model[0].services.playback.command,
      gate_command: $model[0].services["playback-gate"].command,
      probe_command: $model[0].services["playback-probe"].command, sources: $sources}' \
    >"${artifact_dir}/provider/configuration.json"
  sudo install -o 1000 -g 1000 -m 0644 "${artifact_dir}/provider/configuration.json" \
    "${run_dir}/configuration/provider.json"
  "${compose[@]}" --profile observability up --detach --no-build runtime-metrics
  "${compose[@]}" --profile playback --profile test up --detach --no-build \
    playback-probe playback-gate
  "${compose[@]}" --profile playback --profile test wait playback-gate playback-probe
  gate="$("${compose[@]}" ps --all --quiet playback-gate)"
  probe="$("${compose[@]}" ps --all --quiet playback-probe)"
  local gate_logs=0 probe_logs=0
  docker logs "${gate}" >"${artifact_dir}/provider/gate.log" 2>&1 || gate_logs=$?
  docker logs "${probe}" >"${artifact_dir}/provider/probe.log" 2>&1 || probe_logs=$?
  jq -n --argjson gate "$(docker inspect --format '{{.State.ExitCode}}' "${gate}")" \
    --argjson probe "$(docker inspect --format '{{.State.ExitCode}}' "${probe}")" \
    --argjson gate_logs "${gate_logs}" --argjson probe_logs "${probe_logs}" \
    --arg playback_image "$(docker inspect --format '{{.Image}}' "${simulation_container}")" \
    --arg gate_image "$(docker inspect --format '{{.Image}}' "${gate}")" \
    --arg probe_image "$(docker inspect --format '{{.Image}}' "${probe}")" \
    --arg log_sha256 "$(sha256sum "${artifact_dir}/provider/probe.log" | cut -d' ' -f1)" \
    '{gate_exit_code: $gate, probe_exit_code: $probe, gate_logs_exit_code: $gate_logs,
      probe_logs_exit_code: $probe_logs, playback_image_id: $playback_image,
      gate_image_id: $gate_image, probe_image_id: $probe_image, probe_log_sha256: $log_sha256}' \
    >"${artifact_dir}/provider/observation.json"
  sudo install -o 1000 -g 1000 -m 0644 "${artifact_dir}/provider/observation.json" \
    "${run_dir}/observation.json"
  sudo install -o 1000 -g 1000 -m 0644 "${artifact_dir}/provider/gate.log" "${run_dir}/logs/playback-gate.log"
  sudo install -o 1000 -g 1000 -m 0644 "${artifact_dir}/provider/probe.log" "${run_dir}/logs/playback-probe.log"
  "${compose[@]}" --profile acceptance run --rm --no-deps --pull never \
    --volume "${root}/scripts/ci/integration/create-playback-provider.py:/tmp/create-playback-provider.py:ro" \
    runtime-manifest /opt/contracts/bin/python /tmp/create-playback-provider.py \
    --run-dir /run/robotics --host-run-dir "${run_dir}" --run-id "${ROBOTICS_RUN_ID}" \
    --subject-digest "${ROBOTICS_SIMULATION_OCI_DIGEST}" --output /run/robotics/conformance-result.json \
    >"${artifact_dir}/provider/bindings.json"
  cp -- "${run_dir}/profile.json" "${artifact_dir}/provider/profile.json"
  cp -- "${run_dir}/conformance-result.json" "${artifact_dir}/provider/conformance.json"
}

sudo chown -R 1000:1000 "${run_dir}"
sudo chown -R 10001:10001 "${run_dir}/evidence"
if [[ "${data_source}" == recording_playback ]]; then
  "${compose[@]}" --profile playback --profile record --profile observability \
    up --detach --no-build --wait --wait-timeout 120 playback recorder otel-collector \
    "${extra_services[@]}"
else
  "${compose[@]}" --profile stepped --profile record --profile observability \
    up --detach --no-build --wait --wait-timeout 120 simulation recorder otel-collector \
    "${extra_services[@]}"
fi
collector_health_address="$("${compose[@]}" port otel-collector 13133)"
curl --fail --silent --show-error \
  --retry 10 --retry-connrefused --retry-delay 1 \
  "http://${collector_health_address}/"
if [[ "${data_source}" == recording_playback ]]; then
  simulation_container="$("${compose[@]}" ps -q playback)"
  test -n "${simulation_container}"
  collect_playback_provider
else
  simulation_container="$("${compose[@]}" ps -q simulation)"
  test -n "${simulation_container}"
  bash "${script_dir}/collect-simulation-provider.sh" \
    "${simulation_container}" "${run_dir}" "${artifact_dir}/provider" \
    "${ROBOTICS_SIMULATION_OCI_DIGEST}"
fi
sudo install -o 1000 -g 1000 -m 0644 \
  "${artifact_dir}/provider/bindings.json" "${run_dir}/provider-bindings.json"
# The conformance probe controls pause/step/resume itself. Start the periodic
# stepper only after the probe has finished, before the observation window.
if [[ "${data_source}" == simulator ]]; then
  "${compose[@]}" --profile stepped \
    up --detach --no-build --wait --wait-timeout 120 simulation-stepper
fi
runtime_resources="${artifact_dir}/runtime-resources.json"
docker inspect "${simulation_container}" | jq '.[0].HostConfig | {
  NanoCpus,
  CpuPeriod,
  CpuQuota,
  CpusetCpus,
  Memory,
  MemorySwap,
  ShmSize
}' >"${runtime_resources}"
sudo install -o 1000 -g 1000 -m 0644 \
  "${runtime_resources}" \
  "${run_dir}/configuration/runtime-resources.json"
rm "${runtime_resources}"
"${compose[@]}" --profile acceptance run --rm runtime-manifest
foundation_validate_document \
  "${foundation_bin}/python" \
  "${run_dir}/runtime-manifest.json"
fastdds_profile="${root}/config/fastdds/udp-only.xml"
fastdds_profile_sha256="$(sha256sum "${fastdds_profile}" | cut -d' ' -f1)"
jq -e --arg digest "${fastdds_profile_sha256}" \
  '.schema_version == "runtime-manifest.v1" and
   .data_plane.middleware_configuration_sha256 == $digest and
   ([.configuration_artifacts[].kind] | sort) ==
     ["host_topology", "runtime_resources"]' \
  "${run_dir}/runtime-manifest.json" >/dev/null
if [[ "${data_source}" == simulator ]]; then
  "${compose[@]}" --profile acceptance --profile observability \
    up --detach --no-build --wait --wait-timeout 120 runtime-probe-publisher runtime-metrics
fi

observer_compose=("${compose[@]}" --profile acceptance)
observer_service=acceptance-observer
measurement_complete="${run_dir}/measurement-complete"
if [[ "${observer_mode}" == edge-attach ]]; then
  export ROBOTICS_RUN_INPUT_DIR="${run_dir}"
  export ROBOTICS_RESULTS_DIR="${run_dir}/results"
  export ROBOTICS_ATTACH_NETWORK
  ROBOTICS_ATTACH_NETWORK="$(docker inspect "${simulation_container}" | jq -er '
    .[0].NetworkSettings.Networks | keys |
    if length == 1 then .[0] else error("expected one simulation network") end
  ')"
  attached_compose=(docker compose "${compose_environment[@]}" -p "${project}-attach"
    -f "${root}/compose.yaml" -f "${root}/compose.edge-attach.yaml")
  if [[ "${ROBOTICS_RUNTIME_MODE}" == released ]]; then
    attached_compose+=(-f "${root}/compose.released.yaml")
  fi
  attached_compose+=(--profile edge-attach)
  attached_model="${artifact_dir}/edge-attach-compose.json"
  "${attached_compose[@]}" config --format json >"${attached_model}"
  ci_require_policy_allows policy/compose.rego compose \
    "$(realpath --relative-to="${root}" "${attached_model}")"
  foundation_require_release_images_policy "${attached_model}" \
    "$(realpath --relative-to="${root}" "${artifact_dir}")/edge-attach-release-policy-input.json"
  if [[ "${ROBOTICS_RUNTIME_MODE}" == released ]]; then
    chmod 0444 "${attached_model}"
    attached_compose=(docker compose "${compose_environment[@]}" -p "${project}-attach"
      -f "${attached_model}" --profile edge-attach)
    FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS+=(
      --artifact "other_evidence:configuration/edge-attach-compose.json=${attached_model}"
    )
    foundation_prepare_released_image "$(jq -er '.services["edge-attach-data-plane"].image' "${attached_model}")"
  fi
  "${attached_compose[@]}" up --detach --no-build edge-attach-data-plane
  observer_compose=("${attached_compose[@]}")
  observer_service=edge-attach-observer
  measurement_complete="${run_dir}/results/measurement-complete"
fi
# Use the service's actual default verify command in both modes. Its marker
# closes the same live measurement window before recording/evidence finalization.
observer="$(
  "${observer_compose[@]}" run --detach \
    --name "${project}-observer" --no-deps "${observer_service}"
)"
while [[ ! -f "${measurement_complete}" ]]; do
  if [[ "${data_source}" == recording_playback &&
    "$(docker inspect --format '{{.State.Running}}' "${simulation_container}")" != true ]]; then
    printf 'recorded playback ended before the live measurement completed\n' >&2
    exit 70
  fi
  if [[ "$(docker inspect --format '{{.State.Running}}' "${observer}")" != true ]]; then
    observer_status="$(docker wait "${observer}")"
    printf 'acceptance observer exited before completing measurement: %s\n' \
      "${observer_status}" >&2
    exit 70
  fi
  sleep 1
done
if [[ "${data_source}" == recording_playback ]]; then
  [[ "$(docker inspect --format '{{.State.Running}}' "${simulation_container}")" == true ]] || {
    printf 'recorded playback ended before the live completion proof\n' >&2; exit 70;
  }
  "${compose[@]}" --profile observability stop runtime-metrics
  "${compose[@]}" --profile playback stop playback
else
  "${compose[@]}" --profile acceptance --profile observability stop runtime-metrics runtime-probe-publisher
fi
sleep 2
"${compose[@]}" --profile observability stop otel-collector
test -s "${run_dir}/evidence/metrics.otlp.jsonl"
"${compose[@]}" --profile evidence run --rm --no-deps \
  evidence-sink artifact \
  /evidence/metrics.otlp.jsonl application/x-ndjson \
  "${evidence_metrics_segment_index}"
"${compose[@]}" --profile record stop recorder
"${compose[@]}" --profile evidence run --rm evidence-finalize
observer_status="$(docker wait "${observer}")"
publish_acceptance_results
published_result="${artifact_dir}/acceptance-results/acceptance-result.json"
if [[ -f "${published_result}" ]]; then
  jq . "${published_result}"
fi
if ! [[ "${observer_status}" =~ ^[0-9]+$ ]]; then
  printf 'invalid acceptance observer status: %s\n' "${observer_status}" >&2
  exit 2
fi
if ((observer_status != 0)); then
  printf 'acceptance observer exited with status %s\n' "${observer_status}" >&2
  exit "${observer_status}"
fi
"${compose[@]}" --profile acceptance run --rm --no-deps \
  acceptance-observer robotics-acceptance aggregate \
  --scenario /run/robotics/scenario.yaml \
  --run-context /run/robotics/acceptance-run.json \
  --result /run/robotics/results/acceptance-result.json \
  --output /run/robotics/results/acceptance-aggregate.json
sudo chown -R "$(id -u):$(id -g)" "${run_dir}"

mapfile -t mcap_summaries < <(
  find "${run_dir}/evidence/summaries" \
    -maxdepth 1 -type f -name '*.recording-summary.json' -print |
    LC_ALL=C sort
)
mapfile -t mcap_files < <(
  find "${run_dir}/bags" -type f -name '*.mcap' -print |
    LC_ALL=C sort
)
test "${#mcap_summaries[@]}" -ge 1
test "${#mcap_files[@]}" -eq "${#mcap_summaries[@]}"
export ROBOTICS_CONTRACTS_CLI="${foundation_bin}/robotics-contracts"
[[ "$(sha256sum "${fastdds_profile}" | cut -d' ' -f1)" == \
  "${fastdds_profile_sha256}" ]] || {
  printf 'Fast DDS profile changed during the foundation run\n' >&2
  exit 65
}
log_dir="${run_dir}/results/logs"
mkdir -p "${log_dir}"
"${compose[@]}" "${profiles[@]}" logs --no-color >"${log_dir}/foundation.log" 2>&1
docker logs "${observer}" >"${log_dir}/observer.log" 2>&1
chmod 0444 "${log_dir}/foundation.log" "${log_dir}/observer.log"
qualification_inputs=(
  --scenario "${run_dir}/scenario.yaml"
  --runtime-manifest "primary=${run_dir}/runtime-manifest.json"
  --acceptance-run "${run_dir}/acceptance-run.json"
  --result "primary=${run_dir}/results/acceptance-result.json"
  --aggregate "${run_dir}/results/acceptance-aggregate.json"
  --evidence-index "primary=${run_dir}/evidence/evidence-index.json"
  --evidence "metrics:metrics.otlp.jsonl=${run_dir}/evidence/metrics.otlp.jsonl"
  --evidence "junit:junit.xml=${run_dir}/results/junit.xml"
  --evidence "other_evidence:fastdds-profile.xml=${fastdds_profile}"
  --evidence "other_evidence:host-topology.json=${run_dir}/configuration/host-topology.json"
  --evidence "other_evidence:runtime-resources.json=${run_dir}/configuration/runtime-resources.json"
  --artifact "other_evidence:capture/qos-overrides.yaml=${run_dir}/configuration/capture/qos-overrides.yaml"
  --artifact "other_evidence:capture/mcap-writer.yaml=${run_dir}/configuration/capture/mcap-writer.yaml"
  --artifact "qualification_profile:providers/profile.json=${artifact_dir}/provider/profile.json"
  --artifact "provider_conformance:providers/conformance.json=${artifact_dir}/provider/conformance.json"
  --artifact "other_evidence:providers/configuration.json=${artifact_dir}/provider/configuration.json"
  --artifact "other_evidence:providers/observation.json=${artifact_dir}/provider/observation.json"
  --artifact "other_evidence:logs/foundation.log=${log_dir}/foundation.log"
  --artifact "other_evidence:logs/observer.log=${log_dir}/observer.log"
)
while IFS= read -r -d '' path; do
  relative="${path#"$run_dir/bags/"}"
  qualification_inputs+=(--artifact "other_evidence:capture/bags/${relative}=${path}")
done < <(find "${run_dir}/bags" -type f -name metadata.yaml -print0 | sort -z)
append_playback_raw() {
  local kind="$1" subject="$2" path="$3" digest value existing_kind existing_path index
  digest="$(sha256sum "${path}" | cut -d' ' -f1)"
  # Native referenced raw links require one retained SHA/size match. Reuse
  # already retained bytes, while preserving every distinct source input.
  for ((index=0; index<${#qualification_inputs[@]}-1; index++)); do
    case "${qualification_inputs[index]}" in --artifact|--evidence) ;; *) continue ;; esac
    value="${qualification_inputs[index+1]}"
    existing_kind="${value%%:*}"
    case "${existing_kind}" in recording|metrics|junit|other_evidence) ;; *) continue ;; esac
    [[ "${kind}" != recording || "${existing_kind}" == recording ]] || continue
    existing_path="${value#*=}"
    if [[ "$(sha256sum "${existing_path}" | cut -d' ' -f1)" == "${digest}" &&
      "$(stat -c '%s' "${existing_path}")" == "$(stat -c '%s' "${path}")" ]]; then
      return 0
    fi
  done
  qualification_inputs+=(--artifact "${kind}:${subject}=${path}")
}
if [[ "${data_source}" == simulator ]]; then
  qualification_inputs+=(--artifact "other_evidence:providers/world.sdf=${artifact_dir}/provider/world.sdf")
else
  input_digest="$(jq -er '.artifact.sha256' "${run_dir}/dataset-manifest.json")"
  for path in "${mcap_files[@]}"; do
    [[ "$(sha256sum "${path}" | cut -d' ' -f1)" != "${input_digest}" ]] || {
      printf 'new playback observation cannot reuse its source recording bytes\n' >&2; exit 65;
    }
  done
  qualification_inputs+=(--artifact "dataset_manifest:dataset-manifest.json=${run_dir}/dataset-manifest.json")
  while IFS= read -r -d '' path; do
    relative="${path#"$run_dir/"}"
    kind=other_evidence
    [[ "${path}" == *.mcap ]] && kind=recording
    append_playback_raw "${kind}" "${relative}" "${path}"
  done < <(find "${run_dir}/source" -type f -print0 | sort -z)
  for relative in profile.json conformance-result.json observation.json \
    configuration/provider.json configuration/rosbag2-version.txt configuration/playback-inputs.json \
    logs/playback-gate.log logs/playback-probe.log playback-image.json probe-image.json compose-original.json compose.json; do
    case "${relative}" in
      profile.json|conformance-result.json|configuration/provider.json|observation.json) continue ;;
    esac
    append_playback_raw other_evidence "playback/${relative}" "${run_dir}/${relative}"
  done
fi
for index in "${!mcap_summaries[@]}"; do
  qualification_inputs+=(
    --recording-summary "primary-${index}=${mcap_summaries[$index]}"
    --evidence "recording:primary-${index}.mcap=${mcap_files[$index]}"
  )
done
qualification_inputs+=("${FOUNDATION_ARTIFACT_ARGUMENTS[@]}" "${FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS[@]}")
qualification_package="$(realpath -e "${artifact_dir}")/qualification"
(
  # Reusable callers have sibling tooling, consumer and artifacts checkouts.
  cd "${GITHUB_WORKSPACE:-${root}}"
  "${root}/scripts/qualification/package-artifacts" \
    --output "${qualification_package}" "${qualification_inputs[@]}"
)
scripts/qualification/create-statement \
  "${qualification_inputs[@]}" \
  --output "${run_dir}/results/qualification-statement.json"
bash scripts/ci/foundation/sign-ephemeral-qualification.sh \
  "${run_dir}/results/qualification-statement.json" \
  "${run_dir}/results/qualification.sigstore.json" \
  "${run_dir}/results/qualification.pub"
cp -- "${run_dir}/results/qualification-statement.json" \
  "${run_dir}/results/qualification.sigstore.json" \
  "${run_dir}/results/qualification.pub" "${qualification_package}/"
(
  cd "${qualification_package}"
  mapfile -t portable_inputs <qualification-arguments.txt
  "${root}/scripts/qualification/verify-bundle" \
    "${portable_inputs[@]}" \
    --bundle qualification.sigstore.json --key qualification.pub
)

if [[ "${data_source}" == recording_playback ]]; then
  foundation_explain_qualification "${qualification_package}" \
    "${artifact_dir}/playback-explain.json" recording_playback \
    "${foundation_bin}/robotics-acceptance"
fi

jq -e '.status == "passed" and .evaluation_mode == "live"' \
  "${run_dir}/results/acceptance-result.json"
jq -e \
  '.per_domain_aggregate == "passed" and
   .cross_domain_e2e.status == "unevaluated"' \
  "${run_dir}/results/acceptance-aggregate.json"
jq -e '
  [.artifacts[].media_type]
  | contains(["application/x-ndjson"])
' "${run_dir}/evidence/evidence-index.json"
contracts_revision="$(
  git -C dependencies/robotics-runtime rev-parse HEAD
)"
harness_revision="$(
  git -C dependencies/robotics-runtime rev-parse HEAD
)"
jq -e \
  --arg contracts_revision "${contracts_revision}" \
  --arg harness_revision "${harness_revision}" \
  '.components.contracts_revision == $contracts_revision and
   .components.harness_revision == $harness_revision' \
  "${run_dir}/runtime-manifest.json"
test -s "${run_dir}/results/junit.xml"

publish_acceptance_results
cp "${run_dir}/runtime-manifest.json" "${artifact_dir}/"
cp "${run_dir}/acceptance-run.json" "${artifact_dir}/"
cp "${run_dir}/scenario.yaml" "${artifact_dir}/"
cp "${run_dir}/evidence/evidence-index.json" "${artifact_dir}/"
cp "${run_dir}/evidence/metrics.otlp.jsonl" "${artifact_dir}/"
cp "${fastdds_profile}" "${artifact_dir}/fastdds-profile.xml"
cp "${run_dir}/configuration/host-topology.json" "${artifact_dir}/"
cp "${run_dir}/configuration/host-platform.json" "${artifact_dir}/"
cp "${run_dir}/configuration/runtime-resources.json" "${artifact_dir}/"
cp "${run_dir}/results/qualification-statement.json" "${artifact_dir}/"
cp "${run_dir}/results/qualification.sigstore.json" "${artifact_dir}/"
cp "${run_dir}/results/qualification.pub" "${artifact_dir}/"
cp "${mcap_summaries[@]}" "${artifact_dir}/"
mkdir -p "${artifact_dir}/raw-mcap"
cp "${mcap_files[@]}" "${artifact_dir}/raw-mcap/"
