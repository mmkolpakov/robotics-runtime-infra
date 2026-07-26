#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"

vcs_ref="${GITHUB_SHA:-$(git rev-parse HEAD)}"
metadata="$(
  printf 'IMAGE_CREATED=%s\n' "$(git show --no-patch --format=%cI HEAD)"
  printf 'SOURCE_DATE_EPOCH=%s\n' "$(git show --no-patch --format=%ct HEAD)"
  printf 'VCS_REF=%s\n' "${vcs_ref}"
)"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf '%s\n' "${metadata}" >> "${GITHUB_ENV}"
else
  printf '%s\n' "${metadata}"
fi
