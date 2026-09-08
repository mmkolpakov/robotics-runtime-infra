#!/usr/bin/env bash
set -Eeuo pipefail

export PHYSICAL_ATTACH_LIBRARY_ONLY=1
# shellcheck source=scripts/ci/physical-attach.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../physical-attach.sh"
cd "${REPOSITORY_ROOT}"

work_root="$(mktemp -d "${RUNNER_TEMP}/permit-logged.XXXXXXXX")"
trap 'sudo rm -rf -- "${work_root}"' EXIT
chmod 0755 "${work_root}"
case_dir="${work_root}/positive"
mkdir "${case_dir}"
issued_at="$(date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"
expires_at="$(date -u -d '15 minutes' +%Y-%m-%dT%H:%M:%SZ)"
jq '
  .execution_valid.trust_policy |
  .principals = [
    {role: "operator", identity: "ci.operator", issuer: "https://github.com/sigstore/cosign/key"},
    {role: "approver", identity: "ci.approver", issuer: "https://github.com/sigstore/cosign/key"}
  ]
' test/policy/execution/valid.json >"${case_dir}/trust-policy.json"
jq --arg issued "${issued_at}" --arg expires "${expires_at}" \
  --arg trust_sha "$(sha256_file "${case_dir}/trust-policy.json")" '
    .execution_valid.permit |
    .operator_id = "ci.operator" | .approver_id = "ci.approver" |
    .issued_at = $issued | .expires_at = $expires |
    .interlock_check.checked_at = $issued | .trust_policy_sha256 = $trust_sha
  ' test/policy/execution/valid.json >"${case_dir}/execution-permit.json"
jq --arg issued "${issued_at}" '
  .execution_valid.request | .interlock_check.checked_at = $issued
' test/policy/execution/valid.json >"${case_dir}/execution-request.json"
jq --slurpfile permit "${case_dir}/execution-permit.json" '
  .execution_valid.statement | .predicate = $permit[0]
' test/policy/execution/valid.json >"${case_dir}/execution-statement.json"

# Real signatures and public Rekor entries; failure is never replaced by bypass.
generate_role_keys
sign_role "${case_dir}" operator
sign_role "${case_dir}" approver
prepare_preflight_directories "${work_root}/positive-state/nonces" "${work_root}/positive-state/output"
run_test_preflight "${case_dir}" "${work_root}/positive-state/nonces" \
  "${work_root}/positive-state/output/verification.json"
jq -e '
  .decision == "allow" and ([.signers[].role] | sort) == ["approver", "operator"] and
  [.signers[].transparency_log_verified] == [true, true]
' "${work_root}/positive-state/output/verification.json" >/dev/null
test "$(sudo cat "${work_root}/positive-state/nonces/0123456789abcdef0123456789abcdef/permit_sha256")" = \
  "$(sha256_file "${case_dir}/execution-permit.json")"
expect_preflight_denial "${case_dir}" 'permit nonce was already consumed' \
  "${work_root}/positive-state/nonces" "${work_root}/positive-state/output/replay.json" 77

prepare_preflight_directories "${work_root}/offline-state/nonces" "${work_root}/offline-state/output"
expect_preflight_denial "${case_dir}" 'signer has no transparency-log proof' \
  "${work_root}/offline-state/nonces" "${work_root}/offline-state/output/verification.json" \
  65 authorize-offline-test
require_empty_nonce_store "${work_root}/offline-state/nonces"

for invalid in bad-proof missing-log wrong-key; do
  invalid_case="${work_root}/${invalid}"
  cp -a "${case_dir}" "${invalid_case}"
  case "${invalid}" in
    bad-proof)
      jq '.verificationMaterial.tlogEntries[0].inclusionProof.hashes[0] =
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
        "${case_dir}/operator.sigstore.json" >"${invalid_case}/operator.tmp"
      ;;
    missing-log)
      jq '.verificationMaterial.tlogEntries = []' \
        "${case_dir}/operator.sigstore.json" >"${invalid_case}/operator.tmp"
      ;;
    wrong-key)
      cp "${case_dir}/approver.sigstore.json" "${invalid_case}/operator.tmp"
      ;;
  esac
  mv -f "${invalid_case}/operator.tmp" "${invalid_case}/operator.sigstore.json"
  prepare_preflight_directories "${work_root}/${invalid}-state/nonces" "${work_root}/${invalid}-state/output"
  expect_preflight_denial "${invalid_case}" 'logged attestation verification failed' \
    "${work_root}/${invalid}-state/nonces" "${work_root}/${invalid}-state/output/verification.json" 65
  require_empty_nonce_store "${work_root}/${invalid}-state/nonces"
done
printf 'logged permit: allow, consumed nonce, replay, offline bypass and three corruptions checked\n'
