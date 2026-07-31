#!/bin/sh
set -eu

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

validate_contract() {
  robotics-contracts validate --quiet "$1"
}

assert_single_json_document() {
  document="$1"
  jq --slurp --exit-status 'length == 1' "${document}" >/dev/null || {
    printf 'expected exactly one JSON document: %s\n' "${document}" >&2
    exit 65
  }
}

require_sha256_digest() {
  digest="$1"
  description="$2"
  printf '%s\n' "${digest}" | grep -Eq '^sha256:[a-f0-9]{64}$' || {
    printf '%s must be an immutable sha256 digest\n' "${description}" >&2
    exit 65
  }
}

assert_json_documents_equal() {
  left_document="$1"
  right_document="$2"
  failure_message="$3"
  jq --null-input --exit-status \
    --slurpfile left "${left_document}" \
    --slurpfile right "${right_document}" \
    '($left | length) == 1 and
     ($right | length) == 1 and
     $left[0] == $right[0]' >/dev/null || {
    printf '%s\n' "${failure_message}" >&2
    exit 65
  }
}

bundle_integrated_time() {
  bundle="$1"
  jq -er '
    .verificationMaterial.tlogEntries |
    select(length == 1) |
    .[0].integratedTime | tostring |
    select(test("^[0-9]+$"))
  ' "${bundle}" || {
    printf 'Sigstore bundle requires one numeric transparency-log time: %s\n' \
      "${bundle}" >&2
    exit 65
  }
}

trusted_issuer() {
  role="$1"
  identity="$2"
  trust_policy="$3"
  jq -r --arg role "${role}" --arg identity "${identity}" '
    [.principals[] |
      select(.role == $role and .identity == $identity)] |
    select(length == 1) |
    .[0].issuer
  ' "${trust_policy}"
}

require_file() {
  test -f "$1" && test -r "$1" || {
    printf 'required file is not readable: %s\n' "$1" >&2
    exit 66
  }
}

require_private_writable_directory() {
  directory="$1"
  purpose="$2"
  parent="$(dirname "${directory}")"
  test -d "${parent}" && test ! -L "${parent}" || {
    printf '%s parent must be an existing non-symlink directory: %s\n' \
      "${purpose}" "${parent}" >&2
    exit 73
  }
  test "$(stat -c '%u' "${parent}")" != "$(id -u)" &&
    test -z "$(
      find "${parent}" -maxdepth 0 -perm /022 -print -quit
    )" || {
    printf '%s parent must prevent replacement by the preflight identity: %s\n' \
      "${purpose}" "${parent}" >&2
    exit 73
  }
  test -d "${directory}" && test ! -L "${directory}" &&
    test -w "${directory}" || {
    printf '%s must be an existing writable non-symlink directory: %s\n' \
      "${purpose}" "${directory}" >&2
    exit 73
  }
  test "$(stat -c '%u' "${directory}")" = "$(id -u)" || {
    printf '%s must be owned by the preflight identity: %s\n' \
      "${purpose}" "${directory}" >&2
    exit 73
  }
  test -z "$(
    find "${directory}" -maxdepth 0 -perm /022 -print -quit
  )" || {
    printf '%s must not be writable by group or other: %s\n' \
      "${purpose}" "${directory}" >&2
    exit 73
  }
}

statement_subject_digest() {
  statement="$1"
  jq -er '
      [.subject[] |
        select(.name == "robotics-scenario") |
        .digest.sha256] |
      select(length == 1) |
      .[0] |
      select(type == "string" and test("^[a-f0-9]{64}$"))
    ' "${statement}" || {
    printf 'statement must contain one lowercase sha256 robotics-scenario subject\n' >&2
    exit 65
  }
}

execution_permit_predicate_type() {
  statement="$1"
  predicate_type="$(jq -r '.predicateType' "${statement}")"
  test "${predicate_type}" = \
    'https://robotics-runtime-contracts.dev/attestations/execution-permit/v1' || {
    printf 'statement predicate type is not the execution permit contract\n' >&2
    exit 65
  }
  printf '%s\n' "${predicate_type}"
}

assert_bundle_statement() (
  statement="$1"
  bundle="$2"
  output="$3"
  test "$(jq -r '.mediaType' "${bundle}")" = \
    'application/vnd.dev.sigstore.bundle.v0.3+json' || {
    printf 'unsupported Sigstore bundle media type: %s\n' "${bundle}" >&2
    exit 65
  }
  test "$(jq -r '.dsseEnvelope.payloadType' "${bundle}")" = \
    'application/vnd.in-toto+json' || {
    printf 'Sigstore bundle does not contain an in-toto DSSE envelope: %s\n' \
      "${bundle}" >&2
    exit 65
  }
  payload="$(jq -r '.dsseEnvelope.payload' "${bundle}")"
  test -n "${payload}" && test "${payload}" != null || {
    printf 'Sigstore bundle has no DSSE payload: %s\n' "${bundle}" >&2
    exit 65
  }
  printf '%s' "${payload}" | base64 -d > "${output}" || {
    printf 'Sigstore bundle has an invalid DSSE payload: %s\n' "${bundle}" >&2
    exit 65
  }
  assert_json_documents_equal \
    "${statement}" \
    "${output}" \
    "verified DSSE statement does not equal the supplied statement"
)

authorize_common() {
  test "$#" -eq 8 || {
    printf 'authorize_common requires eight arguments\n' >&2
    return 64
  }
  permit="$1"
  statement="$2"
  operator_bundle="$3"
  approver_bundle="$4"
  trust_policy="$5"
  request="$6"
  nonce_dir="$7"
  output="$8"
  execution_policy=/usr/share/robotics-runtime/policy/execution.rego
  policy_input_filter=/usr/share/robotics-runtime/policy/render-policy-input.jq
  cosign_image_digest_file=/usr/share/robotics-runtime/cosign-image-digest

  for required in \
    "${permit}" \
    "${statement}" \
    "${operator_bundle}" \
    "${approver_bundle}" \
    "${trust_policy}" \
    "${request}" \
    "${execution_policy}" \
    "${policy_input_filter}" \
    "${cosign_image_digest_file}"; do
    require_file "${required}"
  done
  assert_single_json_document "${trust_policy}"
  assert_single_json_document "${request}"
  cosign_image_digest="$(cat "${cosign_image_digest_file}")"
  require_sha256_digest "${cosign_image_digest}" "embedded Cosign image digest"
  test ! -e "${output}" && test ! -L "${output}" || {
    printf 'authorization output already exists: %s\n' "${output}" >&2
    exit 73
  }
  output_dir="$(dirname "${output}")"
  require_private_writable_directory \
    "${output_dir}" \
    "authorization output directory"
  require_private_writable_directory "${nonce_dir}" "nonce store"

  work="$(mktemp -d)"
  output_tmp="$(mktemp "${output}.tmp.XXXXXX")"
  trap 'rm -rf "${work}"; rm -f "${output_tmp}"' EXIT HUP INT TERM

  validate_contract "${permit}"
  jq -c '.predicate' "${statement}" >"${work}/predicate.json"
  validate_contract "${work}/predicate.json"

  operator_identity="$(jq -r '.operator_id' "${permit}")"
  approver_identity="$(jq -r '.approver_id' "${permit}")"
  operator_issuer="$(
    trusted_issuer operator "${operator_identity}" "${trust_policy}"
  )"
  approver_issuer="$(
    trusted_issuer approver "${approver_identity}" "${trust_policy}"
  )"
  test -n "${operator_issuer}" && test -n "${approver_issuer}" || {
    printf 'permit roles do not resolve to unique trusted principals\n' >&2
    exit 65
  }

  verify_role_attestation \
    operator \
    "${statement}" \
    "${operator_bundle}" \
    "${operator_identity}" \
    "${operator_issuer}" \
    "${work}/operator-statement.json"
  verify_role_attestation \
    approver \
    "${statement}" \
    "${approver_bundle}" \
    "${approver_identity}" \
    "${approver_issuer}" \
    "${work}/approver-statement.json"

  operator_integrated_time="$(bundle_integrated_time "${operator_bundle}")"
  approver_integrated_time="$(bundle_integrated_time "${approver_bundle}")"
  permit_sha256="$(sha256_file "${permit}")"
  statement_sha256="$(sha256_file "${statement}")"
  policy_sha256="$(sha256_file "${execution_policy}")"
  trust_policy_sha256="$(sha256_file "${trust_policy}")"
  operator_bundle_sha256="$(sha256_file "${operator_bundle}")"
  approver_bundle_sha256="$(sha256_file "${approver_bundle}")"
  cosign_version="$(
    cosign version --json | jq -er '.gitVersion | ltrimstr("v") | split("+")[0]'
  )"

  jq -c -n \
    --arg approver_bundle_sha256 "${approver_bundle_sha256}" \
    --arg approver_identity "${approver_identity}" \
    --argjson approver_integrated_time "${approver_integrated_time}" \
    --arg approver_issuer "${approver_issuer}" \
    --arg cosign_image_digest "${cosign_image_digest}" \
    --arg cosign_version "${cosign_version}" \
    --arg operator_bundle_sha256 "${operator_bundle_sha256}" \
    --arg operator_identity "${operator_identity}" \
    --argjson operator_integrated_time "${operator_integrated_time}" \
    --arg operator_issuer "${operator_issuer}" \
    --arg permit_sha256 "${permit_sha256}" \
    --arg policy_sha256 "${policy_sha256}" \
    --arg statement_sha256 "${statement_sha256}" \
    --arg trust_policy_sha256 "${trust_policy_sha256}" \
    --slurpfile permit "${permit}" \
    --slurpfile request "${request}" \
    --slurpfile statement "${statement}" \
    --slurpfile trust_policy "${trust_policy}" \
    -f "${policy_input_filter}" \
    >"${work}/input.json"

  opa eval \
    --format raw \
    --data "${execution_policy}" \
    --input "${work}/input.json" \
    '{"denials": data.execution.deny,
      "verification": data.execution.verification}' \
    >"${work}/decision.json"
  if test "$(jq -r '.denials | length' "${work}/decision.json")" -ne 0; then
    jq -r '.denials[]' "${work}/decision.json" >&2
    exit 65
  fi
  jq -ce '.verification | select(. != null)' \
    "${work}/decision.json" >"${output_tmp}" || {
    printf 'execution policy did not produce a verification record\n' >&2
    exit 65
  }
  validate_contract "${output_tmp}"

  nonce="$(jq -r '.nonce' "${permit}")"
  umask 077
  mkdir "${nonce_dir}/${nonce}" || {
    printf 'permit nonce was already consumed: %s\n' "${nonce}" >&2
    exit 77
  }
  printf '%s\n' "${permit_sha256}" >"${nonce_dir}/${nonce}/permit_sha256"
  chmod 0444 "${nonce_dir}/${nonce}/permit_sha256"
  chmod 0444 "${output_tmp}"
  mv "${output_tmp}" "${output}"
  output_tmp=
}

materialize_runtime() {
  test "$#" -eq 5 || {
    printf 'materialize_runtime requires five arguments\n' >&2
    return 64
  }
  template="$1"
  permit="$2"
  verification="$3"
  trust_policy="$4"
  output="$5"

  for required in \
    "${template}" \
    "${permit}" \
    "${verification}" \
    "${trust_policy}"; do
    require_file "${required}"
  done
  assert_single_json_document "${trust_policy}"
  test ! -e "${output}" && test ! -L "${output}" || {
    printf 'runtime manifest output already exists: %s\n' "${output}" >&2
    exit 73
  }
  output_dir="$(dirname "${output}")"
  test -d "${output_dir}" && test -w "${output_dir}" || {
    printf 'runtime manifest output directory is not writable: %s\n' \
      "${output_dir}" >&2
    exit 73
  }

  validate_contract "${template}"
  validate_contract "${permit}"
  validate_contract "${verification}"
  permit_sha256="$(sha256_file "${permit}")"
  verification_sha256="$(sha256_file "${verification}")"
  trust_policy_sha256="$(sha256_file "${trust_policy}")"
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  output_tmp="$(mktemp "${output}.tmp.XXXXXX")"
  trap 'rm -f "${output_tmp}"' EXIT HUP INT TERM
  jq \
    --arg generated_at "${generated_at}" \
    --arg permit_sha256 "${permit_sha256}" \
    --arg verification_sha256 "${verification_sha256}" \
    --arg trust_policy_sha256 "${trust_policy_sha256}" '
      .generated_at = $generated_at |
      .authorization.mode = "verified_execution_permit" |
      .authorization.permit_sha256 = $permit_sha256 |
      .authorization.execution_verification_sha256 =
        $verification_sha256 |
      .authorization.trust_policy_sha256 = $trust_policy_sha256
    ' "${template}" > "${output_tmp}"
  validate_contract "${output_tmp}"
  chmod 0444 "${output_tmp}"
  mv "${output_tmp}" "${output}"
  output_tmp=
}
