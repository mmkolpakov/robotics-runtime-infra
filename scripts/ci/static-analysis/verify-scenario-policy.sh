#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo
mkdir -p tmp
ci_yq -o=json test/acceptance/stepped-smoke.yaml \
  > tmp/stepped-smoke.json
test "$(ci_policy_deny_count policy/scenario.rego scenario tmp/stepped-smoke.json)" -eq 0
ci_yq -o=json test/policy/unsafe-compose.yaml \
  > tmp/unsafe-compose.json
test "$(ci_policy_deny_count policy/compose.rego compose tmp/unsafe-compose.json)" -gt 0
ci_yq -o=json test/policy/mock-physical-verdict.yaml \
  > tmp/mock-physical-verdict.json
test "$(ci_policy_deny_count policy/scenario.rego scenario tmp/mock-physical-verdict.json)" -gt 0
