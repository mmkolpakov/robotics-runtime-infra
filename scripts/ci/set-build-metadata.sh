#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${root}"

: "${GITHUB_ENV:?GITHUB_ENV must identify the GitHub Actions environment file}"
{
  printf 'IMAGE_CREATED=%s\n' "$(git show --no-patch --format=%cI HEAD)"
  printf 'SOURCE_DATE_EPOCH=%s\n' "$(git show --no-patch --format=%ct HEAD)"
  printf 'VCS_REF=%s\n' "$(git rev-parse HEAD)"
} >>"${GITHUB_ENV}"
