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

jq -e '
  .execution_valid.trust_policy.max_permit_lifetime_seconds == 1800
' test/policy/execution/valid.json >/dev/null
jq -e '
  .trust_policy.max_permit_lifetime_seconds == 1800
' test/ci/physical-attach/authorization-template.json >/dev/null

jq '.execution_valid.permit
  | .issued_at = "2026-07-14T11:55:00Z"
  | .expires_at = "2026-07-14T12:25:00Z"' \
  test/policy/execution/valid.json >tmp/execution-permit-1800.json
ci_validate_contract_documents tmp/execution-permit-1800.json

jq '.expires_at = "2026-07-14T12:25:01Z"' \
  tmp/execution-permit-1800.json >tmp/execution-permit-1801.json
if ci_validate_contract_documents tmp/execution-permit-1801.json; then
  printf 'contracts accepted a permit lifetime above 1800 seconds\n' >&2
  exit 1
fi

jq '.execution_valid
  | .trust_policy.max_permit_lifetime_seconds = 1801' \
  test/policy/execution/valid.json >tmp/execution-policy-1801.json
deny_count="$(ci_opa eval \
  --format raw \
  --data policy/execution.rego \
  --input tmp/execution-policy-1801.json \
  'count(data.execution.deny)')"
((deny_count > 0))
