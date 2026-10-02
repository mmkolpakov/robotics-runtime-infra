#!/usr/bin/env bats

# Every case reruns setup; mutations are intentionally confined to that case.
# shellcheck disable=SC2030,SC2031

setup() {
  bats_require_minimum_version 1.5.0
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  source "${REPOSITORY_ROOT}/scripts/ci/lib.sh"
  source "${REPOSITORY_ROOT}/scripts/ci/foundation/released-mode.sh"
  consumer="${BATS_TEST_TMPDIR}/consumer"
  evidence="${BATS_TEST_TMPDIR}/release"
  trace="${BATS_TEST_TMPDIR}/calls"
  mkdir "${consumer}"
  : >"${trace}"
  registry="$(jq -r '.infra.registry' "${REPOSITORY_ROOT}/config/trust/identities.json")"
  collector="$(ci_release_otel_collector_reference)"
  pause="$(ci_release_edge_attach_data_plane_reference)"
  export GH_TOKEN=fixture-token ROBOTICS_RUNTIME_MODE=released
  export ROBOTICS_FOUNDATION_RELEASE_TAG=v0.8.0
  export ROBOTICS_FOUNDATION_RELEASE_LOCK="${consumer}/release.env"
  fixture_plan="${BATS_TEST_TMPDIR}/fixture-plan.json"
  GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/fixture-plan-output" \
    GITHUB_REF_NAME="${ROBOTICS_FOUNDATION_RELEASE_TAG}" \
    bash "${REPOSITORY_ROOT}/scripts/ci/release/prepare-plan.sh" \
      "${REPOSITORY_ROOT}/config/ci/release-environment.json" "${fixture_plan}"
  {
    printf '%s\n' 'ROBOTICS_RUNTIME_MODE=released'
    printf 'ROBOTICS_RELEASE_SOURCE_SHA=%040d\n' 1
    printf '%s\n' 'ROBOTICS_RELEASE_SOURCE_REF=refs/tags/v0.8.0'
    jq -r --arg registry "${registry}" \
      '.images[] | "\(.environment_variable)=\($registry)/\(.id):0.8.0@sha256:\("a" * 64)"' \
      "${fixture_plan}"
    printf 'OTEL_COLLECTOR_IMAGE=%s\n' "${collector}"
    printf 'EDGE_ATTACH_DATA_PLANE_IMAGE=%s\n' "${pause}"
  } >"${ROBOTICS_FOUNDATION_RELEASE_LOCK}"
}

# Replace external auth/registry transport; keep native Compose and identity checks.
gh() {
  printf 'gh %s\n' "$*" >>"${trace}"
  [[ " $* " == *' --repo mmkolpakov/robotics-runtime-infra '* ]] || return 99
  case "$1 $2" in
    'release verify')
      [[ "$3" == "${ROBOTICS_FOUNDATION_RELEASE_TAG}" ]] || return 99
      [[ -z "${GH_RELEASE_STATUS:-}" ]] || return "${GH_RELEASE_STATUS}"
      if [[ -v GH_RELEASE_JSON ]]; then
        printf '%s\n' "${GH_RELEASE_JSON}"
      else
        printf '%s\n' '{"verified":true}'
      fi
      ;;
    'release verify-asset')
      [[ "$3" == "${ROBOTICS_FOUNDATION_RELEASE_TAG}" ]] || return 99
      cmp -- "${ROBOTICS_FOUNDATION_RELEASE_LOCK}" "$4" || return 99
      [[ -z "${GH_ASSET_STATUS:-}" ]] || return "${GH_ASSET_STATUS}"
      if [[ -v GH_ASSET_JSON ]]; then
        printf '%s\n' "${GH_ASSET_JSON}"
      else
        printf '%s\n' '{"verified":true}'
      fi
      ;;
    'attestation verify')
      [[ " $* " == *" --signer-workflow mmkolpakov/robotics-runtime-infra/.github/workflows/release-image.yml "* &&
         " $* " == *" --source-digest ${ROBOTICS_RELEASE_SOURCE_SHA} "* &&
         " $* " == *" --source-ref refs/tags/${ROBOTICS_FOUNDATION_RELEASE_TAG} "* &&
         " $* " == *' --deny-self-hosted-runners '* &&
         " $* " == *' --bundle-from-oci '* ]] || return 99
      [[ -z "${GH_IMAGE_STATUS:-}" ]] || return "${GH_IMAGE_STATUS}"
      if [[ -v GH_IMAGE_JSON ]]; then
        printf '%s\n' "${GH_IMAGE_JSON}"
      else
        printf '%s\n' '[{}]'
      fi
      ;;
    *) return 99 ;;
  esac
}

docker() {
  local image digest
  if [[ "$1" == compose ]]; then
    command docker "$@"
    return
  fi
  printf 'docker %s\n' "$*" >>"${trace}"
  case "$1 ${2:-}" in
    'pull '*)
      [[ -z "${DOCKER_PULL_STATUS:-}" ]] || return "${DOCKER_PULL_STATUS}"
      ;;
    'image inspect')
      image="$3" digest="${3##*@}"
      jq -nc --arg pin "${image%@*}${digest:+@}${digest}" \
        '[{Id: ("sha256:" + ("b" * 64)), RepoDigests: [$pin]}]'
      ;;
    'buildx imagetools')
      digest="${*: -1}" digest="${digest##*@}"
      jq -nc --arg digest "${digest}" \
        '{digest:$digest,mediaType:"application/vnd.oci.image.manifest.v1+json"}'
      ;;
    *) return 99 ;;
  esac
}

prepare() {
  foundation_prepare_execution_mode "${consumer}" "${evidence}" || return
  jq -nc --argjson approved "${ROBOTICS_RELEASE_APPROVED_IMAGES}" \
    --arg snapshot "${ROBOTICS_RELEASE_LOCK_SNAPSHOT}" \
    --arg sha "${ROBOTICS_RELEASE_SOURCE_SHA}" \
    --arg ref "${ROBOTICS_RELEASE_SOURCE_REF}" \
    --arg policy "${POLICY_TOOLING_IMAGE:-}" \
    --argjson argument_count "${#FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS[@]}" \
    '{approved:$approved,snapshot:$snapshot,sha:$sha,ref:$ref,
      policy:$policy,argument_count:$argument_count}'
}

@test "source default is offline and rejects released inputs" {
  unset ROBOTICS_RUNTIME_MODE
  ROBOTICS_FOUNDATION_RELEASE_LOCK='' ROBOTICS_FOUNDATION_RELEASE_TAG=''
  run prepare
  [ "${status}" -eq 0 ]
  jq -e '.approved == [] and .snapshot == "" and .sha == "" and .ref == ""' <<<"${output}"
  [ ! -s "${trace}" ]
  [ ! -e "${evidence}" ]
  ROBOTICS_FOUNDATION_RELEASE_TAG=v0.8.0
  run prepare
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"source mode does not accept"* ]]
  [ ! -s "${trace}" ]
}

@test "mode and independent release tag fail before authentication" {
  ROBOTICS_RUNTIME_MODE=unknown
  run prepare
  [ "${status}" -eq 64 ]
  ROBOTICS_RUNTIME_MODE=released ROBOTICS_FOUNDATION_RELEASE_TAG=''
  run prepare
  [ "${status}" -eq 64 ]
  ROBOTICS_FOUNDATION_RELEASE_TAG=$'v0.8.0\nOTHER=value'
  run prepare
  [ "${status}" -eq 64 ]
  [ ! -s "${trace}" ]
}

@test "caller lock confinement rejects outside files and control suffixes" {
  cp "${ROBOTICS_FOUNDATION_RELEASE_LOCK}" "${BATS_TEST_TMPDIR}/outside.env"
  ROBOTICS_FOUNDATION_RELEASE_LOCK="${BATS_TEST_TMPDIR}/outside.env"
  run prepare
  [ "${status}" -eq 64 ]
  ROBOTICS_FOUNDATION_RELEASE_LOCK="${consumer}/release.env"$'\n'
  cp "${consumer}/release.env" "${ROBOTICS_FOUNDATION_RELEASE_LOCK}"
  run prepare
  [ "${status}" -eq 64 ]
  [ ! -s "${trace}" ]
}

@test "authenticated raw lock exports full inventory but prepares only selected images" {
  POLICY_TOOLING_IMAGE=ambient-untrusted OTEL_COLLECTOR_IMAGE=ambient-untrusted
  run --separate-stderr prepare
  [ "${status}" -eq 0 ]
  jq -e --argjson count "$(jq 'length + 2' "${REPOSITORY_ROOT}/config/ci/release-environment.json")" \
    '.approved | length == $count' <<<"${output}"
  jq -e --arg snapshot "${evidence}/release.env" \
    '.snapshot == $snapshot and .ref == "refs/tags/v0.8.0" and
     (.policy | startswith("ghcr.io/mmkolpakov/robotics-runtime-infra/policy-tooling:0.8.0@")) and
     .argument_count == 26' <<<"${output}"
  cmp "${consumer}/release.env" "${evidence}/release.env"
  [ "$(stat -c %a "${evidence}/release.env")" = 444 ]
  [ "$(grep -c '^docker pull ' "${trace}")" -eq 5 ]
  [ "$(grep -c '^gh attestation ' "${trace}")" -eq 4 ]
  [[ "$(sed -n '1p' "${trace}")" == 'gh release verify v0.8.0 --repo '* ]]
  [[ "$(sed -n '2p' "${trace}")" == 'gh release verify-asset v0.8.0 '* ]]
  [[ "$(sed -n '3p' "${trace}")" == *'/policy-tooling:0.8.0@'* ]]
  run ! grep -E '^gh attestation .*otel/opentelemetry' "${trace}"
  [ "$(find "${evidence}/images" -name '*.identity.json' | wc -l)" -eq 5 ]
}

@test "native asset failure preserves status and prevents image access" {
  GH_ASSET_STATUS=42
  run prepare
  [ "${status}" -eq 42 ]
  [ "$(grep -c '^gh release ' "${trace}")" -eq 2 ]
  run ! grep -E '^(docker |gh attestation )' "${trace}"
  cmp "${consumer}/release.env" "${evidence}/release.env"
}

@test "authenticated malformed locks never become executable data" {
  cp "${ROBOTICS_FOUNDATION_RELEASE_LOCK}" "${BATS_TEST_TMPDIR}/original.env"
  for mutation in duplicate missing repository tag collector pause command; do
    cp "${BATS_TEST_TMPDIR}/original.env" "${ROBOTICS_FOUNDATION_RELEASE_LOCK}"
    evidence="${BATS_TEST_TMPDIR}/${mutation}"
    : >"${trace}"
    case "${mutation}" in
      duplicate) printf 'ROBOTICS_RUNTIME_MODE=released\n' >>"${ROBOTICS_FOUNDATION_RELEASE_LOCK}" ;;
      missing) sed -i '/^EVIDENCE_IMAGE=/d' "${ROBOTICS_FOUNDATION_RELEASE_LOCK}" ;;
      repository) sed -i 's@/policy-tooling:@/unapproved-policy:@' "${ROBOTICS_FOUNDATION_RELEASE_LOCK}" ;;
      tag) sed -i 's@refs/tags/v0.8.0@refs/tags/v0.9.0@' "${ROBOTICS_FOUNDATION_RELEASE_LOCK}" ;;
      collector) sed -i 's@^OTEL_COLLECTOR_IMAGE=.*@OTEL_COLLECTOR_IMAGE=untrusted:latest@' "${ROBOTICS_FOUNDATION_RELEASE_LOCK}" ;;
      pause) sed -i 's@^EDGE_ATTACH_DATA_PLANE_IMAGE=.*@EDGE_ATTACH_DATA_PLANE_IMAGE=untrusted:latest@' "${ROBOTICS_FOUNDATION_RELEASE_LOCK}" ;;
      command)
        sed -i '/^POLICY_TOOLING_IMAGE=/d' "${ROBOTICS_FOUNDATION_RELEASE_LOCK}"
        # shellcheck disable=SC2016
        printf 'POLICY_TOOLING_IMAGE=$(touch %s)\n' \
          "${consumer}/executed" >>"${ROBOTICS_FOUNDATION_RELEASE_LOCK}"
        ;;
    esac
    run prepare
    [ "${status}" -eq 65 ]
    [ "$(grep -c '^gh release ' "${trace}")" -eq 2 ]
    run ! grep -E '^(docker |gh attestation )' "${trace}"
    [ ! -e "${consumer}/executed" ]
  done
}

failure_without_authority() {
  local failure
  foundation_prepare_execution_mode "${consumer}" "${evidence}"
  failure=$?
  [[ "${ROBOTICS_RELEASE_APPROVED_IMAGES}" == '[]' &&
     -z "${ROBOTICS_RELEASE_LOCK_SNAPSHOT}${ROBOTICS_RELEASE_SOURCE_SHA}${ROBOTICS_RELEASE_SOURCE_REF}" &&
     "${POLICY_TOOLING_IMAGE}" == ambient-untrusted ]] || return 99
  return "${failure}"
}

@test "native planner failure preserves status before exporting release authority" {
  shims="${BATS_TEST_TMPDIR}/planner-bin"
  mkdir "${shims}"
  export PLAN_REAL_DOCKER
  PLAN_REAL_DOCKER="$(type -P docker)"
  cat >"${shims}/docker" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == 'buildx bake --file docker-bake.hcl --print release' ]]; then
  printf 'native planner failed\n' >&2
  exit 44
fi
exec "${PLAN_REAL_DOCKER}" "$@"
SH
  chmod +x "${shims}/docker"
  POLICY_TOOLING_IMAGE=ambient-untrusted
  PATH="${shims}:${PATH}" run failure_without_authority
  [ "${status}" -eq 44 ]
  [[ "${output}" == *'native planner failed'* ]]
  [ ! -e "${evidence}/release-plan.json" ]
  [ ! -e "${evidence}/images" ]
  run ! grep -E '^(docker |gh attestation )' "${trace}"
}

@test "target names cannot replace the native released image repository IDs" {
  cp "${ROBOTICS_FOUNDATION_RELEASE_LOCK}" "${BATS_TEST_TMPDIR}/native.env"
  for id in benchmark edge sensor; do
    cp "${BATS_TEST_TMPDIR}/native.env" "${ROBOTICS_FOUNDATION_RELEASE_LOCK}"
    sed -i "s@/${id}:@/${id}-runtime:@" "${ROBOTICS_FOUNDATION_RELEASE_LOCK}"
    evidence="${BATS_TEST_TMPDIR}/target-${id}"
    : >"${trace}"
    run prepare
    [ "${status}" -eq 65 ]
    [[ "${output}" == *'unexpected or invalid value'* ]]
    run ! grep -E '^(docker |gh attestation )' "${trace}"
  done
}

@test "empty or multiple release verification documents cannot export authority" {
  POLICY_TOOLING_IMAGE=ambient-untrusted
  for invalid in '{}' $'{"verified":true}\n{"verified":true}'; do
    evidence="${BATS_TEST_TMPDIR}/bad-json-${RANDOM}"
    GH_ASSET_JSON="${invalid}"
    run failure_without_authority
    [ "${status}" -eq 65 ]
  done
  run ! grep -E '^(docker |gh attestation )' "${trace}"
}

@test "internal image provenance failure and empty result stop before pull" {
  GH_IMAGE_STATUS=42
  run prepare
  [ "${status}" -eq 42 ]
  run ! grep '^docker ' "${trace}"
  [ -z "$(find "${evidence}/images" -name '*.tmp' -print)" ]
  unset GH_IMAGE_STATUS
  for invalid in '[]' $'[{}]\n[{}]'; do
    evidence="${BATS_TEST_TMPDIR}/bad-image-${RANDOM}"
    GH_IMAGE_JSON="${invalid}"
    run prepare
    [ "${status}" -eq 65 ]
  done
  run ! grep '^docker ' "${trace}"
}

@test "pull failure remains a failure after verified image provenance" {
  DOCKER_PULL_STATUS=43
  run prepare
  [ "${status}" -eq 43 ]
  [ "$(grep -c '^gh attestation ' "${trace}")" -eq 1 ]
  [ "$(grep -c '^docker pull ' "${trace}")" -eq 1 ]
  run ! grep '^docker image inspect' "${trace}"
}

prepare_aliases_and_extra() {
  foundation_prepare_execution_mode "${consumer}" "${evidence}" || return
  local alias="${SIMULATION_IMAGE%@*}"
  alias="${alias%:*}@${SIMULATION_IMAGE##*@}"
  foundation_prepare_released_image "${alias}" || return
  foundation_prepare_released_image "${SIMULATION_IMAGE}" || return
  foundation_prepare_released_image "${EDGE_IMAGE}" || return
  alias="${EDGE_IMAGE%@*}"
  alias="${alias%:*}:display-alias@"
  alias+="${EDGE_IMAGE##*@}"
  foundation_prepare_released_image "${alias}" || return
  printf '%s\n' "${#FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS[@]}"
}

@test "selected approved extra and normalized aliases share immutable evidence" {
  run --separate-stderr prepare_aliases_and_extra
  [ "${status}" -eq 0 ]
  [ "${output}" = 30 ]
  [ "$(grep -c '^docker pull ' "${trace}")" -eq 6 ]
  [ "$(grep -c '^gh attestation ' "${trace}")" -eq 5 ]
  [ "$(find "${evidence}/images" -name '*.identity.json' | wc -l)" -eq 6 ]
}

prepare_then_reject_foreign() {
  foundation_prepare_execution_mode "${consumer}" "${evidence}" || return
  : >"${trace}"
  foundation_prepare_released_image "ghcr.io/foreign/simulation@${SIMULATION_IMAGE##*@}"
}

@test "matching digest under unapproved repository cannot reach provenance or pull" {
  run prepare_then_reject_foreign
  [ "${status}" -eq 65 ]
  [ ! -s "${trace}" ]
}

@test "existing evidence is never overwritten by a retry" {
  run prepare
  [ "${status}" -eq 0 ]
  cp "${evidence}/release.env" "${BATS_TEST_TMPDIR}/saved.env"
  : >"${trace}"
  run prepare
  [ "${status}" -eq 64 ]
  cmp "${BATS_TEST_TMPDIR}/saved.env" "${evidence}/release.env"
  [ ! -s "${trace}" ]
}

prepare_with_lifecycle_status() {
  local result=0
  foundation_prepare_execution_mode "${consumer}" "${evidence}" || result=$?
  printf 'prepared=%s\n' "${ROBOTICS_RELEASE_IMAGES_PREPARED}"
  return "${result}"
}

@test "core readiness is reset and marked only after every selected image succeeds" {
  ROBOTICS_RELEASE_IMAGES_PREPARED=1 GH_IMAGE_STATUS=42
  run --separate-stderr prepare_with_lifecycle_status
  [ "${status}" -eq 42 ]
  [[ "${output}" == *'prepared=' ]]
  unset GH_IMAGE_STATUS
  evidence="${BATS_TEST_TMPDIR}/failed-pull"
  DOCKER_PULL_STATUS=43
  run --separate-stderr prepare_with_lifecycle_status
  [ "${status}" -eq 43 ]
  [[ "${output}" == *'prepared=' ]]
  unset DOCKER_PULL_STATUS
  evidence="${BATS_TEST_TMPDIR}/complete"
  run --separate-stderr prepare_with_lifecycle_status
  [ "${status}" -eq 0 ]
  [ "${output}" = prepared=1 ]
}

prepare_optional_upstream() {
  foundation_prepare_execution_mode "${consumer}" "${evidence}" || return
  foundation_prepare_released_image "${EDGE_ATTACH_DATA_PLANE_IMAGE}" || return
  foundation_prepare_released_image "${EDGE_ATTACH_DATA_PLANE_IMAGE}" || return
  printf '%s\n' "${#FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS[@]}"
}

@test "optional fixed upstream pause has local identity without internal build attestation" {
  run --separate-stderr prepare_optional_upstream
  [ "${status}" -eq 0 ]
  [ "${output}" = 28 ]
  [ "$(grep -c '^docker pull ' "${trace}")" -eq 6 ]
  [ "$(grep -c '^gh attestation ' "${trace}")" -eq 4 ]
  [ "$(find "${evidence}/images" -name '*.identity.json' | wc -l)" -eq 6 ]
}

verify_lock_guard() {
  local mode="$1" marker="$2" shims="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${shims}"
  cat >"${shims}/docker" <<'SH'
#!/usr/bin/env bash
printf 'Docker executed\n' >>"${FIXTURE_DOCKER_TRACE}"
SH
  chmod +x "${shims}/docker"
  env PATH="${shims}:${PATH}" FIXTURE_DOCKER_TRACE="${trace}" \
    ROBOTICS_RUNTIME_MODE="${mode}" ROBOTICS_RELEASE_IMAGES_PREPARED="${marker}" \
    bash "${REPOSITORY_ROOT}/scripts/ci/foundation/verify-image-lock.sh"
}

@test "embedded image-lock verifier refuses unknown execution mode before Docker" {
  run verify_lock_guard unknown 1
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"unsupported runtime mode"* ]]
  [ ! -s "${trace}" ]
}

@test "embedded image-lock verifier requires completed released preparation before Docker" {
  run verify_lock_guard released ''
  [ "${status}" -eq 65 ]
  [[ "${output}" == *"requires completed provenance preparation"* ]]
  [ ! -s "${trace}" ]
}
