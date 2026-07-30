#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"

mkdir -p artifacts dependencies
uvx --from vcs2l==1.1.7 vcs validate --input foundation.repos
uvx --from vcs2l==1.1.7 vcs import --input foundation.repos dependencies
uvx --from vcs2l==1.1.7 vcs export --exact --lint dependencies \
  > artifacts/foundation.resolved.repos
