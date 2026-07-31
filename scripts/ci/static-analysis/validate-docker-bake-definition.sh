#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

bake=(docker buildx bake --file docker-bake.hcl)

mapfile -t bake_targets < <(
  "${bake[@]}" --list=type=targets,format=json |
    jq -er '.[].name'
)
((${#bake_targets[@]} > 0))
"${bake[@]}" --check "${bake_targets[@]}"
