#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"
root="$(foundation_repository_root)"
export ROBOTICS_FOUNDATION_RUN_ID
ROBOTICS_FOUNDATION_RUN_ID="$(foundation_run_id)-edge-attach"
project="$(foundation_project_name acceptance "${ROBOTICS_FOUNDATION_RUN_ID}" "${GITHUB_RUN_ATTEMPT:-1}")"
export ROBOTICS_FOUNDATION_ARTIFACT_DIR="${root}/artifacts/${project}"
export ROBOTICS_FOUNDATION_OBSERVER=edge-attach
export ROS_DOMAIN_ID=53
export GZ_PARTITION="${project}"
status=0
bash "${script_dir}/run-acceptance.sh" || status=$?
cleanup_status=0
project_status=0
foundation_assert_project_clean "${project}-attach" || cleanup_status=$?
foundation_assert_project_clean "${project}" || project_status=$?
if ((status != 0)); then
  exit "${status}"
fi
if ((cleanup_status != 0)); then
  exit "${cleanup_status}"
fi
exit "${project_status}"
