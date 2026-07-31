#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

test "$#" -ge 1 || {
  printf 'usage: scan-bake-group.sh BAKE_GROUP [PLATFORM [BAKE_OPTION...]]\n' >&2
  exit 64
}

group="$1"
shift
platform="${1:-}"
[[ "${group}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
if test -n "${platform}"; then
  [[ "${platform}" =~ ^linux/(amd64|arm64)$ ]]
  shift
fi
bake_options=("$@")

targets="$(ci_bake_target_images "${group}")"

loaded_image=
cleanup() {
  if test -n "${loaded_image}"; then
    docker image rm --force "${loaded_image}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT HUP INT TERM

while IFS=$'\t' read -r target image; do
  if test -n "${platform}"; then
    docker buildx bake --file docker-bake.hcl "${target}" \
      --load \
      --set "*.platform=${platform}" \
      "${bake_options[@]}"
    loaded_image="${image}"
  fi
  repository="${image%@*}"
  repository="${repository%:*}"
  report_id="${group}-$(basename -- "${repository}")"
  scan_args=("${image}" "${report_id}")
  if test -n "${platform}"; then
    scan_args+=("${platform}")
  fi
  scripts/ci/security/scan-image.sh "${scan_args[@]}"
  if test -n "${loaded_image}"; then
    docker image rm --force "${loaded_image}" >/dev/null
    loaded_image=
  fi
done <<<"${targets}"
