#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"

base_run_id="$(foundation_run_id)"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
run_a="${base_run_id}-acceptance-a"
run_b="${base_run_id}-acceptance-b"
project_a="$(foundation_project_name acceptance "${run_a}" "${run_attempt}")"
project_b="$(foundation_project_name acceptance "${run_b}" "${run_attempt}")"
artifact_a="${root}/artifacts/${project_a}"
artifact_b="${root}/artifacts/${project_b}"
rm -rf "${artifact_a}" "${artifact_b}"
mkdir -p "${artifact_a}" "${artifact_b}"

run_acceptance() (
  export ROBOTICS_FOUNDATION_RUN_ID="$1"
  export ROBOTICS_FOUNDATION_ARTIFACT_DIR="$2"
  export ROS_DOMAIN_ID="$3"
  export GZ_PARTITION="$4"
  bash "${script_dir}/run-acceptance.sh"
)

run_acceptance "${run_a}" "${artifact_a}" 51 "${project_a}" &
pid_a=$!
run_acceptance "${run_b}" "${artifact_b}" 52 "${project_b}" &
pid_b=$!

status_a=0
status_b=0
wait "${pid_a}" || status_a=$?
wait "${pid_b}" || status_b=$?
foundation_assert_project_clean "${project_a}"
foundation_assert_project_clean "${project_b}"
if ((status_a != 0 || status_b != 0)); then
  printf 'parallel acceptance failed: a=%s b=%s\n' "${status_a}" "${status_b}" >&2
  exit 1
fi

mkdir -p "${root}/artifacts"
cp -a "${artifact_a}/." "${root}/artifacts/"
