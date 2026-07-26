#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

test "$#" -eq 1 || {
  printf 'usage: scan-bake-group.sh BAKE_GROUP\n' >&2
  exit 64
}

group="$1"
[[ "${group}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]

bake_plan="$(docker buildx bake --print "${group}")"
images_json="$(
  jq -ce '
    [.target[]?.tags[]?]
    | unique
    | if length > 0 then . else error("Bake group has no tagged images") end
  ' <<<"${bake_plan}"
)"
mapfile -t images < <(jq -r '.[]' <<<"${images_json}")

for image in "${images[@]}"; do
  repository="${image%@*}"
  repository="${repository%:*}"
  report_id="${group}-$(basename -- "${repository}")"
  scripts/ci/security/scan-image.sh "${image}" "${report_id}"
done
