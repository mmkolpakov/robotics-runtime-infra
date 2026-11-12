#!/usr/bin/env bash
set -Eeuo pipefail

# Scan the published release digests with the reviewed Trivy and OpenVEX
# policy. Used by the nightly and post-merge security gate; it never rebuilds
# an image and never accepts a mutable tag.

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

test "$#" -eq 2 || {
  printf 'usage: scan-published-release.sh RELEASE_ENV DIGESTS_DIR\n' >&2
  exit 64
}

release_env="$1"
digests_dir="$2"
test -f "${release_env}"
test -d "${digests_dir}"

: "${TRIVY_IMAGE:?TRIVY_IMAGE is required}"

# The published platform set comes from the release group of the bake
# definition; the release gate itself verifies every candidate platform.
bake_plan="$(docker buildx bake --file docker-bake.hcl --print release)"

failed=()
while IFS='=' read -r variable reference; do
  case "${variable}" in
    *_IMAGE) ;;
    *) continue ;;
  esac
  if [[ ! "${reference}" =~ @sha256:[a-f0-9]{64}$ ]]; then
    printf 'unpinned published reference: %s\n' "${reference}" >&2
    exit 65
  fi
  id="$(basename -- "${reference%%@*}")"
  id="${id%%:*}"
  if [[ "${reference}" == ghcr.io/*/robotics-runtime-infra/* ]]; then
    if ! grep -Fxq "${reference}" "${digests_dir}/${id}.txt"; then
      printf 'digest record does not match the release lock: %s\n' "${id}" >&2
      exit 65
    fi
    platforms="$(jq -er --arg id "${id}" '.target[$id].platforms | join(",")' <<<"${bake_plan}")" || {
      printf 'published image is not in the release group: %s\n' "${id}" >&2
      exit 65
    }
  else
    platforms="linux/amd64,linux/arm64"
  fi
  if ! scripts/ci/security/scan-image.sh "${reference}" "published-${id}" "${platforms}"; then
    failed+=("${reference}")
  fi
done <"${release_env}"

if test "${#failed[@]}" -gt 0; then
  printf 'published image security gate failed for %s\n' "${failed[@]}" >&2
  exit 1
fi
