#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo
ci_set_compose_fixture_env

case_dir="${CI_REPO_ROOT}/tmp/foundation-consumer-policy"
trap 'rm -rf "${case_dir}"' EXIT
rm -rf "${case_dir}"
mkdir -p "${case_dir}/consumer/src"
printf '%s\n' \
  'services:' \
  '  product:' \
  '    image: registry.k8s.io/pause:3.10.1@sha256:278fb9dbcca9518083ad1e11276933a2e96f23de604a3a08cc3c80002767d24c' \
  '    cap_drop: [ALL]' \
  '    security_opt: [no-new-privileges:true]' \
  '    volumes:' \
  '      - type: bind' \
  '        source: ./src' \
  '        target: /workspace/src' \
  '        read_only: true' \
  >"${case_dir}/consumer/compose.yaml"

files=(
  compose.yaml compose.foundation.yaml compose.stepped.yaml
  compose.record.yaml compose.evidence.yaml compose.observability.yaml
)
profiles=(
  --profile stepped --profile record --profile acceptance
  --profile evidence --profile observability
)
foundation=(docker compose -p foundation-policy-smoke)
for file in "${files[@]}"; do
  foundation+=(-f "${CI_REPO_ROOT}/${file}")
done
"${foundation[@]}" "${profiles[@]}" config --format json >"${case_dir}/foundation.json"
ci_yq_from_root "${case_dir}/consumer" \
  -o=json /input/compose.yaml >"${case_dir}/consumer-source.json"
ci_require_policy_allows \
  policy/consumer_compose_source.rego consumer_compose_source \
  tmp/foundation-consumer-policy/consumer-source.json
ci_require_source_paths_within_root \
  "${case_dir}/consumer-source.json" "${case_dir}/consumer"
env -i \
  PATH="${PATH}" \
  HOME="${HOME}" \
  PWD="${CI_REPO_ROOT}" \
  COMPOSE_DISABLE_ENV_FILE=1 \
  docker compose \
  --project-directory "${case_dir}/consumer" \
  -f "${case_dir}/consumer/compose.yaml" \
  config --no-normalize --format json >"${case_dir}/consumer.json"
ci_require_model_paths_within_root \
  "${case_dir}/consumer.json" "${case_dir}/consumer"

jq -n \
  --arg root "${CI_REPO_ROOT}" \
  --arg consumer "${case_dir}/consumer.json" \
  --arg consumer_root "${case_dir}/consumer" \
  --argjson files "$(printf '%s\n' "${files[@]}" | jq -Rsc 'split("\n")[:-1]')" \
  '{
    include: [
      {
        path: [$files[] | ($root + "/" + .)],
        project_directory: $root
      },
      {path: $consumer, project_directory: $consumer_root}
    ],
    services: {}
  }' >"${case_dir}/wrapper.json"
docker compose -p foundation-policy-smoke -f "${case_dir}/wrapper.json" \
  "${profiles[@]}" config --format json >"${case_dir}/resolved.json"

jq -n \
  --slurpfile foundation "${case_dir}/foundation.json" \
  --slurpfile consumer "${case_dir}/consumer.json" \
  --slurpfile resolved "${case_dir}/resolved.json" \
  --arg consumer_root "${case_dir}/consumer" \
  '{
    foundation: $foundation[0],
    consumer: $consumer[0],
    resolved: $resolved[0],
    consumer_root: $consumer_root,
    allowed_services: ["product"]
  }' >"${case_dir}/input.json"

ci_require_policy_allows \
  policy/foundation.rego foundation tmp/foundation-consumer-policy/input.json
ci_require_policy_allows \
  policy/compose.rego compose tmp/foundation-consumer-policy/resolved.json
jq -e '.services.product.volumes[0].source | endswith("/consumer/src")' \
  "${case_dir}/resolved.json" >/dev/null
