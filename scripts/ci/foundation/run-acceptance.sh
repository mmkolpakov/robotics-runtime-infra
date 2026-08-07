#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

readonly evidence_metrics_segment_index=900000

root="$(foundation_repository_root)"
cd "${root}"
# shellcheck source=scripts/ci/lib.sh
source "${root}/scripts/ci/lib.sh"

foundation_require_env EVIDENCE_IMAGE SIMULATION_IMAGE
command -v cosign >/dev/null 2>&1 || {
  printf 'cosign is required for foundation qualification\n' >&2
  exit 69
}

run_id="$(foundation_run_id)"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
project="$(foundation_project_name acceptance "${run_id}" "${run_attempt}")"
artifact_dir="$(foundation_artifact_dir "${root}" "${project}")"
run_dir="${root}/runs/${project}"
scenario_source="${ROBOTICS_FOUNDATION_SCENARIO:-test/acceptance/stepped-smoke.yaml}"
[[ -f "${scenario_source}" ]] || {
  printf 'foundation scenario does not exist: %s\n' "${scenario_source}" >&2
  exit 66
}
rm -rf "${run_dir}"
mkdir -p \
  "${run_dir}/bags" \
  "${run_dir}/configuration" \
  "${run_dir}/evidence" \
  "${run_dir}/results" \
  "${artifact_dir}"
cp "${scenario_source}" "${run_dir}/scenario.yaml"
lscpu --json >"${run_dir}/configuration/host-topology.json"

export ROBOTICS_RUN_ID
ROBOTICS_RUN_ID="$(
  dependencies/robotics-acceptance-harness/.venv/bin/robotics-acceptance create-run \
    --scenario "${run_dir}/scenario.yaml" \
    --output "${run_dir}/acceptance-run.json" \
    --domain primary=observer \
    --time-authority sim_clock \
    --time-source gazebo-clock
)"
export ROBOTICS_DOMAIN_ID=primary
foundation_validate_document \
  dependencies/robotics-runtime-contracts/.venv/bin/python \
  "${run_dir}/acceptance-run.json"

export ROBOTICS_RUN_DIR="${run_dir}"
export ROBOTICS_BAG_DIR="${run_dir}/bags"
export ROBOTICS_EVIDENCE_DIR="${run_dir}/evidence"
export ROBOTICS_MAX_BAG_SIZE=1048576
export ROBOTICS_MAX_SEGMENT_SIZE_BYTES=2097152
export ROBOTICS_METRICS_EXPORT_INTERVAL_MS=200
export ROBOTICS_RECORD_REGEX='^(/clock|/robotics/runtime_probe)$'
export ROBOTICS_SIMULATION_OCI_DIGEST
export ROBOTICS_SIMULATION_OCI_REFERENCE
ROBOTICS_SIMULATION_OCI_DIGEST="$(
  docker image inspect "${SIMULATION_IMAGE}" --format '{{.Id}}'
)"
ROBOTICS_SIMULATION_OCI_REFERENCE="${SIMULATION_IMAGE}@${ROBOTICS_SIMULATION_OCI_DIGEST}"

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
foundation_compose=(docker compose -p "${project}")
for file in "${foundation_files[@]}"; do
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
consumer_root="${ROBOTICS_FOUNDATION_CONSUMER_ROOT:-${root}}"
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
    docker compose \
    --project-directory "${consumer_root}" \
    -f "${consumer_file}" \
    config --no-normalize --format json >"${consumer_model}"
  ci_require_model_paths_within_root "${consumer_model}" "${consumer_root}"
  wrapper="${run_dir}/compose.json"
  jq -n \
    --arg root "${root}" \
    --arg consumer_file "${consumer_model}" \
    --arg consumer_root "${consumer_root}" \
    '{
      include: [
        {
          path: [
            ($root + "/compose.yaml"),
            ($root + "/compose.foundation.yaml"),
            ($root + "/compose.stepped.yaml"),
            ($root + "/compose.record.yaml"),
            ($root + "/compose.evidence.yaml"),
            ($root + "/compose.observability.yaml")
          ],
          project_directory: $root
        },
        {path: $consumer_file, project_directory: $consumer_root}
      ],
      services: {}
    }' >"${wrapper}"
  compose=(docker compose -p "${project}" -f "${wrapper}")
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
observer=""
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
    "${run_dir}/evidence/metrics.otlp.json" \
    "${run_dir}/evidence/evidence-index.json"; do
    if [[ -f "${source}" ]]; then
      sudo cp "${source}" "${destination}/"
    fi
  done
  sudo chown -R "$(id -u):$(id -g)" "${destination}"
}
cleanup() {
  local status=$?
  foundation_compose_logs \
    "${artifact_dir}/foundation-e2e.log" \
    "${compose[@]}" "${profiles[@]}"
  if ((status != 0)); then
    publish_acceptance_results || true
    publish_failure_evidence || true
  fi
  if [[ -n "${observer}" ]]; then
    docker logs "${observer}" \
      > "${artifact_dir}/foundation-observer.log" 2>&1 || true
  fi
  foundation_compose_down "${compose[@]}" "${profiles[@]}"
  return "${status}"
}
trap cleanup EXIT

sudo chown -R 1000:1000 "${run_dir}"
sudo chown -R 10001:10001 "${run_dir}/evidence"
"${compose[@]}" --profile stepped --profile record --profile observability \
  up --detach --no-build --wait --wait-timeout 120 \
  simulation simulation-stepper recorder otel-collector \
  "${extra_services[@]}"
collector_health_address="$("${compose[@]}" port otel-collector 13133)"
curl --fail --silent --show-error \
  --retry 10 --retry-connrefused --retry-delay 1 \
  "http://${collector_health_address}/"
simulation_container="$("${compose[@]}" ps -q simulation)"
test -n "${simulation_container}"
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
export ROBOTICS_HOST_TOPOLOGY_CONFIG=/run/robotics/configuration/host-topology.json
export ROBOTICS_RUNTIME_RESOURCES_CONFIG=/run/robotics/configuration/runtime-resources.json
"${compose[@]}" --profile acceptance run --rm runtime-manifest
foundation_validate_document \
  dependencies/robotics-runtime-contracts/.venv/bin/python \
  "${run_dir}/runtime-manifest.json"
fastdds_profile="${root}/config/fastdds/udp-only.xml"
fastdds_profile_sha256="$(sha256sum "${fastdds_profile}" | cut -d' ' -f1)"
jq -e --arg digest "${fastdds_profile_sha256}" \
  '.schema_version == "runtime-manifest.v2" and
   .data_plane.fastdds_profile_sha256 == $digest and
   ([.configuration_artifacts[].kind] | sort) ==
     ["host_topology", "runtime_resources"]' \
  "${run_dir}/runtime-manifest.json" >/dev/null
"${compose[@]}" --profile acceptance --profile observability \
  up --detach --no-build --wait --wait-timeout 120 \
  runtime-probe-publisher runtime-metrics

observer="$(
  "${compose[@]}" --profile acceptance run --detach \
    --name "${project}-observer" --no-deps acceptance-observer
)"
measurement_complete="${run_dir}/measurement-complete"
while [[ ! -f "${measurement_complete}" ]]; do
  if [[ "$(docker inspect --format '{{.State.Running}}' "${observer}")" != true ]]; then
    observer_status="$(docker wait "${observer}")"
    printf 'acceptance observer exited before completing measurement: %s\n' \
      "${observer_status}" >&2
    exit 70
  fi
  sleep 1
done
"${compose[@]}" --profile acceptance --profile observability stop \
  runtime-metrics runtime-probe-publisher
sleep 2
"${compose[@]}" --profile observability stop otel-collector
test -s "${run_dir}/evidence/metrics.otlp.json"
"${compose[@]}" --profile evidence run --rm --no-deps \
  evidence-sink artifact \
  /evidence/metrics.otlp.json application/json \
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
    -maxdepth 1 -type f -name '*.mcap-summary.json' -print |
    LC_ALL=C sort
)
mapfile -t mcap_files < <(
  find "${run_dir}/bags" -type f -name '*.mcap' -print |
    LC_ALL=C sort
)
test "${#mcap_summaries[@]}" -ge 1
test "${#mcap_files[@]}" -eq "${#mcap_summaries[@]}"
export ROBOTICS_CONTRACTS_CLI="${root}/dependencies/robotics-runtime-contracts/.venv/bin/robotics-contracts"
[[ "$(sha256sum "${fastdds_profile}" | cut -d' ' -f1)" == \
  "${fastdds_profile_sha256}" ]] || {
  printf 'Fast DDS profile changed during the foundation run\n' >&2
  exit 65
}
qualification_inputs=(
  --scenario "${run_dir}/scenario.yaml"
  --runtime-manifest "primary=${run_dir}/runtime-manifest.json"
  --acceptance-run "${run_dir}/acceptance-run.json"
  --result "primary=${run_dir}/results/acceptance-result.json"
  --aggregate "${run_dir}/results/acceptance-aggregate.json"
  --evidence-index "primary=${run_dir}/evidence/evidence-index.json"
  --evidence "metrics:metrics.otlp.json=${run_dir}/evidence/metrics.otlp.json"
  --evidence "junit:junit.xml=${run_dir}/results/junit.xml"
  --evidence "other_evidence:fastdds-profile.xml=${fastdds_profile}"
  --evidence "other_evidence:host-topology.json=${run_dir}/configuration/host-topology.json"
  --evidence "other_evidence:runtime-resources.json=${run_dir}/configuration/runtime-resources.json"
)
for index in "${!mcap_summaries[@]}"; do
  qualification_inputs+=(
    --mcap-summary "primary-${index}=${mcap_summaries[$index]}"
    --evidence "raw_mcap:primary-${index}.mcap=${mcap_files[$index]}"
  )
done
scripts/qualification/create-statement \
  "${qualification_inputs[@]}" \
  --output "${run_dir}/results/qualification-statement.json"
bash scripts/ci/foundation/sign-ephemeral-qualification.sh \
  "${run_dir}/results/qualification-statement.json" \
  "${run_dir}/results/qualification.sigstore.json" \
  "${run_dir}/results/qualification.pub"
scripts/qualification/verify-bundle \
  --bundle "${run_dir}/results/qualification.sigstore.json" \
  --key "${run_dir}/results/qualification.pub" \
  "${qualification_inputs[@]}"

jq -e '.status == "passed"' \
  "${run_dir}/results/acceptance-result.json"
jq -e \
  '.per_domain_aggregate == "passed" and
   .cross_domain_e2e.status == "unevaluated"' \
  "${run_dir}/results/acceptance-aggregate.json"
jq -e '
  [.segments[].media_type]
  | contains(["application/json"])
' "${run_dir}/evidence/evidence-index.json"
contracts_revision="$(
  git -C dependencies/robotics-runtime-contracts rev-parse HEAD
)"
harness_revision="$(
  git -C dependencies/robotics-acceptance-harness rev-parse HEAD
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
cp "${run_dir}/evidence/metrics.otlp.json" "${artifact_dir}/"
cp "${fastdds_profile}" "${artifact_dir}/fastdds-profile.xml"
cp "${run_dir}/configuration/host-topology.json" "${artifact_dir}/"
cp "${run_dir}/configuration/runtime-resources.json" "${artifact_dir}/"
cp "${run_dir}/results/qualification-statement.json" "${artifact_dir}/"
cp "${run_dir}/results/qualification.sigstore.json" "${artifact_dir}/"
cp "${run_dir}/results/qualification.pub" "${artifact_dir}/"
cp "${mcap_summaries[@]}" "${artifact_dir}/"
mkdir -p "${artifact_dir}/raw-mcap"
cp "${mcap_files[@]}" "${artifact_dir}/raw-mcap/"
