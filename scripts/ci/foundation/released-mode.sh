#!/usr/bin/env bash

# Sourced preparation only; runtime execution remains in run-acceptance.sh.
# shellcheck source=scripts/ci/foundation/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
# shellcheck source=scripts/ci/image-provenance.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/image-provenance.sh"
# shellcheck source=scripts/ci/image-identity.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/image-identity.sh"
# shellcheck source=scripts/ci/release/upstream-images.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/release/upstream-images.sh"

foundation_validate_execution_mode() {
  local mode="$1" lock="$2" tag="$3"
  case "${mode}" in
    source)
      [[ -z "${lock}${tag}" ]] || {
        printf 'source mode does not accept a release lock or release tag\n' >&2
        return 64
      }
      ;;
    released)
      [[ -n "${lock}" &&
         "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || {
        printf 'released mode requires a release lock and independent release tag\n' >&2
        return 64
      }
      ;;
    *)
      printf 'unsupported runtime mode: %s\n' "${mode}" >&2
      return 64
      ;;
  esac
}

foundation_prepare_execution_mode() {
  local consumer_root="$1" evidence_dir="$2"
  local mode="${ROBOTICS_RUNTIME_MODE:-source}"
  local lock="${ROBOTICS_FOUNDATION_RELEASE_LOCK:-}"
  local tag="${ROBOTICS_FOUNDATION_RELEASE_TAG:-}"
  local root identities registry repository entries collector pause source key value line id
  local evidence_parent evidence_name status
  local -A expected=() values=()
  local -a images=()
  FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS=()
  declare -gA FOUNDATION_RELEASE_PREPARED_IMAGES=()
  export ROBOTICS_RELEASE_IMAGES_PREPARED=''
  export ROBOTICS_RELEASE_APPROVED_IMAGES='[]'
  export ROBOTICS_RELEASE_LOCK_SNAPSHOT=''
  export ROBOTICS_RELEASE_SOURCE_SHA='' ROBOTICS_RELEASE_SOURCE_REF=''
  foundation_validate_execution_mode "${mode}" "${lock}" "${tag}" || return
  export ROBOTICS_RUNTIME_MODE="${mode}"
  [[ "${mode}" == released ]] || return 0

  source="$(foundation_consumer_file "${consumer_root}" "${lock}")" || return
  [[ "${evidence_dir}" != *[$'\r\n\t']* &&
     ! -e "${evidence_dir}" && ! -L "${evidence_dir}" ]] || {
    printf 'release evidence directory must be new and contain no controls\n' >&2
    return 64
  }
  evidence_name="$(basename -- "${evidence_dir}")"
  IFS= read -r -d '' evidence_parent < <(
    realpath --zero -e "$(dirname -- "${evidence_dir}")"
  ) || return 64
  [[ "${evidence_parent}" != *[$'\r\n\t']* ]] || return 64
  evidence_dir="${evidence_parent}/${evidence_name}"
  mkdir -m 0700 -- "${evidence_dir}" || return
  cp -- "${source}" "${evidence_dir}/release.env" || return
  chmod 0444 "${evidence_dir}/release.env" || return
  root="$(foundation_repository_root)"
  identities="${root}/config/trust/identities.json"
  registry="$(jq -er '.infra.registry' "${identities}")" || return
  repository="$(jq -er '.infra.repository' "${identities}")" || return
  test -n "${GH_TOKEN:-}" || {
    printf 'GH_TOKEN is required to authenticate the release lock\n' >&2
    return 69
  }
  gh release verify "${tag}" --repo "${repository}" --format json \
    >"${evidence_dir}/release-verification.json" || return
  gh release verify-asset "${tag}" "${evidence_dir}/release.env" \
    --repo "${repository}" --format json \
    >"${evidence_dir}/asset-verification.json" || return
  for source in release-verification asset-verification; do
    jq -se 'length == 1 and (.[0] | type == "object" and length > 0)' \
      "${evidence_dir}/${source}.json" >/dev/null || {
      printf 'release verification evidence is empty or malformed\n' >&2
      return 65
    }
    chmod 0444 "${evidence_dir}/${source}.json" || return
    FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS+=(
      --artifact "other_evidence:release/${source}.json=${evidence_dir}/${source}.json"
    )
  done
  # Map keys identify Bake targets; the native plan supplies image repositories.
  GITHUB_OUTPUT="${evidence_dir}/release-plan-output.txt" \
    GITHUB_REF_NAME="${tag}" \
    bash "${root}/scripts/ci/release/prepare-plan.sh" \
      "${root}/config/ci/release-environment.json" \
      "${evidence_dir}/release-plan.json" || return
  chmod 0444 "${evidence_dir}/release-plan.json" || return
  FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS+=(
    --artifact "other_evidence:release/release-plan.json=${evidence_dir}/release-plan.json"
  )
  entries="$(jq -er '.images[] | [.id, .environment_variable] | @tsv' \
    "${evidence_dir}/release-plan.json")" || return
  while IFS=$'\t' read -r id key; do
    expected["${key}"]="${registry}/${id}:${tag#v}"
  done <<<"${entries}"
  collector="$(ci_release_otel_collector_reference)" || return
  expected[OTEL_COLLECTOR_IMAGE]="${collector}"
  pause="$(ci_release_edge_attach_data_plane_reference)" || return
  expected[EDGE_ATTACH_DATA_PLANE_IMAGE]="${pause}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^([A-Z][A-Z0-9_]+)=(.+)$ &&
       "${line}" != *[$'\r\t']* ]] || {
      printf 'release lock must use literal generated KEY=VALUE lines\n' >&2
      return 65
    }
    key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    [[ ! -v "values[${key}]" ]] || {
      printf 'release lock contains a duplicate key: %s\n' "${key}" >&2
      return 65
    }
    case "${key}" in
      ROBOTICS_RUNTIME_MODE) [[ "${value}" == released ]] ;;
      ROBOTICS_RELEASE_SOURCE_SHA) [[ "${value}" =~ ^[a-f0-9]{40}$ ]] ;;
      ROBOTICS_RELEASE_SOURCE_REF) [[ "${value}" == "refs/tags/${tag}" ]] ;;
      OTEL_COLLECTOR_IMAGE | EDGE_ATTACH_DATA_PLANE_IMAGE)
        [[ "${value}" == "${expected[${key}]}" ]]
        ;;
      *)
        [[ -v "expected[${key}]" &&
           "${value%@*}" == "${expected[${key}]}" &&
           "${value##*@}" =~ ^sha256:[a-f0-9]{64}$ ]]
        ;;
    esac || {
      printf 'release lock contains an unexpected or invalid value: %s\n' "${key}" >&2
      return 65
    }
    values["${key}"]="${value}"
  done <"${evidence_dir}/release.env"
  for key in ROBOTICS_RUNTIME_MODE ROBOTICS_RELEASE_SOURCE_SHA \
    ROBOTICS_RELEASE_SOURCE_REF "${!expected[@]}"; do
    [[ -v "values[${key}]" ]] || {
      printf 'release lock is missing: %s\n' "${key}" >&2
      return 65
    }
  done
  for key in SIMULATION_IMAGE OBSERVER_IMAGE EVIDENCE_IMAGE POLICY_TOOLING_IMAGE; do
    [[ -v "expected[${key}]" ]] || {
      printf 'release image inventory is missing: %s\n' "${key}" >&2
      return 65
    }
  done
  for key in "${!expected[@]}"; do
    # The value has already passed the literal canonical-lock grammar.
    export "${key}=${values[${key}]}" || return
    images+=("${values[${key}]}")
  done
  export ROBOTICS_RELEASE_SOURCE_SHA="${values[ROBOTICS_RELEASE_SOURCE_SHA]}"
  export ROBOTICS_RELEASE_SOURCE_REF="${values[ROBOTICS_RELEASE_SOURCE_REF]}"
  export ROBOTICS_RELEASE_LOCK_SNAPSHOT="${evidence_dir}/release.env"
  ROBOTICS_RELEASE_APPROVED_IMAGES="$(
    printf '%s\n' "${images[@]}" | jq -Rsc 'split("\n")[:-1] | sort'
  )" || return
  export ROBOTICS_RELEASE_APPROVED_IMAGES
  FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS+=(
    --artifact "other_evidence:release/release.env=${ROBOTICS_RELEASE_LOCK_SNAPSHOT}"
  )
  mkdir -m 0700 "${evidence_dir}/images" || return
  for key in POLICY_TOOLING_IMAGE SIMULATION_IMAGE OBSERVER_IMAGE EVIDENCE_IMAGE \
    OTEL_COLLECTOR_IMAGE; do
    foundation_prepare_released_image "${!key}" || {
      status=$?
      return "${status}"
    }
  done
  export ROBOTICS_RELEASE_IMAGES_PREPARED=1
}

foundation_prepare_released_image() {
  local requested="$1" canonical hash evidence_dir identity_file proof_file registry
  [[ "${ROBOTICS_RUNTIME_MODE:-source}" == released &&
     -n "${ROBOTICS_RELEASE_LOCK_SNAPSHOT:-}" ]] || {
    printf 'released image preparation requires an authenticated lock\n' >&2
    return 65
  }
  canonical="$(jq -er --arg image "${requested}" '
    def identity:
      split("@") as $parts |
      if ($parts | length) != 2 or
         ($parts[1] | test("^sha256:[a-f0-9]{64}$") | not) or
         ($parts[0] | test("[[:space:]@]")) then
        error("invalid digest-pinned image")
      else
        ($parts[0] | split("/") | .[-1] |= split(":")[0] | join("/"))
        + "@" + $parts[1]
      end;
    ($image | identity) as $requested |
    map(select(identity == $requested)) |
    if length == 1 then .[0] else error("image is outside the approved release lock") end
  ' <<<"${ROBOTICS_RELEASE_APPROVED_IMAGES}")" || return 65
  hash="$(printf '%s' "${canonical}" | sha256sum | cut -d' ' -f1)"
  [[ -z "${FOUNDATION_RELEASE_PREPARED_IMAGES[${hash}]:-}" ]] || return 0
  evidence_dir="$(dirname -- "${ROBOTICS_RELEASE_LOCK_SNAPSHOT}")/images"
  identity_file="${evidence_dir}/${hash}.identity.json"
  registry="$(jq -er '.infra.registry' \
    "$(foundation_repository_root)/config/trust/identities.json")" || return
  if [[ "${canonical}" == "${registry}/"* ]]; then
    proof_file="${evidence_dir}/${hash}.attestation.json"
    ci_verify_released_image_provenance "${canonical}" \
      "${ROBOTICS_RELEASE_SOURCE_SHA}" "${ROBOTICS_RELEASE_SOURCE_REF}" \
      "${proof_file}" || return
  else
    # Upstream dependencies are authenticated as fixed lock entries,
    # not as images built by the infra release workflow.
    [[ "${canonical}" == "${OTEL_COLLECTOR_IMAGE}" ||
       "${canonical}" == "${EDGE_ATTACH_DATA_PLANE_IMAGE}" ]] || return 65
    proof_file=''
  fi
  docker pull "${canonical}" || return
  ci_image_identity "${canonical}" released >"${identity_file}.tmp" || return
  chmod 0444 "${identity_file}.tmp" || return
  mv -- "${identity_file}.tmp" "${identity_file}" || return
  if [[ -n "${proof_file}" ]]; then
    FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS+=(
      --artifact "other_evidence:release/images/${hash}.attestation.json=${proof_file}"
    )
  fi
  FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS+=(
    --artifact "other_evidence:release/images/${hash}.identity.json=${identity_file}"
  )
  FOUNDATION_RELEASE_PREPARED_IMAGES["${hash}"]=1
}
