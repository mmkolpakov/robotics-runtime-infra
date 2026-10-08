#!/usr/bin/env bash

ci_verify_released_image_provenance() {
  local image="$1" source_sha="$2" source_ref="$3" evidence="$4"
  local root identities canonical_repository registry signer_workflow
  local evidence_tmp verification_status
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
  identities="${root}/config/trust/identities.json"
  canonical_repository="$(jq -er '.infra.repository' "${identities}")" || return
  registry="$(jq -er '.infra.registry' "${identities}")" || return
  signer_workflow="${canonical_repository}/.github/workflows/$(jq -er '.infra.release_workflow' "${identities}")"

  [[ "${source_sha}" =~ ^[a-f0-9]{40}$ ]] || {
    printf 'ROBOTICS_RELEASE_SOURCE_SHA is not a Git commit digest\n' >&2
    return 65
  }
  [[ "${source_ref}" =~ ^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || {
    printf 'ROBOTICS_RELEASE_SOURCE_REF is not a release tag ref\n' >&2
    return 65
  }
  [[ "${image##*@}" =~ ^sha256:[a-f0-9]{64}$ ]] &&
    [[ "${image%@*}" == "${registry}/"* ]] || {
    printf 'released image must pin the canonical registry: %s\n' "${image}" >&2
    return 65
  }
  test -n "${GH_TOKEN:-}" || {
    printf 'GH_TOKEN is required to verify released image provenance\n' >&2
    return 69
  }

  evidence_tmp="${evidence}.tmp"
  (
    umask 077
    gh attestation verify "oci://${image}" \
      --repo "${canonical_repository}" \
      --signer-workflow "${signer_workflow}" \
      --source-digest "${source_sha}" \
      --source-ref "${source_ref}" \
      --deny-self-hosted-runners \
      --bundle-from-oci \
      --format json >"${evidence_tmp}"
  ) || {
    verification_status=$?
    rm -f -- "${evidence_tmp}"
    return "${verification_status}"
  }
  jq -se 'length == 1 and (.[0] | type == "array" and length > 0)' "${evidence_tmp}" >/dev/null || {
    printf 'image provenance evidence is empty or malformed\n' >&2
    rm -f -- "${evidence_tmp}"
    return 65
  }
  chmod 0444 "${evidence_tmp}" || return
  mv -- "${evidence_tmp}" "${evidence}"
}
