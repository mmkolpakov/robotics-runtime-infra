#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"

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
rm -rf "${run_dir}"
mkdir -p \
  "${run_dir}/bags" \
  "${run_dir}/evidence" \
  "${run_dir}/results" \
  "${artifact_dir}"
cp test/acceptance/stepped-smoke.yaml "${run_dir}/scenario.yaml"

export ROBOTICS_RUN_ID
ROBOTICS_RUN_ID="$(
  scripts/create-acceptance-run \
    --scenario "${run_dir}/scenario.yaml" \
    --scenario-id org.example.runtime-infra.stepped-smoke \
    --output "${run_dir}/acceptance-run.json" \
    --domain primary=observer \
    --time-authority sim_clock \
    --time-source gazebo-clock
)"
export ROBOTICS_DOMAIN_ID=primary
foundation_validate_document \
  dependencies/robotics-runtime-contracts/.venv/bin/python \
  "${run_dir}/acceptance-run.json"
sudo chown -R 1000:1000 "${run_dir}"
sudo chown -R 10001:10001 "${run_dir}/evidence"

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

compose=(
  docker compose -p "${project}"
  -f compose.yaml
  -f compose.foundation.yaml
  -f compose.stepped.yaml
  -f compose.record.yaml
  -f compose.evidence.yaml
  -f compose.observability.yaml
)
profiles=(
  --profile stepped
  --profile record
  --profile acceptance
  --profile evidence
  --profile observability
)
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

"${compose[@]}" --profile stepped --profile record --profile observability \
  up --detach --no-build --wait --wait-timeout 120 \
  simulation simulation-stepper recorder otel-collector
collector_health_address="$("${compose[@]}" port otel-collector 13133)"
curl --fail --silent --show-error \
  --retry 10 --retry-connrefused --retry-delay 1 \
  "http://${collector_health_address}/"
"${compose[@]}" --profile acceptance run --rm runtime-manifest
fastdds_profile="${root}/config/fastdds/udp-only.xml"
fastdds_profile_sha256="$(sha256sum "${fastdds_profile}" | cut -d' ' -f1)"
jq -e --arg digest "${fastdds_profile_sha256}" \
  '.data_plane.fastdds_profile_sha256 == $digest' \
  "${run_dir}/runtime-manifest.json" >/dev/null
"${compose[@]}" --profile acceptance --profile observability \
  up --detach --no-build --wait --wait-timeout 30 \
  runtime-probe-publisher runtime-metrics

observer="$(
  "${compose[@]}" --profile acceptance run --detach \
    --name "${project}-observer" --no-deps acceptance-observer
)"
sleep 2
telemetry_duration="$(
  docker run --rm \
    --entrypoint /usr/local/bin/yq \
    --volume "${run_dir}/scenario.yaml:/scenario.yaml:ro" \
    "${EVIDENCE_IMAGE}" \
    -r \
    '.timeouts.graph_ready_sec +
     .timeouts.stable_for_sec +
     .timeouts.execution_sec + 3' \
    /scenario.yaml
)"
if ! [[ "${telemetry_duration}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'invalid telemetry duration: %s\n' "${telemetry_duration}" >&2
  exit 2
fi
telemetry_deadline=$((SECONDS + telemetry_duration))
while ((SECONDS < telemetry_deadline)); do
  sleep 1
done
"${compose[@]}" --profile acceptance --profile observability stop \
  runtime-metrics runtime-probe-publisher
sleep 2
"${compose[@]}" --profile observability stop otel-collector
test -s "${run_dir}/evidence/metrics.otlp.json"
"${compose[@]}" --profile evidence run --rm --no-deps \
  evidence-sink artifact \
  /evidence/metrics.otlp.json application/json 900000
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
  --run-context /run/robotics/acceptance-run.json \
  --result /run/robotics/results/acceptance-result.json \
  --output /run/robotics/results/acceptance-aggregate.json
sudo chown -R "$(id -u):$(id -g)" "${run_dir}"

mapfile -t mcap_summaries < <(
  find "${run_dir}/evidence/summaries" \
    -maxdepth 1 -type f -name '*.mcap-summary.json' -print |
    LC_ALL=C sort
)
test "${#mcap_summaries[@]}" -ge 1
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
)
for index in "${!mcap_summaries[@]}"; do
  qualification_inputs+=(
    --mcap-summary "primary-${index}=${mcap_summaries[$index]}"
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
cp "${run_dir}/results/qualification-statement.json" "${artifact_dir}/"
cp "${run_dir}/results/qualification.sigstore.json" "${artifact_dir}/"
cp "${run_dir}/results/qualification.pub" "${artifact_dir}/"
cp "${mcap_summaries[@]}" "${artifact_dir}/"
