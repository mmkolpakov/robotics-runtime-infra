#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

runtime_images="$(ci_bake_target_images cpu)"

mkdir -p artifacts/runtime
docker compose logs --no-color > artifacts/runtime/compose.log 2>&1 || true
while IFS=$'\t' read -r _ image; do
  safe_name="$(tr '/:' '__' <<<"${image}")"
  if ! docker image inspect "${image}" \
    >"artifacts/runtime/${safe_name}.json"; then
    rm -f "artifacts/runtime/${safe_name}.json"
    printf '%s\n' "${image}" >>artifacts/runtime/missing-images.txt
  fi
done <<<"${runtime_images}"
