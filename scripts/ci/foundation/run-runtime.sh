#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"
run_id="$(foundation_run_id)"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
project="$(foundation_project_name runtime "${run_id}" "${run_attempt}")"
artifact_dir="$(foundation_artifact_dir "${root}" "${project}")"
mkdir -p "${artifact_dir}/test-results"

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  local run_status=$?
  local cleanup_status=0
  trap - EXIT
  if ((${status:-0} != 0)); then
    run_status="${status}"
  fi
  foundation_compose_cleanup \
    "${artifact_dir}/foundation-runtime.log" \
    "${project}" \
    docker compose -p "${project}" --profile test || cleanup_status=$?
  if ((run_status != 0)); then
    exit "${run_status}"
  fi
  exit "${cleanup_status}"
}
trap 'cleanup' EXIT

docker compose -p "${project}" \
  up --detach --no-build --wait --wait-timeout 120
foundation_wait_for_clock "${project}"

test_container="${project}-test"
set +e
docker compose -p "${project}" \
  run --name "${test_container}" --no-deps test
status=$?
set -e
docker cp \
  "${test_container}:/opt/robotics_ws/build/robotics_runtime_infra/test_results/." \
  "${artifact_dir}/test-results/"
docker rm "${test_container}"

exit "${status}"
