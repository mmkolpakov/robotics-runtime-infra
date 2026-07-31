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

trivy=(
  docker run --rm
  --volume /var/run/docker.sock:/var/run/docker.sock
  --volume "${HOME}/.docker:/root/.docker:ro"
  --volume "${PWD}:/work:ro"
  --volume "${security_artifact_dir}:/reports"
  --volume "${trivy_cache_dir}:/root/.cache/trivy"
  "${TRIVY_IMAGE}" image
  --config /work/trivy.yaml
  --ignorefile /work/.trivyignore
  --vex /work/security/vex/linux-libc-dev.openvex.json
)

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
  "${trivy[@]}" \
    "${platform_args[@]}" \
    --format json \
    --output "${raw_report}" \
    "${image}"
  docker run --rm \
    --volume "${security_artifact_dir}:/reports" \
    "${TRIVY_IMAGE}" convert \
    --format sarif \
    --output "/reports/${report_id}-${platform_id}.sarif" \
    --severity HIGH,CRITICAL \
    --exit-code 1 \
    "${raw_report}"
done
