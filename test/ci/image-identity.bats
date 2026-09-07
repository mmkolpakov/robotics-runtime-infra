#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  # shellcheck source=scripts/ci/image-identity.sh
  source "${REPOSITORY_ROOT}/scripts/ci/image-identity.sh"
  MANIFEST="sha256:$(printf '%064d' 1)"
  OTHER="sha256:$(printf '%064d' 2)"
  CONFIG="sha256:$(printf '%064d' 9)"
  export INSPECT_FILE="${BATS_TEST_TMPDIR}/inspect.json"
  export INSPECT_CALLS="${BATS_TEST_TMPDIR}/inspect.calls"
  export INSPECT_STATUS=0
  fixture "registry.example:5000/team/image@${MANIFEST}"
}

fixture() {
  jq -n --arg config "${CONFIG}" --args \
    '[{Id: $config, RepoTags: [], RepoDigests: $ARGS.positional}]' \
    "$@" >"${INSPECT_FILE}"
}

docker() {
  [[ "$#" == 3 && "$1 $2" == 'image inspect' ]] || return 64
  printf '%s\n' "$3" >>"${INSPECT_CALLS}"
  [[ "${INSPECT_STATUS}" == 0 ]] || return "${INSPECT_STATUS}"
  cat "${INSPECT_FILE}"
}

@test "registry identity does not change when only Docker config ID changes" {
  first="$(ci_image_identity registry.example:5000/team/image:v1 source)"
  CONFIG="${OTHER}"
  fixture "registry.example:5000/team/image@${MANIFEST}"
  second="$(ci_image_identity registry.example:5000/team/image:v1 source)"
  [ "$(jq -r '.digest' <<<"${first}")" = "${MANIFEST}" ]
  [ "$(jq -c 'del(.config_digest)' <<<"${first}")" = \
    "$(jq -c 'del(.config_digest)' <<<"${second}")" ]
  [ "$(jq -r '.config_digest' <<<"${first}")" != \
    "$(jq -r '.config_digest' <<<"${second}")" ]
}

@test "released tag plus digest is preserved exactly once" {
  reference="registry.example:5000/team/image:v1@${MANIFEST}"
  identity="$(ci_image_identity "${reference}" released)"
  [ "$(cat "${INSPECT_CALLS}")" = "${reference}" ]
  jq -e --arg reference "${reference}" --arg digest "${MANIFEST}" \
    '.reference == $reference and .digest == $digest and .kind == "registry"
     and (.reference | split("@") | length) == 2' <<<"${identity}"
}

@test "unpinned tags prefer their repository over an unrelated first entry" {
  fixture "aaa.example/unrelated@${OTHER}" "registry.example:5000/team/image@${MANIFEST}"
  identity="$(ci_image_identity registry.example:5000/team/image:v1 source)"
  [ "$(jq -r '.reference' <<<"${identity}")" = \
    "registry.example:5000/team/image:v1@${MANIFEST}" ]
}

@test "an untagged repository keeps its registry port" {
  identity="$(ci_image_identity registry.example:5000/team/image source)"
  [ "$(jq -r '.reference' <<<"${identity}")" = \
    "registry.example:5000/team/image@${MANIFEST}" ]
}

@test "multiple matching RepoDigests select stably regardless of inspection order" {
  fixture "registry.example:5000/team/image@${OTHER}" "registry.example:5000/team/image@${MANIFEST}"
  first="$(ci_image_identity registry.example:5000/team/image:v1 source)"
  fixture "registry.example:5000/team/image@${MANIFEST}" "registry.example:5000/team/image@${OTHER}"
  second="$(ci_image_identity registry.example:5000/team/image:v1 source)"
  [ "${first}" = "${second}" ]
  [ "$(jq -r '.digest' <<<"${first}")" = "${MANIFEST}" ]
}

@test "a local tag alias records a stable actual RepoDigest" {
  fixture "zzz.example/image@${OTHER}" "aaa.example/image@${MANIFEST}"
  first="$(ci_image_identity local/alias:dev source)"
  fixture "aaa.example/image@${MANIFEST}" "zzz.example/image@${OTHER}"
  second="$(ci_image_identity local/alias:dev source)"
  [ "${first}" = "${second}" ]
  [ "$(jq -r '.reference' <<<"${first}")" = "aaa.example/image@${MANIFEST}" ]
}

@test "Docker Hub familiar names match canonical RepoDigests" {
  fixture "aaa.example/unrelated@${OTHER}" "docker.io/library/alpine@${MANIFEST}"
  for name in alpine:latest docker.io/alpine:latest index.docker.io/library/alpine:latest; do
    identity="$(ci_image_identity "${name}" source)"
    [ "$(jq -r '.reference' <<<"${identity}")" = "${name}@${MANIFEST}" ]
  done
}

@test "pinned identity selects the requested digest even under a repository alias" {
  fixture "registry.example:5000/team/image@${OTHER}" "mirror.example/team/image@${MANIFEST}"
  identity="$(ci_image_identity "registry.example:5000/team/image:v1@${MANIFEST}" released)"
  [ "$(jq -r '.digest' <<<"${identity}")" = "${MANIFEST}" ]
}

@test "pinned mismatch fails even when the requested digest equals the config ID" {
  for mode in released source; do
    run ci_image_identity "registry.example:5000/team/image:v1@${CONFIG}" "${mode}"
    [ "${status}" -eq 65 ]
    [[ "${output}" == *'absent from inspected RepoDigests'* ]]
  done
}

@test "released identity fails without RepoDigests and never falls back to Id" {
  fixture
  run ci_image_identity "registry.example:5000/team/image:v1@${CONFIG}" released
  [ "${status}" -eq 65 ]
  [[ "${output}" == *'absent from inspected RepoDigests'* ]]
}

@test "released tags require a requested digest" {
  run ci_image_identity registry.example:5000/team/image:v1 released
  [ "${status}" -eq 65 ]
  [ ! -e "${INSPECT_CALLS}" ]
}

@test "source-only config identity is explicit and retains emitter compatibility" {
  fixture
  identity="$(ci_image_identity local/image:dev source 2>"${BATS_TEST_TMPDIR}/warning")"
  jq -e --arg config "${CONFIG}" '
    .kind == "local-config" and .digest == $config and .config_digest == $config
    and .reference == ("local-config/image@" + $config)
    and (.reference | endswith("@" + $config))
  ' <<<"${identity}"
  [[ "$(cat "${BATS_TEST_TMPDIR}/warning")" == *'not verified registry identity'* ]]
}

@test "source images with absent or null RepoDigests retain the explicit fallback" {
  for value in '[{Id: $config}]' '[{Id: $config, RepoDigests: null}]'; do
    jq -n --arg config "${CONFIG}" "${value}" >"${INSPECT_FILE}"
    run ci_image_identity local/image:dev source
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"kind":"local-config"'* ]]
  done
}

@test "a pin never enables the source fallback when RepoDigests are absent" {
  fixture
  run ci_image_identity "local/image@${CONFIG}" source
  [ "${status}" -eq 65 ]
}

@test "doubled at signs and malformed digest pins fail before Docker inspection" {
  for reference in "image:v1@${MANIFEST}@${CONFIG}" 'image:v1@sha256:bad' \
    "@${MANIFEST}" 'image@' "image@@${MANIFEST}"; do
    run ci_image_identity "${reference}" source
    [ "${status}" -eq 65 ]
    [[ "${output}" == *'malformed digest-pinned image reference'* ]]
  done
  [ ! -e "${INSPECT_CALLS}" ]
}

@test "Docker validates repository syntax and inspection failures propagate" {
  INSPECT_STATUS=42
  run ci_image_identity 'INVALID repository:v1' source
  [ "${status}" -eq 42 ]
  [ "$(cat "${INSPECT_CALLS}")" = 'INVALID repository:v1' ]
  [ -z "${output}" ]
}

@test "empty malformed and multiple inspection documents fail closed" {
  for payload in '' '{}' '[]' 'null' 'invalid' '[{},{}]' \
    '[{"Id":"bad","RepoDigests":[]}]'; do
    printf '%s\n' "${payload}" >"${INSPECT_FILE}"
    run ci_image_identity local/image:dev source
    [ "${status}" -eq 65 ]
  done
  fixture
  cat "${INSPECT_FILE}" "${INSPECT_FILE}" >"${BATS_TEST_TMPDIR}/two.json"
  cp "${BATS_TEST_TMPDIR}/two.json" "${INSPECT_FILE}"
  run ci_image_identity local/image:dev source
  [ "${status}" -eq 65 ]
}

@test "malformed RepoDigests cannot become source fallback or registry evidence" {
  for digests in 'false' '{}' '[null]' '["image@bad"]' '["image@sha256:bad@sha256:bad"]'; do
    jq -n --arg config "${CONFIG}" --argjson digests "${digests}" \
      '[{Id: $config, RepoDigests: $digests}]' >"${INSPECT_FILE}"
    run ci_image_identity local/image:dev source
    [ "${status}" -eq 65 ]
  done
}

@test "unknown runtime modes fail closed" {
  run ci_image_identity local/image:dev relased
  [ "${status}" -eq 64 ]
  [ ! -e "${INSPECT_CALLS}" ]
}

@test "physical runtime manifest preserves a released pin and records the registry digest" {
  export -f docker
  run bash -ceu '
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1/scripts/ci/physical-attach.sh"
    work_root="$2"
    ROBOTICS_RUNTIME_MODE=released
    OBSERVER_IMAGE="registry.example:5000/team/image:v1@$3"
    printf "%064d\n" 3 >"${work_root}/target-identity.sha256"
    cp "${PHYSICAL_ATTACH_FIXTURE_ROOT}/target-evidence.json" "${work_root}/target-evidence.json"
    write_runtime_manifest_input
    jq -e --arg digest "$3" --arg reference "${OBSERVER_IMAGE}" \
      ".oci_image.digest == \$digest and .oci_image.reference == \$reference" \
      "${work_root}/runtime/runtime-manifest.input.json"
  ' _ "${REPOSITORY_ROOT}" "${BATS_TEST_TMPDIR}" "${MANIFEST}"
  [ "${status}" -eq 0 ]
}

@test "physical runtime manifest keeps source-only config identity visibly local" {
  fixture
  export -f docker
  run bash -ceu '
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1/scripts/ci/physical-attach.sh"
    work_root="$2"
    ROBOTICS_RUNTIME_MODE=source
    OBSERVER_IMAGE=local/image:dev
    printf "%064d\n" 3 >"${work_root}/target-identity.sha256"
    cp "${PHYSICAL_ATTACH_FIXTURE_ROOT}/target-evidence.json" "${work_root}/target-evidence.json"
    write_runtime_manifest_input
    jq -e --arg config "$3" \
      ".oci_image.digest == \$config and .oci_image.reference == (\"local-config/image@\" + \$config)" \
      "${work_root}/runtime/runtime-manifest.input.json"
  ' _ "${REPOSITORY_ROOT}" "${BATS_TEST_TMPDIR}" "${CONFIG}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'not verified registry identity'* ]]
}

@test "physical permit mismatch returns failure even when called in a conditional" {
  export -f docker
  run bash -ceu '
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1/scripts/ci/physical-attach.sh"
    work_root="$2"
    ROBOTICS_RUNTIME_MODE=released
    OBSERVER_IMAGE="registry.example:5000/team/image:v1@$3"
    printf "%064d\n" 3 >"${work_root}/target-identity.sha256"
    scenario_manifest="${work_root}/scenario-inputs.manifest"
    printf "scenario-input\n" >"${scenario_manifest}"
    if write_permit_case "${work_root}/case" now later target; then
      exit 99
    else
      test "$?" -eq 65
    fi
    test ! -e "${work_root}/case/execution-permit.json"
    test ! -e "${work_root}/case/execution-request.json"
  ' _ "${REPOSITORY_ROOT}" "${BATS_TEST_TMPDIR}" "${CONFIG}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'absent from inspected RepoDigests'* ]]
}

@test "scenario input manifest retains the actual execution config identity" {
  run bash -ceu '
    set -o pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1/scripts/ci/physical-attach.sh"
    work_root="$2"
    scenario_manifest="${work_root}/scenario-inputs.manifest"
    ROBOTICS_RUNTIME_MODE=source
    ROBOTICS_TIME_EVIDENCE="${INSPECT_FILE}"
    ROBOTICS_TIME_EVIDENCE_WINDOW="${INSPECT_FILE}"
    ROBOTICS_TIME_EVIDENCE_RUN_ID=fixture-run
    git() {
      case "$3" in
        status) return 0 ;;
        rev-parse) printf "%040d\n" 1 ;;
        *) return 64 ;;
      esac
    }
    real_compose() { printf "local/image:dev\n"; }
    docker() {
      test "$#" -eq 5
      test "$1 $2" = "image inspect"
      test "$4" = --format
      test "$5" = "{{.Id}}"
      jq -er ".[0].Id" "${INSPECT_FILE}"
    }
    write_scenario_input_manifest
    grep -Fx "$(printf "image\t%s\tlocal/image:dev" "$3")" "${scenario_manifest}"
    docker() { return 42; }
    if write_scenario_input_manifest; then
      exit 99
    else
      test "$?" -eq 42
    fi
  ' _ "${REPOSITORY_ROOT}" "${BATS_TEST_TMPDIR}" "${CONFIG}"
  [ "${status}" -eq 0 ]
}
