#!/usr/bin/env bash
set -Eeuo pipefail

simulation_compose=(
  docker compose
  -f compose.yaml
  -f compose.simulation-conformance.yaml
)
"${simulation_compose[@]}" up --detach --no-build --wait --wait-timeout 120 simulation
"${simulation_compose[@]}" exec -T simulation \
  robotics-entrypoint timeout 20 ros2 topic echo \
  /clock rosgraph_msgs/msg/Clock --once
mkdir -p artifacts/simulation-conformance
"${simulation_compose[@]}" \
  --profile simulation-conformance \
  run --rm --no-deps simulation-conformance \
  >artifacts/simulation-conformance/report.json
jq -e '.schema_version == "simulation-conformance.v1" and .status == "passed"' \
  artifacts/simulation-conformance/report.json >/dev/null
test_container="${COMPOSE_PROJECT_NAME}-test"
set +e
docker compose --profile test run \
  --name "${test_container}" --no-deps test
status=$?
set -e
mkdir -p artifacts/test-results
docker cp \
  "${test_container}:/opt/robotics_ws/build/robotics_runtime_infra/test_results/." \
  artifacts/test-results/
docker rm "${test_container}"
test "${status}" -eq 0
