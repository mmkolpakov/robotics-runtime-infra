#!/usr/bin/env bash

# This module is sourced by physical-attach.sh and uses its coordinator state.
# shellcheck disable=SC2154

write_scenario_input_manifest() {
  local image
  local repository_status
  local source_revision

  repository_status="$(
    git -C "${REPOSITORY_ROOT}" status --porcelain=v1 --untracked-files=normal
  )"
  test -z "${repository_status}" || {
    printf 'physical attach requires a clean Git worktree\n' >&2
    return 65
  }
  source_revision="$(git -C "${REPOSITORY_ROOT}" rev-parse --verify HEAD)"
  [[ "${source_revision}" =~ ^[a-f0-9]{40}$ ]]
  {
    printf 'source\t%s\trepository\n' "${source_revision}"
    printf 'evidence\t%s\thardware-time.otlp.json\n' \
      "$(sha256_file "${ROBOTICS_TIME_EVIDENCE}")"
    printf 'evidence\t%s\thardware-time-window.json\n' \
      "$(sha256_file "${ROBOTICS_TIME_EVIDENCE_WINDOW}")"
    while IFS= read -r image; do
      printf 'image\t%s\t%s\n' \
        "$(docker image inspect "${image}" --format '{{.Id}}')" \
        "${image}"
    done < <(
      real_compose \
        --profile real-observation \
        --profile real-observation-test \
        --profile real-observation-test-negative \
        config --images | LC_ALL=C sort --unique
    )
    if test "${ROBOTICS_RUNTIME_MODE}" = released; then
      test -s "${ROBOTICS_VERIFIER_PROVENANCE_EVIDENCE}"
      printf 'evidence\t%s\tverifier-attestation.json\n' \
        "$(sha256_file "${ROBOTICS_VERIFIER_PROVENANCE_EVIDENCE}")"
    fi
    printf 'measurement-run\t%s\thardware-time\n' \
      "${ROBOTICS_TIME_EVIDENCE_RUN_ID}"
  } | LC_ALL=C sort >"${scenario_manifest}"
  test -s "${scenario_manifest}"
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
  test -s "${scenario_manifest}" || {
    printf 'physical-attach input manifest is absent\n' >&2
    return 66
  }
  target_identity="$(<"${work_root}/target-identity.sha256")"
  scenario_sha256="$(sha256_file "${scenario_manifest}")"
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

sign_role() {
  local case_dir="$1"
  local role="$2"

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
  test "$(
    jq '.verificationMaterial.tlogEntries | length' \
      "${case_dir}/${role}.sigstore.json"
  )" -eq 1
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
    /work/keys \
    "${case_mount}/execution-permit.json" \
    "${case_mount}/execution-statement.json" \
    "${case_mount}/operator.sigstore.json" \
    "${case_mount}/approver.sigstore.json" \
    "${case_mount}/trust-policy.json" \
    "${case_mount}/execution-request.json" \
    "$(work_mount_path "${nonce_dir}")" \
    "$(work_mount_path "${output}")"
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
  local first_entry

  if ! first_entry="$(
    sudo find "${nonce_dir}" -mindepth 1 -maxdepth 1 -print -quit
  )"; then
    printf 'could not inspect the permit nonce store: %s\n' \
      "${nonce_dir}" >&2
    return 70
  fi
  test -z "${first_entry}" || {
    printf 'denied permit consumed a nonce: %s\n' "${nonce_dir}" >&2
    return 1
  }
}
