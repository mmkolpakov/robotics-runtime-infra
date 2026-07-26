#!/usr/bin/env bash

# This module is sourced by physical-attach.sh and uses its coordinator state.
# shellcheck disable=SC2154

physical_attach_input_paths() {
  cat <<'EOF'
compose.can-observation.yaml
compose.edge-attach.yaml
compose.real-observation.test.yaml
compose.real-observation.yaml
compose.security.yaml
compose.serial.yaml
compose.yaml
config/fastdds/udp-only.xml
config/sros2/observer.policy.xml
config/sros2/smoke.policy.xml
docker/permit-preflight/permit-preflight
foundation.repos
policy/execution.rego
scripts/ci/integration/verify-synthetic-physical-attach-end-to-end.sh
scripts/ci/lib.sh
scripts/ci/physical-attach.sh
scripts/ci/physical-attach/authorization.sh
scripts/ci/physical-attach/devices.sh
scripts/ci/physical-attach/observation.sh
systemd/robotics-can-observation@.service
test/ci/physical-attach/authorization-template.json
test/ci/physical-attach/observer-command-denied.sh
test/ci/physical-attach/observer-listen.sh
test/ci/physical-attach/observer-unsecured-source-denied.sh
test/ci/physical-attach/policy-input.jq
test/ci/physical-attach/report.json
test/ci/physical-attach/runtime-manifest.jq
test/ci/physical-attach/target-evidence.json
test/ci/physical-attach/verify-time-evidence.jq
test/physical/hil-runtime.input.json
EOF
}

write_file_input_manifest() {
  local source_root="$1"
  local output="$2"
  local path

  : >"${output}"
  physical_attach_input_paths | LC_ALL=C sort --check --unique
  while IFS= read -r path; do
    test -n "${path}"
    test -f "${source_root}/${path}" && test ! -L "${source_root}/${path}" || {
      printf 'required physical-attach input is absent: %s\n' "${path}" >&2
      return 66
    }
    printf 'file\t%s\t%s\n' \
      "$(sha256_file "${source_root}/${path}")" \
      "${path}" >>"${output}"
  done < <(physical_attach_input_paths)
  test "$(
    wc -l <"${output}" | tr -d ' '
  )" -eq "$(
    physical_attach_input_paths | wc -l | tr -d ' '
  )"
}

write_scenario_input_manifest() {
  local entries="${scenario_manifest}.entries"

  write_file_input_manifest "${REPOSITORY_ROOT}" "${entries}"
  {
    cat "${entries}"
    printf 'evidence\t%s\thardware-time.otlp.json\n' \
      "$(sha256_file "${ROBOTICS_TIME_EVIDENCE}")"
    printf 'evidence\t%s\thardware-time-window.json\n' \
      "$(sha256_file "${ROBOTICS_TIME_EVIDENCE_WINDOW}")"
    printf 'image\t%s\tacceptance-observer\n' "$(
      docker image inspect "${OBSERVER_IMAGE}" --format '{{.Id}}'
    )"
    printf 'image\t%s\tsynthetic-telemetry-source\n' "$(
      docker image inspect "${BENCHMARK_IMAGE}" --format '{{.Id}}'
    )"
    printf 'image\t%s\tcan-client\n' "$(
      docker image inspect "${CAN_CLIENT_IMAGE}" --format '{{.Id}}'
    )"
    printf 'image\t%s\tpermit-preflight\n' \
      "${ROBOTICS_COSIGN_IMAGE_DIGEST}"
    printf 'measurement-run\t%s\thardware-time\n' \
      "${ROBOTICS_TIME_EVIDENCE_RUN_ID}"
  } | LC_ALL=C sort >"${scenario_manifest}"
  rm -f "${entries}"
  test -s "${scenario_manifest}"
}

physical_attach_scenario_sha256() {
  test -s "${scenario_manifest}" || {
    printf 'physical-attach input manifest is absent\n' >&2
    return 66
  }
  sha256_file "${scenario_manifest}"
}

write_trust_policy() {
  local target_identity
  target_identity="$(<"${work_root}/target-identity.sha256")"
  jq \
    --arg target_identity "${target_identity}" '
      .trust_policy |
      .targets[0].identity_sha256 = $target_identity
    ' "${PHYSICAL_ATTACH_FIXTURE_ROOT}/authorization-template.json" \
    >"${work_root}/trust-policy.json"
}

write_permit_case() {
  local case_dir="$1"
  local issued_at="$2"
  local expires_at="$3"
  local request_target_identity="$4"
  local target_evidence="${5:-${work_root}/target-evidence.json}"
  local target_identity
  local scenario_sha256
  local image_digest
  local trust_policy_sha256
  local interlock_sha256
  local checked_at
  local nonce

  mkdir -p "${case_dir}"
  target_identity="$(<"${work_root}/target-identity.sha256")"
  scenario_sha256="$(physical_attach_scenario_sha256)"
  image_digest="$(
    docker image inspect "${OBSERVER_IMAGE}" --format '{{.Id}}'
  )"
  trust_policy_sha256="$(sha256_file "${work_root}/trust-policy.json")"
  interlock_sha256="$(sha256_file "${target_evidence}")"
  checked_at="$(jq -r '.checked_at' "${target_evidence}")"
  nonce="$(tr -d '-' </proc/sys/kernel/random/uuid)"

  cp "${work_root}/trust-policy.json" "${case_dir}/trust-policy.json"
  jq \
    --arg approver_id "ci.approver" \
    --arg checked_at "${checked_at}" \
    --arg expires_at "${expires_at}" \
    --arg image_digest "${image_digest}" \
    --arg interlock_sha256 "${interlock_sha256}" \
    --arg issued_at "${issued_at}" \
    --arg nonce "${nonce}" \
    --arg operator_id "ci.operator" \
    --arg scenario_sha256 "${scenario_sha256}" \
    --arg target_identity "${target_identity}" \
    --arg trust_policy_sha256 "${trust_policy_sha256}" '
      .permit |
      .scenario_sha256 = $scenario_sha256 |
      .image_digest = $image_digest |
      .trust_policy_sha256 = $trust_policy_sha256 |
      .target.identity_sha256 = $target_identity |
      .issued_at = $issued_at |
      .expires_at = $expires_at |
      .nonce = $nonce |
      .operator_id = $operator_id |
      .approver_id = $approver_id |
      .interlock_check.sha256 = $interlock_sha256 |
      .interlock_check.checked_at = $checked_at
    ' "${PHYSICAL_ATTACH_FIXTURE_ROOT}/authorization-template.json" \
    >"${case_dir}/execution-permit.json"

  jq '
    {
      _type: "https://in-toto.io/Statement/v1",
      subject: [
        {
          name: "robotics-scenario",
          digest: {sha256: .scenario_sha256}
        },
        {
          name: "robotics-runtime-image",
          digest: {sha256: (.image_digest | sub("^sha256:"; ""))}
        }
      ],
      predicateType: .predicate_type,
      predicate: .
    }
  ' "${case_dir}/execution-permit.json" \
    >"${case_dir}/execution-statement.json"

  jq \
    --arg checked_at "${checked_at}" \
    --arg image_digest "${image_digest}" \
    --arg interlock_sha256 "${interlock_sha256}" \
    --arg request_target_identity "${request_target_identity}" \
    --arg scenario_sha256 "${scenario_sha256}" '
      .request |
      .scenario_sha256 = $scenario_sha256 |
      .image_digest = $image_digest |
      .target.identity_sha256 = $request_target_identity |
      .interlock_check.sha256 = $interlock_sha256 |
      .interlock_check.checked_at = $checked_at
    ' "${PHYSICAL_ATTACH_FIXTURE_ROOT}/authorization-template.json" \
    >"${case_dir}/execution-request.json"
}

generate_role_keys() {
  local key_dir="${work_root}/keys"
  mkdir -p "${key_dir}"
  chmod 0777 "${key_dir}"
  cosign_run "${key_dir}" generate-key-pair --output-key-prefix operator
  cosign_run "${key_dir}" generate-key-pair --output-key-prefix approver
  cosign_run "${key_dir}" signing-config create \
    --with-default-services \
    --no-default-fulcio \
    --no-default-oidc \
    --no-default-tsa \
    --out signing-config.json
}

sign_and_verify_role() {
  local case_dir="$1"
  local role="$2"
  local scenario_sha256
  local predicate_type

  scenario_sha256="$(jq -r '.scenario_sha256' "${case_dir}/execution-permit.json")"
  predicate_type="$(jq -r '.predicate_type' "${case_dir}/execution-permit.json")"
  chmod 0777 "${case_dir}"

  cosign_run "${work_root}" attest-blob --yes \
    --key "keys/${role}.key" \
    --signing-config keys/signing-config.json \
    --bundle "$(basename "${case_dir}")/${role}.sigstore.json" \
    --statement "$(basename "${case_dir}")/execution-statement.json"
  permit_chmod \
    "${work_root}" \
    0444 \
    "$(basename "${case_dir}")/${role}.sigstore.json"
  permit_run "${work_root}" verify-offline-test-attestation \
    "/work/$(basename "${case_dir}")/execution-statement.json" \
    "/work/$(basename "${case_dir}")/${role}.sigstore.json" \
    "/work/keys/${role}.pub"
  cosign_run "${work_root}" verify-blob-attestation \
    --bundle "$(basename "${case_dir}")/${role}.sigstore.json" \
    --key "keys/${role}.pub" \
    --digest "${scenario_sha256}" \
    --digestAlg sha256 \
    --type "${predicate_type}" >/dev/null
  test "$(
    jq '.verificationMaterial.tlogEntries | length' \
      "${case_dir}/${role}.sigstore.json"
  )" -eq 1
}

write_policy_input() {
  local case_dir="$1"
  local operator_integrated_time
  local approver_integrated_time
  local cosign_version
  local image_digest
  local policy_sha256

  operator_integrated_time="$(
    jq -r '.verificationMaterial.tlogEntries[0].integratedTime' \
      "${case_dir}/operator.sigstore.json"
  )"
  approver_integrated_time="$(
    jq -r '.verificationMaterial.tlogEntries[0].integratedTime' \
      "${case_dir}/approver.sigstore.json"
  )"
  cosign_version="$(
    cosign_run "${case_dir}" version --json |
      jq -r '.gitVersion | sub("^v"; "")'
  )"
  image_digest="$(
    docker image inspect "${PERMIT_PREFLIGHT_IMAGE}" --format '{{.Id}}'
  )"
  policy_sha256="$(
    docker run --rm \
      --entrypoint sha256sum \
      "${PERMIT_PREFLIGHT_IMAGE}" \
      /usr/share/robotics-runtime/policy/execution.rego |
      awk '{print $1}'
  )"

  jq -n \
    --arg approver_bundle_sha256 \
      "$(sha256_file "${case_dir}/approver.sigstore.json")" \
    --arg approver_issuer "https://github.com/sigstore/cosign/key" \
    --arg approver_identity "ci.approver" \
    --arg cosign_image_digest "${image_digest}" \
    --arg cosign_version "${cosign_version}" \
    --arg operator_bundle_sha256 \
      "$(sha256_file "${case_dir}/operator.sigstore.json")" \
    --arg operator_issuer "https://github.com/sigstore/cosign/key" \
    --arg operator_identity "ci.operator" \
    --arg permit_sha256 \
      "$(sha256_file "${case_dir}/execution-permit.json")" \
    --arg policy_sha256 "${policy_sha256}" \
    --arg statement_sha256 \
      "$(sha256_file "${case_dir}/execution-statement.json")" \
    --arg trust_policy_sha256 \
      "$(sha256_file "${case_dir}/trust-policy.json")" \
    --argjson approver_integrated_time "${approver_integrated_time}" \
    --argjson operator_integrated_time "${operator_integrated_time}" \
    --slurpfile permit "${case_dir}/execution-permit.json" \
    --slurpfile request "${case_dir}/execution-request.json" \
    --slurpfile statement "${case_dir}/execution-statement.json" \
    --slurpfile trust_policy "${case_dir}/trust-policy.json" \
    -f "${PHYSICAL_ATTACH_FIXTURE_ROOT}/policy-input.jq" \
    >"${case_dir}/policy-input.json"
}

work_mount_path() {
  local host_path="$1"

  case "${host_path}" in
    "${work_root}")
      printf '/work\n'
      ;;
    "${work_root}"/*)
      printf '/work/%s\n' "${host_path#"${work_root}/"}"
      ;;
    *)
      printf 'path is outside the physical-attach workspace: %s\n' \
        "${host_path}" >&2
      return 66
      ;;
  esac
}

prepare_preflight_directories() {
  local nonce_dir="$1"
  local output_dir="$2"
  local nonce_parent
  local output_parent

  nonce_parent="$(dirname "${nonce_dir}")"
  output_parent="$(dirname "${output_dir}")"
  install -d -m 0755 "${nonce_parent}"
  if test "${output_parent}" != "${nonce_parent}"; then
    install -d -m 0755 "${output_parent}"
  fi

  sudo install \
    -d \
    -m 0700 \
    -o "${PERMIT_PREFLIGHT_UID}" \
    -g "${PERMIT_PREFLIGHT_GID}" \
    "${nonce_dir}"
  sudo install \
    -d \
    -m 0755 \
    -o "${PERMIT_PREFLIGHT_UID}" \
    -g "${PERMIT_PREFLIGHT_GID}" \
    "${output_dir}"
}

run_offline_preflight() {
  local case_dir="$1"
  local nonce_dir="$2"
  local output="$3"
  local case_mount

  case_mount="$(work_mount_path "${case_dir}")"
  permit_run "${work_root}" authorize-offline-test \
    "${case_mount}/execution-permit.json" \
    "${case_mount}/execution-statement.json" \
    "${case_mount}/operator.sigstore.json" \
    "${case_mount}/approver.sigstore.json" \
    /work/keys \
    "${case_mount}/trust-policy.json" \
    "${case_mount}/execution-request.json" \
    "$(work_mount_path "${nonce_dir}")" \
    "$(work_mount_path "${output}")" \
    "${ROBOTICS_COSIGN_IMAGE_DIGEST}"
}

expect_preflight_denial() {
  local case_dir="$1"
  local expected_message="$2"
  local nonce_dir="$3"
  local output="$4"
  local expected_status="${5:-}"
  local denial_log="${case_dir}/preflight-denial.log"
  local status

  set +e
  run_offline_preflight \
    "${case_dir}" \
    "${nonce_dir}" \
    "${output}" >"${denial_log}" 2>&1
  status=$?
  set -e
  test "${status}" -ne 0 || {
    printf 'denied authorization passed the production preflight path\n' >&2
    return 1
  }
  if test -n "${expected_status}"; then
    test "${status}" -eq "${expected_status}" || {
      cat "${denial_log}" >&2
      printf 'preflight returned %s instead of %s\n' \
        "${status}" "${expected_status}" >&2
      return 1
    }
  fi
  if test -n "${expected_message}"; then
    grep -Fq "${expected_message}" "${denial_log}" || {
      cat "${denial_log}" >&2
      return 1
    }
  fi
  test ! -e "${output}" && test ! -L "${output}"
}

require_empty_nonce_store() {
  local nonce_dir="$1"

  test -z "$(
    find "${nonce_dir}" -mindepth 1 -maxdepth 1 -print -quit
  )" || {
    printf 'denied permit consumed a nonce: %s\n' "${nonce_dir}" >&2
    return 1
  }
}

authorize_equivalent_policy_case() {
  local case_dir="$1"
  sign_and_verify_role "${case_dir}" operator
  sign_and_verify_role "${case_dir}" approver
  write_policy_input "${case_dir}"
  opa_eval "${case_dir}" eval \
    --fail \
    --format raw \
    --data /usr/share/robotics-runtime/policy/execution.rego \
    --input /work/policy-input.json \
    data.execution.verification >"${case_dir}/execution-verification.json"
  test -s "${case_dir}/execution-verification.json"
}

expect_policy_denial() {
  local case_dir="$1"
  local expected="$2"
  local deny_output="${case_dir}/policy-deny.json"

  write_policy_input "${case_dir}"
  opa_eval "${case_dir}" eval \
    --format json \
    --data /usr/share/robotics-runtime/policy/execution.rego \
    --input /work/policy-input.json \
    data.execution.deny >"${deny_output}"
  jq -e --arg expected "${expected}" '
    [.result[0].expressions[0].value[]] | index($expected) != null
  ' "${deny_output}" >/dev/null
  if opa_eval "${case_dir}" eval \
    --fail \
    --format raw \
    --data /usr/share/robotics-runtime/policy/execution.rego \
    --input /work/policy-input.json \
    data.execution.verification >/dev/null; then
    printf 'denied authorization unexpectedly produced verification\n' >&2
    return 1
  fi
}

verify_wrong_signer() {
  local case_dir="$1"
  local scenario_sha256
  local predicate_type

  scenario_sha256="$(jq -r '.scenario_sha256' "${case_dir}/execution-permit.json")"
  predicate_type="$(jq -r '.predicate_type' "${case_dir}/execution-permit.json")"
  if cosign_run "${work_root}" verify-blob-attestation \
    --bundle "$(basename "${case_dir}")/approver.sigstore.json" \
    --key keys/approver.pub \
    --digest "${scenario_sha256}" \
    --digestAlg sha256 \
    --type "${predicate_type}" >/dev/null 2>&1; then
    printf 'wrong signer was accepted for the approver role\n' >&2
    return 1
  fi
}

check_production_authorize_contract() {
  local output
  local status

  set +e
  output="$(permit_run "${work_root}" authorize 2>&1)"
  status=$?
  set -e
  test "${status}" -eq 64
  grep -Fq \
    'permit-preflight authorize PERMIT STATEMENT OPERATOR_BUNDLE APPROVER_BUNDLE TRUSTED_ROOT TRUST_POLICY REQUEST NONCE_DIR OUTPUT COSIGN_IMAGE_DIGEST' \
    <<<"${output}"
}
