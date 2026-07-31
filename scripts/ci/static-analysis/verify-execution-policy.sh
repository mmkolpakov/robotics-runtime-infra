#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo
mkdir -p tmp
jq '.execution_valid' test/policy/execution/valid.json \
  > tmp/execution-valid-input.json
jq '.execution_valid.permit' test/policy/execution/valid.json \
  > tmp/execution-permit.json
ci_opa eval \
  --fail \
  --format raw \
  --data policy/execution.rego \
  --input tmp/execution-valid-input.json \
  'data.execution.verification with time.now_ns as time.parse_rfc3339_ns("2026-07-14T12:00:00Z")' \
  > tmp/execution-verification.json
ci_validate_contract_documents \
  tmp/execution-permit.json \
  tmp/execution-verification.json
