#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo
mkdir -p tmp
for workflow in \
  .github/workflows/hardware-qualification.yml \
  .github/workflows/rk3588-qualification.yml; do
  workflow_json="tmp/$(basename "${workflow}" .yml).json"
  ci_yq -o=json "${workflow}" > "${workflow_json}"
  test "$(
    ci_policy_deny_count \
      policy/hardware-workflow.rego \
      hardware_workflow \
      "${workflow_json}"
  )" -eq 0
done
