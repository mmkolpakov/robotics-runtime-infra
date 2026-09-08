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
  export REMOTE_FILE="${BATS_TEST_TMPDIR}/remote.json"
  export REMOTE_CALLS="${BATS_TEST_TMPDIR}/remote.calls"
  export INSPECT_STATUS=0
  export REMOTE_STATUS=0
  fixture "registry.example:5000/team/image@${MANIFEST}"
  jq -n --arg digest "${MANIFEST}" '
    {digest: $digest, size: 1234, mediaType: "application/vnd.oci.image.manifest.v1+json"}
  ' >"${REMOTE_FILE}"
}

fixture() {
  jq -n --arg config "${CONFIG}" --args \
    '[{Id: $config, RepoTags: [], RepoDigests: $ARGS.positional}]' \
    "$@" >"${INSPECT_FILE}"
}

containerd_fixture() {
  # The local ID is the target descriptor, not the image config. RepoDigests
  # are synthesized for local tags whether or not they were ever published.
  jq -n --arg manifest "${MANIFEST}" --args '
    [{Id: $manifest,
      Descriptor: {digest: $manifest, mediaType: "application/vnd.oci.image.index.v1+json"},
      RepoTags: ["local/alias:dev"], RepoDigests: $ARGS.positional}]
  ' "$@" >"${INSPECT_FILE}"
}

docker() {
  if [[ "$#" == 3 && "$1 $2" == 'image inspect' ]]; then
    printf '%s\n' "$3" >>"${INSPECT_CALLS}"
    [[ "${INSPECT_STATUS}" == 0 ]] || return "${INSPECT_STATUS}"
    cat "${INSPECT_FILE}"
  elif [[ "$#" == 6 && "$1 $2 $3 $4" == 'buildx imagetools inspect --format' &&
    "$5" == '{{json .Manifest}}' ]]; then
    printf '%s\n' "$6" >>"${REMOTE_CALLS}"
    cat "${REMOTE_FILE}"
    return "${REMOTE_STATUS}"
  elif [[ "$1" == run && -n "${RUNTIME_CALLS:-}" ]]; then
    printf '%s\n' "$@" >"$RUNTIME_CALLS"
  else
    return 64
  fi
}

@test "released registry identity is stable across classic and containerd image stores" {
  first="$(ci_image_identity "registry.example:5000/team/image:v1@${MANIFEST}" released)"
  containerd_fixture "registry.example:5000/team/image@${MANIFEST}"
  second="$(ci_image_identity "registry.example:5000/team/image:v1@${MANIFEST}" released)"
  [ "$(jq -r '.digest' <<<"${first}")" = "${MANIFEST}" ]
  [ "$(jq -c 'del(.local_image_id)' <<<"${first}")" = \
    "$(jq -c 'del(.local_image_id)' <<<"${second}")" ]
  [ "$(jq -r '.local_image_id' <<<"${first}")" = "${CONFIG}" ]
  [ "$(jq -r '.local_image_id' <<<"${second}")" = "${MANIFEST}" ]
  jq -e 'has("config_digest") | not' <<<"${first}"
  jq -e 'has("config_digest") | not' <<<"${second}"
}

@test "released tag plus digest is preserved exactly once" {
  reference="registry.example:5000/team/image:v1@${MANIFEST}"
  identity="$(ci_image_identity "${reference}" released)"
  [ "$(cat "${INSPECT_CALLS}")" = "${reference}" ]
  [ "$(cat "${REMOTE_CALLS}")" = "${reference}" ]
  jq -e --arg reference "${reference}" --arg digest "${MANIFEST}" \
    '.reference == $reference and .digest == $digest and .kind == "registry"
     and (.reference | split("@") | length) == 2' <<<"${identity}"
}

@test "unpinned source tags remain local even with matching and unrelated RepoDigests" {
  fixture "aaa.example/unrelated@${OTHER}" "registry.example:5000/team/image@${MANIFEST}"
  identity="$(ci_image_identity registry.example:5000/team/image:v1 source)"
  [ "$(jq -r '.reference' <<<"${identity}")" = \
    "local-image/image@${CONFIG}" ]
  [ ! -e "${REMOTE_CALLS}" ]
}

@test "a pin without a tag keeps its registry port in the remote lookup" {
  identity="$(ci_image_identity "registry.example:5000/team/image@${MANIFEST}" released)"
  [ "$(jq -r '.reference' <<<"${identity}")" = \
    "registry.example:5000/team/image@${MANIFEST}" ]
  [ "$(cat "${REMOTE_CALLS}")" = "registry.example:5000/team/image@${MANIFEST}" ]
}

@test "source identity is independent of matching RepoDigest order" {
  fixture "registry.example:5000/team/image@${OTHER}" "registry.example:5000/team/image@${MANIFEST}"
  first="$(ci_image_identity registry.example:5000/team/image:v1 source)"
  fixture "registry.example:5000/team/image@${MANIFEST}" "registry.example:5000/team/image@${OTHER}"
  second="$(ci_image_identity registry.example:5000/team/image:v1 source)"
  [ "${first}" = "${second}" ]
  [ "$(jq -r '.digest' <<<"${first}")" = "${CONFIG}" ]
}

@test "containerd local aliases never promote synthesized RepoDigests to registry identity" {
  containerd_fixture "local/alias@${MANIFEST}" "aaa.example/image@${MANIFEST}"
  first="$(ci_image_identity local/alias:dev source)"
  containerd_fixture "aaa.example/image@${MANIFEST}" "local/alias@${MANIFEST}"
  second="$(ci_image_identity local/alias:dev source)"
  [ "${first}" = "${second}" ]
  jq -e --arg id "${MANIFEST}" '
    .reference == ("local-image/image@" + $id) and .kind == "local-image-id"
    and .local_image_id == $id and (has("config_digest") | not)
  ' <<<"${first}"
  [ ! -e "${REMOTE_CALLS}" ]
}

@test "Docker Hub familiar pins are checked remotely without rewriting the reference" {
  fixture "aaa.example/unrelated@${OTHER}" "docker.io/library/alpine@${MANIFEST}"
  for name in alpine:latest docker.io/alpine:latest index.docker.io/library/alpine:latest; do
    identity="$(ci_image_identity "${name}@${MANIFEST}" released)"
    [ "$(jq -r '.reference' <<<"${identity}")" = "${name}@${MANIFEST}" ]
  done
}

@test "a local repository alias still requires remote verification of the requested repository" {
  fixture "registry.example:5000/team/image@${OTHER}" "mirror.example/team/image@${MANIFEST}"
  identity="$(ci_image_identity "registry.example:5000/team/image:v1@${MANIFEST}" released)"
  [ "$(jq -r '.digest' <<<"${identity}")" = "${MANIFEST}" ]
  [ "$(cat "${REMOTE_CALLS}")" = "registry.example:5000/team/image:v1@${MANIFEST}" ]
}

@test "pinned mismatch fails even when the requested digest equals the config ID" {
  for mode in released source; do
    run ci_image_identity "registry.example:5000/team/image:v1@${CONFIG}" "${mode}"
    [ "${status}" -eq 65 ]
    [[ "${output}" == *'absent from inspected RepoDigests'* ]]
  done
  [ ! -e "${REMOTE_CALLS}" ]
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

@test "source-only local image identity is explicit and retains emitter compatibility" {
  fixture
  identity="$(ci_image_identity local/image:dev source 2>"${BATS_TEST_TMPDIR}/warning")"
  jq -e --arg config "${CONFIG}" '
    .kind == "local-image-id" and .digest == $config and .local_image_id == $config
    and (has("config_digest") | not)
    and .reference == ("local-image/image@" + $config)
    and (.reference | endswith("@" + $config))
  ' <<<"${identity}"
  [[ "$(cat "${BATS_TEST_TMPDIR}/warning")" == *'not verified registry identity'* ]]
}

@test "source images with absent or null RepoDigests retain the explicit fallback" {
  for value in '[{Id: $config}]' '[{Id: $config, RepoDigests: null}]'; do
    jq -n --arg config "${CONFIG}" "${value}" >"${INSPECT_FILE}"
    run ci_image_identity local/image:dev source
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"kind":"local-image-id"'* ]]
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

@test "containerd without Descriptor is still an opaque local ID and needs no registry" {
  CONFIG="${MANIFEST}"
  fixture "local/alias@${MANIFEST}"
  REMOTE_STATUS=127
  identity="$(ci_image_identity local/alias:dev source)"
  jq -e --arg id "${MANIFEST}" '
    .kind == "local-image-id" and .digest == $id and .local_image_id == $id
    and (has("config_digest") | not)
  ' <<<"${identity}"
  [ ! -e "${REMOTE_CALLS}" ]
}

@test "unpublished containerd pins fail when remote lookup fails in either mode" {
  containerd_fixture "local/alias@${MANIFEST}"
  for mode in released source; do
    for REMOTE_STATUS in 44 69 77 127; do
      # Even a valid descriptor printed before a failure cannot produce identity.
      identity_status=0
      identity="$(ci_image_identity "local/alias@${MANIFEST}" "${mode}")" || identity_status=$?
      [ "${identity_status}" -eq "${REMOTE_STATUS}" ]
      [ -z "${identity}" ]
    done
  done
  [ "$(sort -u "${REMOTE_CALLS}")" = "local/alias@${MANIFEST}" ]
}

@test "a matching local digest cannot override a different remote digest" {
  containerd_fixture "local/alias@${MANIFEST}"
  jq -n --arg digest "${OTHER}" '
    {digest: $digest, mediaType: "application/vnd.oci.image.index.v1+json"}
  ' >"${REMOTE_FILE}"
  for mode in released source; do
    run ci_image_identity "local/alias@${MANIFEST}" "${mode}"
    [ "${status}" -eq 65 ]
    [[ "${output}" == *'registry manifest does not match'* ]]
    [[ "${output}" != *'"kind"'* ]]
  done
}

@test "empty malformed or multiple remote descriptors fail closed" {
  for payload in '' 'null' '{}' '[]' 'false' '"text"' 'not-json'; do
    printf '%s\n' "${payload}" >"${REMOTE_FILE}"
    run ci_image_identity "registry.example:5000/team/image@${MANIFEST}" released
    [ "${status}" -eq 65 ]
    [[ "${output}" != *'"kind"'* ]]
  done
  jq -n --arg digest "${MANIFEST}" '
    {digest: $digest, mediaType: "application/vnd.oci.image.manifest.v1+json"} | ., .
  ' >"${REMOTE_FILE}"
  run ci_image_identity "registry.example:5000/team/image@${MANIFEST}" released
  [ "${status}" -eq 65 ]
}

@test "remote descriptor must be an OCI or Docker image manifest or index" {
  for media_type in '' 'application/vnd.oci.image.config.v1+json' 'application/json'; do
    jq -n --arg digest "${MANIFEST}" --arg media_type "${media_type}" '
      {digest: $digest, mediaType: $media_type}
    ' >"${REMOTE_FILE}"
    run ci_image_identity "registry.example:5000/team/image@${MANIFEST}" released
    [ "${status}" -eq 65 ]
  done
}

@test "remote verification accepts both supported single and multi-platform media types" {
  containerd_fixture "registry.example:5000/team/image@${MANIFEST}"
  for media_type in \
    application/vnd.oci.image.manifest.v1+json \
    application/vnd.oci.image.index.v1+json \
    application/vnd.docker.distribution.manifest.v2+json \
    application/vnd.docker.distribution.manifest.list.v2+json; do
    jq -n --arg digest "${MANIFEST}" --arg media_type "${media_type}" '
      {digest: $digest, mediaType: $media_type, size: 1234}
    ' >"${REMOTE_FILE}"
    identity="$(ci_image_identity "registry.example:5000/team/image@${MANIFEST}" released)"
    jq -e --arg digest "${MANIFEST}" '
      .digest == $digest and .kind == "registry" and (has("config_digest") | not)
    ' <<<"${identity}"
  done
}

@test "verified source pins retain the requested registry identity" {
  identity="$(ci_image_identity "registry.example:5000/team/image:v1@${MANIFEST}" source)"
  jq -e --arg digest "${MANIFEST}" '
    .digest == $digest and .kind == "registry" and (has("config_digest") | not)
  ' <<<"${identity}"
  [ "$(cat "${REMOTE_CALLS}")" = "registry.example:5000/team/image:v1@${MANIFEST}" ]
}

@test "physical runtime writer receives the released reference and registry digest" {
  export -f docker
  run bash -ceu '
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1/scripts/ci/physical-attach.sh"
    work_root="$2"
    ROBOTICS_RUNTIME_MODE=released
    OBSERVER_IMAGE="registry.example:5000/team/image:v1@$3"
    RUNTIME_CALLS="$2/runtime.calls"
    identity="$(ci_image_identity "$OBSERVER_IMAGE" "$ROBOTICS_RUNTIME_MODE")"
    run_runtime_manifest_writer "$work_root/runtime" "$identity"
    test "$(sed -n "/^--subject-digest\$/ {n;p;}" "$RUNTIME_CALLS")" = "$3"
    test "$(sed -n "/^--subject-reference\$/ {n;p;}" "$RUNTIME_CALLS")" = "$OBSERVER_IMAGE"
  ' _ "${REPOSITORY_ROOT}" "${BATS_TEST_TMPDIR}" "${MANIFEST}"
  [ "${status}" -eq 0 ]
}

@test "physical runtime writer keeps source-only image identity visibly local" {
  fixture
  export -f docker
  run bash -ceu '
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1/scripts/ci/physical-attach.sh"
    work_root="$2"
    ROBOTICS_RUNTIME_MODE=source
    OBSERVER_IMAGE=local/image:dev
    RUNTIME_CALLS="$2/runtime.calls"
    identity="$(ci_image_identity "$OBSERVER_IMAGE" "$ROBOTICS_RUNTIME_MODE")"
    run_runtime_manifest_writer "$work_root/runtime" "$identity"
    test "$(sed -n "/^--subject-digest\$/ {n;p;}" "$RUNTIME_CALLS")" = "$3"
    test "$(sed -n "/^--subject-reference\$/ {n;p;}" "$RUNTIME_CALLS")" = "local-image/image@$3"
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

@test "remote failure prevents physical permit and runtime output even in conditionals" {
  export REMOTE_STATUS=42
  export -f docker
  run bash -ceu '
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1/scripts/ci/physical-attach.sh"
    work_root="$2"
    ROBOTICS_RUNTIME_MODE=released
    OBSERVER_IMAGE="registry.example:5000/team/image:v1@$3"
    printf "%064d\n" 3 >"${work_root}/target-identity.sha256"
    cp "${PHYSICAL_ATTACH_FIXTURE_ROOT}/target-evidence.json" "${work_root}/target-evidence.json"
    scenario_manifest="${work_root}/scenario-inputs.manifest"
    printf "scenario-input\n" >"${scenario_manifest}"
    if write_permit_case "${work_root}/case" now later target; then
      exit 99
    else
      test "$?" -eq 42
    fi
    if write_runtime_manifest_input; then
      exit 99
    else
      test "$?" -eq 42
    fi
    test ! -e "${work_root}/case/execution-permit.json"
    test ! -e "${work_root}/case/execution-request.json"
    test ! -e "${work_root}/runtime/runtime-manifest.input.json"
  ' _ "${REPOSITORY_ROOT}" "${BATS_TEST_TMPDIR}" "${MANIFEST}"
  [ "${status}" -eq 0 ]
}

@test "scenario input manifest retains the Docker local image ID" {
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
