#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"

foundation_require_env EVIDENCE_IMAGE SIMULATION_IMAGE

run_id="${GITHUB_RUN_ID:-local}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
project="$(foundation_project_name acceptance "${run_id}" "${run_attempt}")"
run_dir="${root}/runs/foundation-e2e"
rm -rf "${run_dir}"
mkdir -p \
  "${run_dir}/bags" \
  "${run_dir}/evidence" \
  "${run_dir}/results" \
  artifacts
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
export ROBOTICS_SIMULATION_OCI_DIGEST
export ROBOTICS_SIMULATION_OCI_REFERENCE
ROBOTICS_SIMULATION_OCI_DIGEST="$(
  docker image inspect "${SIMULATION_IMAGE}" --format '{{.Id}}'
)"
ROBOTICS_SIMULATION_OCI_REFERENCE="${SIMULATION_IMAGE}@${ROBOTICS_SIMULATION_OCI_DIGEST}"

compose=(
  docker compose -p "${project}"
  -f compose.yaml
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
cleanup() {
  foundation_compose_logs \
    artifacts/foundation-e2e.log \
    "${compose[@]}" "${profiles[@]}"
  if [[ -n "${observer}" ]]; then
    docker logs "${observer}" \
      > artifacts/foundation-observer.log 2>&1 || true
  fi
  foundation_compose_down "${compose[@]}" "${profiles[@]}"
}
trap cleanup EXIT

"${compose[@]}" --profile stepped --profile record --profile observability \
  up --detach --no-build --wait --wait-timeout 120 \
  simulation simulation-stepper recorder otel-collector
curl --fail --silent --show-error \
  --retry 10 --retry-connrefused --retry-delay 1 \
  http://127.0.0.1:13133/
"${compose[@]}" --profile acceptance run --rm runtime-manifest

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
  timestamp="$(date +%s%N)"
  jq -c -n \
    --arg timestamp "${timestamp}" \
    --arg source_id gazebo-clock \
    -f test/observability/foundation-metrics.jq \
    > artifacts/foundation-metrics-input.json
  curl --fail --silent --show-error \
    --header "Content-Type: application/json" \
    --data-binary @artifacts/foundation-metrics-input.json \
    http://127.0.0.1:4318/v1/metrics
  sleep 1
done
timestamp="$(date +%s%N)"
jq -c -n \
  --arg start_timestamp "${timestamp}" \
  --arg end_timestamp "$((timestamp + 1000000))" \
  -f test/observability/foundation-traces.jq \
  > artifacts/foundation-traces-input.json
curl --fail --silent --show-error \
  --header "Content-Type: application/json" \
  --data-binary @artifacts/foundation-traces-input.json \
  http://127.0.0.1:4318/v1/traces
sleep 2
"${compose[@]}" --profile observability stop otel-collector
test -s "${run_dir}/evidence/metrics.otlp.json"
test -s "${run_dir}/evidence/traces.otlp.jsonl"
"${compose[@]}" --profile evidence run --rm --no-deps \
  evidence-sink artifact \
  /evidence/metrics.otlp.json application/json 900000
"${compose[@]}" --profile evidence run --rm --no-deps \
  evidence-sink artifact \
  /evidence/traces.otlp.jsonl application/x-ndjson 900001
"${compose[@]}" --profile record stop recorder
"${compose[@]}" --profile evidence run --rm evidence-finalize
docker wait "${observer}"
test "$(docker inspect "${observer}" --format '{{.State.ExitCode}}')" -eq 0
"${compose[@]}" --profile acceptance run --rm --no-deps \
  acceptance-observer robotics-acceptance aggregate \
  --run-context /run/robotics/acceptance-run.json \
  --result /run/robotics/results/acceptance-result.json \
  --output /run/robotics/results/acceptance-aggregate.json
sudo chown -R "$(id -u):$(id -g)" "${run_dir}"

jq -e '.status == "passed"' \
  "${run_dir}/results/acceptance-result.json"
jq -e \
  '.per_domain_aggregate == "passed" and
   .cross_domain_e2e.status == "unevaluated"' \
  "${run_dir}/results/acceptance-aggregate.json"
jq -e '
  [.segments[].media_type]
  | contains(["application/json", "application/x-ndjson"])
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

cp -r "${run_dir}/results" artifacts/acceptance-results
cp "${run_dir}/runtime-manifest.json" artifacts/
cp "${run_dir}/acceptance-run.json" artifacts/
cp "${run_dir}/evidence/evidence-index.json" artifacts/
cp "${run_dir}/evidence/metrics.otlp.json" artifacts/
cp "${run_dir}/evidence/traces.otlp.jsonl" artifacts/
