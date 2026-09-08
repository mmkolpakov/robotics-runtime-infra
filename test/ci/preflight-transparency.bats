#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PREFLIGHT="${ROOT}/docker/permit-preflight"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export COSIGN_ARGV="${BATS_TEST_TMPDIR}/argv"
  cat >"${BATS_TEST_TMPDIR}/bin/cosign" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"${COSIGN_ARGV}"
exit "${COSIGN_STATUS:-0}"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/cosign"
  # shellcheck source=docker/permit-preflight/core.sh
  source "${PREFLIGHT}/core.sh"
}

load_role() {
  local entrypoint="$1" start=verify_role_attestation
  [[ "${entrypoint}" != permit-preflight-ci ]] || start=verify_offline_attestation
  # Load the real command construction without running the top-level CLI.
  eval "$(sed -n "/^${start}()/,/^command_name=/{ /^command_name=/d; p; }" \
    "${PREFLIGHT}/${entrypoint}")"
  # The command-boundary fixture isolates transparency from contract/DSSE tests.
  require_file() { :; }
  assert_single_json_document() { :; }
  statement_subject_digest() { printf '%064d\n' 0; }
  assert_bundle_statement() { return "${BUNDLE_STATUS:-0}"; }
  ci_key_dir=/fixture/keys
  ci_authorization_mode=authorize-offline-test
}

verify_role() {
  verify_role_with_transparency "$1" \
    operator statement.json bundle.json ci.operator https://github.com/sigstore/cosign/key decoded.json
}

@test "logged CI verifies the key and pinned log root without a bypass" {
  load_role permit-preflight-ci
  ci_authorization_mode=authorize-logged-test
  run verify_role "${BATS_TEST_TMPDIR}/logged.json"
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/logged.json")" = true ]
  ! grep -Fx -- --insecure-ignore-tlog "${COSIGN_ARGV}"
  grep -Fx -- --key "${COSIGN_ARGV}"
  grep -Fx -- /fixture/keys/operator.pub "${COSIGN_ARGV}"
  grep -Fx -- --trusted-root "${COSIGN_ARGV}"
  grep -Fx -- /usr/share/robotics-runtime/trust/sigstore-trusted-root.json "${COSIGN_ARGV}"
}

@test "keyed CI cannot report a claimed OIDC identity or issuer" {
  load_role permit-preflight-ci
  for ci_authorization_mode in authorize-logged-test authorize-offline-test; do
    run verify_role_with_transparency "${BATS_TEST_TMPDIR}/identity.json" \
      operator statement.json bundle.json operator@example.test \
      https://github.com/sigstore/cosign/key decoded.json
    [ "${status}" -eq 65 ]
    run verify_role_with_transparency "${BATS_TEST_TMPDIR}/issuer.json" \
      operator statement.json bundle.json ci.operator \
      https://token.actions.githubusercontent.com decoded.json
    [ "${status}" -eq 65 ]
  done
  [ ! -e "${COSIGN_ARGV}" ]
}

@test "failed log verification cannot produce true" {
  load_role permit-preflight-ci
  ci_authorization_mode=authorize-logged-test
  export COSIGN_STATUS=9
  run verify_role "${BATS_TEST_TMPDIR}/failed-log.json"
  [ "${status}" -eq 65 ]
  [ ! -e "${BATS_TEST_TMPDIR}/failed-log.json" ]
}

@test "real production arguments produce true, real offline arguments produce false" {
  load_role permit-preflight
  run verify_role "${BATS_TEST_TMPDIR}/production.json"
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/production.json")" = true ]
  ! grep -Fx -- --insecure-ignore-tlog "${COSIGN_ARGV}"
  grep -Fx -- --certificate-identity "${COSIGN_ARGV}"

  load_role permit-preflight-ci
  run verify_role "${BATS_TEST_TMPDIR}/offline.json"
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/offline.json")" = false ]
  grep -Fx -- --insecure-ignore-tlog "${COSIGN_ARGV}"
  grep -Fx -- --key "${COSIGN_ARGV}"

  run jq -n \
    --arg approver_bundle_sha256 digest --arg approver_identity approver \
    --argjson approver_integrated_time 1 --arg approver_issuer issuer \
    --arg cosign_image_digest digest --arg cosign_version 3.1.3 \
    --arg operator_bundle_sha256 digest --arg operator_identity operator \
    --argjson operator_integrated_time 1 --arg operator_issuer issuer \
    --arg permit_sha256 digest --arg policy_sha256 digest \
    --arg statement_sha256 digest --arg trust_policy_sha256 digest \
    --argjson permit '[{}]' --argjson statement '[{}]' \
    --argjson request '[{}]' --argjson trust_policy '[{}]' \
    --argjson operator_transparency_log_verified "$(cat "${BATS_TEST_TMPDIR}/production.json")" \
    --argjson approver_transparency_log_verified "$(cat "${BATS_TEST_TMPDIR}/offline.json")" \
    -f "${PREFLIGHT}/render-policy-input.jq"
  [ "${status}" -eq 0 ]
  jq -e '.verified_signers | map(.transparency_log_verified) == [true, false]' <<<"${output}"
}

@test "failed cosign and missing invocation cannot produce verified evidence" {
  load_role permit-preflight
  export COSIGN_STATUS=9
  run verify_role "${BATS_TEST_TMPDIR}/failed.json"
  [ "${status}" -ne 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/failed.json" ]
  unset COSIGN_STATUS
  verify_role_attestation() { :; }
  run verify_role "${BATS_TEST_TMPDIR}/missing.json"
  [ "${status}" -eq 65 ]
  [ ! -e "${BATS_TEST_TMPDIR}/missing.json" ]
}

@test "an invalid bundle still fails after a successful cosign invocation" {
  load_role permit-preflight
  export BUNDLE_STATUS=65
  run verify_role "${BATS_TEST_TMPDIR}/invalid-bundle.json"
  [ "${status}" -eq 65 ]
}

@test "boolean flag values and repeated flags follow the actual final invocation" {
  verify_role_attestation() {
    cosign verify-blob-attestation --insecure-ignore-tlog=true --insecure-ignore-tlog=false
  }
  run verify_role "${BATS_TEST_TMPDIR}/false-option.json"
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/false-option.json")" = true ]
  verify_role_attestation() {
    cosign verify-blob-attestation --insecure-ignore-tlog=false --insecure-ignore-tlog
  }
  run verify_role "${BATS_TEST_TMPDIR}/true-option.json"
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/true-option.json")" = false ]
}

@test "string option values cannot override a real bypass flag" {
  verify_role_attestation() {
    cosign verify-blob-attestation --insecure-ignore-tlog \
      --certificate-identity --insecure-ignore-tlog=false
  }
  run verify_role "${BATS_TEST_TMPDIR}/string-value.json"
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/string-value.json")" = false ]
  verify_role_attestation() {
    cosign verify-blob-attestation --private-infrastructure --insecure-ignore-tlog=false
  }
  run verify_role "${BATS_TEST_TMPDIR}/private.json"
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/private.json")" = false ]
}
