#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

test "$#" -ge 2 || {
  printf 'usage: scan-image.sh IMAGE REPORT_ID [PLATFORM_OR_CSV...]\n' >&2
  exit 64
}

image="$1"
report_id="$2"
shift 2
platform_inputs=("$@")
platforms=()

: "${TRIVY_IMAGE:?TRIVY_IMAGE is required}"
[[ "${report_id}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
if test "${#platform_inputs[@]}" -eq 0; then
  platforms=("")
else
  for platform_input in "${platform_inputs[@]}"; do
    IFS=',' read -r -a parsed_platforms <<<"${platform_input}"
    test "${#parsed_platforms[@]}" -gt 0
    for platform in "${parsed_platforms[@]}"; do
      test -n "${platform}"
      platforms+=("${platform}")
    done
  done
fi

security_artifact_dir="${ROBOTICS_CI_SECURITY_ARTIFACT_DIR:-${PWD}/artifacts/security}"
trivy_cache_dir="${ROBOTICS_CI_TRIVY_CACHE_DIR:-${PWD}/.trivy-cache}"
mkdir -p "${security_artifact_dir}" "${trivy_cache_dir}"

priority_args=()
if test -n "${ROBOTICS_CI_TRIVY_DETECTION_PRIORITY:-}"; then
  if test "${ROBOTICS_CI_TRIVY_DETECTION_PRIORITY}" != comprehensive; then
    printf 'unsupported explicit Trivy detection priority\n' >&2
    exit 65
  fi
  priority_args=(--detection-priority comprehensive)
fi

vendor_mount=()
vendor_args=()
if test -n "${ROBOTICS_CI_VENDOR_VEX_DIR:-}"; then
  vendor_dir="$(realpath -- "${ROBOTICS_CI_VENDOR_VEX_DIR}")"
  artifact_root="$(realpath -- "${security_artifact_dir}")"
  case "${vendor_dir}" in
    "${artifact_root}"/*) ;;
    *) printf 'vendor VEX must be retained under the security artifact directory\n' >&2; exit 65 ;;
  esac
  test -f "${vendor_dir}/canonical-ubuntu.openvex.json"
  test -f "${vendor_dir}/provenance.json"
  (cd -- "${vendor_dir}" && sha256sum --strict --check SHA256SUMS)
  vendor_mount=(--volume "${vendor_dir}:/vendor-vex:ro")
  vendor_args=(--vex /vendor-vex/canonical-ubuntu.openvex.json)
fi

canonical_source_dir="${ROBOTICS_CI_CANONICAL_SOURCE_DIR:-}"
security_python="${ROBOTICS_CI_SECURITY_PYTHON:-}"
if test -n "${canonical_source_dir}"; then
  test -z "${ROBOTICS_CI_VENDOR_VEX_DIR:-}"
  test "${ROBOTICS_CI_TRIVY_DETECTION_PRIORITY:-}" = comprehensive
  test -x "${security_python}"
  "${security_python}" -c 'from importlib.metadata import version; assert version("packageurl-python") == "0.17.6"'
  canonical_source_dir="$(realpath -- "${canonical_source_dir}")"
  case "${canonical_source_dir}" in
    "$(realpath -- "${security_artifact_dir}")"/*) ;;
    *) printf 'Canonical sources must be retained with security artifacts\n' >&2; exit 65 ;;
  esac
fi

trivy_runner=(
  docker run --rm
  --volume /var/run/docker.sock:/var/run/docker.sock
  --volume "${HOME}/.docker:/root/.docker:ro"
  --volume "${PWD}:/work:ro"
  --volume "${security_artifact_dir}:/reports"
  --volume "${trivy_cache_dir}:/root/.cache/trivy"
  "${vendor_mount[@]}"
)
trivy_flags=(
  "${priority_args[@]}"
  --config /work/trivy.yaml
  --ignorefile /work/.trivyignore
  --vex /work/security/vex/linux-libc-dev.openvex.json
  --vex /work/security/vex/go-modules.openvex.json
  "${vendor_args[@]}"
  --show-suppressed
  --list-all-pkgs
)

trivy=("${trivy_runner[@]}" "${TRIVY_IMAGE}" image "${trivy_flags[@]}")

scan_with_canonical_vex() (
  capture="${security_artifact_dir}/${report_id}-${platform_id}-canonical"
  mkdir "${capture}"
  docker image inspect --format '{{json .}}' "${image}" |
    jq '{Id, Os, Architecture}' >"${capture}/image.json"
  image_id="$(jq -er '.Id | select(test("^sha256:[0-9a-f]{64}$"))' "${capture}/image.json")"
  arch="$(jq -er '.Architecture | select(. == "amd64" or . == "arm64")' "${capture}/image.json")"
  jq -e '.Os == "linux"' "${capture}/image.json" >/dev/null
  selected_platform="linux/${arch}"
  test -z "${platform}" || test "${platform}" = "${selected_platform}"
  original_report="${security_artifact_dir}/${report_id}-${platform_id}-raw.json"
  "${trivy[@]}" --image-src docker --platform "${selected_platform}" --format json \
    --output "/reports/${report_id}-${platform_id}-raw.json" "${image_id}"
  jq -e --arg id "${image_id}" --arg arch "${arch}" '
    .Metadata.ImageID == $id and .Metadata.ImageConfig.architecture == $arch
    and .Metadata.OS == {Family: "ubuntu", Name: "24.04"}
  ' "${original_report}" >/dev/null

  cid_file="${capture}/container.cid"
  container_removed=false
  cleanup_capture() {
    if test "${container_removed}" = false && test -s "${cid_file}"; then
      local captured_cid
      captured_cid="$(cat "${cid_file}")"
      [[ "${captured_cid}" =~ ^[0-9a-f]{64}$ ]] || return 1
      docker rm --volumes "${captured_cid}" >/dev/null
    fi
  }
  trap cleanup_capture EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  docker create --platform "${selected_platform}" --cidfile "${cid_file}" \
    --entrypoint /bin/true "${image_id}" >/dev/null
  cid="$(cat "${cid_file}")"
  [[ "${cid}" =~ ^[0-9a-f]{64}$ ]]
  for phase in before after; do
    docker container inspect --format '{{json .}}' "${cid}" |
      jq '{Id, Image, State: {Status: .State.Status, Running: .State.Running}}' \
      >"${capture}/container-${phase}.json"
    jq -e --arg id "${image_id}" --arg cid "${cid}" '
      .Id == $cid and .Image == $id
      and .State.Status == "created" and .State.Running == false
    ' "${capture}/container-${phase}.json" >/dev/null
    if test "${phase}" = before; then
      docker cp -L "${cid}:/etc/os-release" "${capture}/os-release"
      test -f "${capture}/os-release"
      test "$(wc -c <"${capture}/os-release")" -gt 0
      test "$(wc -c <"${capture}/os-release")" -le 32768
    fi
  done
  cleanup_capture
  container_removed=true
  package_purl="$(jq -er '
    [.Results[]?.Packages[]? | select(.Name == "linux-libc-dev") | .Identifier.PURL]
    | if length == 1 then .[0] else error("missing or ambiguous header package") end
  ' "${original_report}")"
  revision="$(jq -er .source_commit security/vex/canonical-source.json)"
  "${security_python}" scripts/ci/security/prepare-ubuntu-vex.py \
    --vendor-dir "${canonical_source_dir}" --source-commit "${revision}" \
    --scan-report "${original_report}" --os-release "${capture}/os-release" \
    --package-purl "${package_purl}" --output-dir "${capture}/vex"
  (cd "${capture}/vex" && sha256sum --strict --check SHA256SUMS)
  "${trivy_runner[@]}" --volume "$(realpath "${capture}/vex"):/canonical-vex:ro" \
    "${TRIVY_IMAGE}" image "${trivy_flags[@]}" \
    --vex /canonical-vex/canonical-ubuntu.openvex.json \
    --skip-db-update --skip-java-db-update --image-src docker \
    --platform "${selected_platform}" --format json --output "${raw_report}" "${image_id}"
  jq -e --arg id "${image_id}" --arg arch "${arch}" '
    .Metadata.ImageID == $id and .Metadata.ImageConfig.architecture == $arch
    and .Metadata.OS == {Family: "ubuntu", Name: "24.04"}
  ' "${security_artifact_dir}/${report_id}-${platform_id}.json" >/dev/null
)

failed=()
for platform in "${platforms[@]}"; do
  platform_args=()
  platform_id=local
  if test -n "${platform}"; then
    case "${platform}" in
      linux/amd64 | linux/arm64) ;;
      *)
        printf 'unsupported scan platform: %s\n' "${platform}" >&2
        exit 65
        ;;
    esac
    platform_args=(--platform "${platform}")
    platform_id="${platform//\//-}"
  fi
  raw_report="/reports/${report_id}-${platform_id}.json"
  if test -n "${canonical_source_dir}"; then
    scan_with_canonical_vex
  else
    "${trivy[@]}" \
      "${platform_args[@]}" \
      --format json \
      --output "${raw_report}" \
      "${image}"
  fi
  if ! docker run --rm \
    --volume "${security_artifact_dir}:/reports" \
    "${TRIVY_IMAGE}" convert \
    --format sarif \
    --output "/reports/${report_id}-${platform_id}.sarif" \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --exit-code 1 \
    "${raw_report}"; then
    failed+=("${image} ${platform_id}")
    # Print the blocking findings; the reports stay in the artifact.
    docker run --rm \
      --volume "${security_artifact_dir}:/reports" \
      "${TRIVY_IMAGE}" convert \
      --format table \
      --severity HIGH,CRITICAL \
      "${raw_report}" || true
  fi
done

if test "${#failed[@]}" -gt 0; then
  printf 'vulnerability gate failed: %s\n' "${failed[@]}" >&2
  exit 1
fi
