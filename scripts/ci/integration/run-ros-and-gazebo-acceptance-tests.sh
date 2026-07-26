#!/usr/bin/env bash
set -Eeuo pipefail

docker compose up --detach --no-build --wait --wait-timeout 120 simulation
docker compose exec -T simulation \
  robotics-entrypoint timeout 20 ros2 topic echo \
  /clock rosgraph_msgs/msg/Clock --once
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
