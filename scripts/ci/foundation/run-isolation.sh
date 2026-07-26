#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"
mkdir -p artifacts

run_id="${GITHUB_RUN_ID:-local}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
project_a="$(foundation_project_name isolation-a "${run_id}" "${run_attempt}")"
project_b="$(foundation_project_name isolation-b "${run_id}" "${run_attempt}")"

cleanup() {
  foundation_compose_cleanup \
    artifacts/foundation-a.log \
    docker compose -p "${project_a}"
  foundation_compose_cleanup \
    artifacts/foundation-b.log \
    docker compose -p "${project_b}"
}
trap cleanup EXIT

ROS_DOMAIN_ID=41 GZ_PARTITION="${project_a}" \
  docker compose -p "${project_a}" \
  up --detach --no-build --wait --wait-timeout 120
ROS_DOMAIN_ID=42 GZ_PARTITION="${project_b}" \
  docker compose -p "${project_b}" \
  up --detach --no-build --wait --wait-timeout 120
foundation_wait_for_clock "${project_a}"
foundation_wait_for_clock "${project_b}"
