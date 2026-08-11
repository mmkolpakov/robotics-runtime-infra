#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
}

@test "the benchmark publisher outlives the subscriber oracle" {
  run env \
    ROBOTICS_BENCHMARK_DURATION_SEC=5 \
    ROBOTICS_BENCHMARK_PUBLISHER_DURATION_SEC=60 \
    ROBOTICS_DOMAIN_ID=89 \
    ROBOTICS_RUN_ID=run-benchmark-compose-test \
    docker compose \
    -f compose.yaml \
    -f compose.benchmark.yaml \
    --profile benchmark \
    config --format json
  [ "${status}" -eq 0 ]

  run jq -e '
    . as $model |
    def max_runtime($service):
      $model.services[$service].command as $command |
      $command[($command | index("--max-runtime")) + 1] | tonumber;
    max_runtime("benchmark-publisher") > max_runtime("benchmark-subscriber")
  ' <<<"${output}"
  [ "${status}" -eq 0 ]

  run grep -F -- '--exit-code-from benchmark-subscriber' \
    scripts/ci/integration/benchmark-the-supported-ros-data-planes.sh
  [ "${status}" -eq 0 ]
}
