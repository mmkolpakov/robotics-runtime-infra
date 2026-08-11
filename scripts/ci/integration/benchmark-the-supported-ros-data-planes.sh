#!/usr/bin/env bash
set -Eeuo pipefail

result_root="${PWD}/artifacts/benchmarks"
mkdir -p "${result_root}"
for profile in \
  udp-only.xml \
  shm-only.xml \
  datasharing-required.xml; do
  name="${profile%.xml}"
  result_dir="${result_root}/${name}"
  project="benchmark-${name}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
  mkdir -p "${result_dir}"
  sudo chown -R 1000:1000 "${result_dir}"
  compose=(
    docker compose -p "${project}"
    -f compose.yaml
    -f compose.benchmark.yaml
  )
  set +e
  ROBOTICS_BENCHMARK_PROFILE="${profile}" \
  ROBOTICS_BENCHMARK_DIR="${result_dir}" \
  ROBOTICS_BENCHMARK_DURATION_SEC=5 \
  ROBOTICS_BENCHMARK_PUBLISHER_DURATION_SEC=60 \
    "${compose[@]}" --profile benchmark \
    up --no-build --abort-on-container-exit \
    --exit-code-from benchmark-subscriber \
    benchmark-subscriber benchmark-publisher
  status=$?
  set -e
  "${compose[@]}" --profile benchmark \
    down --volumes --remove-orphans || true
  test "${status}" -eq 0
  jq -e '
    ([.analysis_results[].num_samples_received] | add) > 0 and
    ([.analysis_results[].num_samples_lost] | add) == 0
  ' "${result_dir}/subscriber.json"
done
