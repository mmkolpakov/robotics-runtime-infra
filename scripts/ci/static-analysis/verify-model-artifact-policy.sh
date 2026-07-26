#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo
mkdir -p tmp
jq '.model_artifact_valid' \
  test/policy/model_artifact/valid.json \
  > tmp/model-artifact-valid.json
jq '.model_artifact_tensorrt' \
  test/policy/model_artifact/tensorrt.json \
  > tmp/model-artifact-tensorrt.json
ci_validate_contract_documents "manifest" \
  tmp/model-artifact-valid.json \
  tmp/model-artifact-tensorrt.json
for candidate in \
  tmp/model-artifact-valid.json \
  tmp/model-artifact-tensorrt.json; do
  test "$(
    ci_policy_deny_count \
      policy/model-artifact.rego \
      model_artifact \
      "${candidate}"
  )" -eq 0
done
for fixture in \
  tampered_target tampered_report wrong_hardware failed_parity; do
  key="model_artifact_${fixture}"
  candidate="tmp/model-artifact-${fixture}.json"
  jq -s --arg key "${key}" \
    '.[0].model_artifact_valid * .[1][$key]' \
    test/policy/model_artifact/valid.json \
    "test/policy/model_artifact/${fixture}.json" \
    > "${candidate}"
  test "$(
    ci_policy_deny_count \
      policy/model-artifact.rego \
      model_artifact \
      "${candidate}"
  )" -gt 0
done
jq -s '
  .[0].model_artifact_tensorrt *
  .[1].model_artifact_wrong_compute_capability
' \
  test/policy/model_artifact/tensorrt.json \
  test/policy/model_artifact/wrong_compute_capability.json \
  > tmp/model-artifact-wrong-compute-capability.json
test "$(
  ci_policy_deny_count \
    policy/model-artifact.rego \
    model_artifact \
    tmp/model-artifact-wrong-compute-capability.json
)" -gt 0
