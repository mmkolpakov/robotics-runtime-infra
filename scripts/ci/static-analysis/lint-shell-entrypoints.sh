#!/usr/bin/env bash
set -Eeuo pipefail

mapfile -d '' ci_scripts < <(
  find scripts/ci -type f -name '*.sh' -print0
)
mapfile -d '' qualification_scripts < <(
  find scripts/qualification -type f -print0
)

docker run --rm --volume "${PWD}:/work:ro" --workdir /work \
  "${SHELLCHECK_IMAGE}" \
  docker/entrypoint.sh \
  docker/apt/use-package-snapshots \
  docker/apt/update-rosdep-cache \
  docker/evidence-sink/evidence-sink \
  docker/permit-preflight/permit-preflight \
  docker/runtime/emit-runtime-manifest \
  test/zenoh/run \
  "${qualification_scripts[@]}" \
  "${ci_scripts[@]}"
