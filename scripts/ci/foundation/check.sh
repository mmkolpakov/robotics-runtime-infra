#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"

foundation_require_env SHELLCHECK_IMAGE
command -v bats >/dev/null

mapfile -t scripts < <(
  find scripts/ci/foundation -maxdepth 1 -type f -name '*.sh' -print \
    | LC_ALL=C sort
)
docker run --rm \
  --volume "${root}:/work:ro" \
  --workdir /work \
  "${SHELLCHECK_IMAGE}" \
  "${scripts[@]}"
bats test/ci/foundation*.bats
