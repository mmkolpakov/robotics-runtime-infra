#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"

foundation_require_env SIMULATION_IMAGE OBSERVER_IMAGE

contracts_dir=dependencies/robotics-runtime-contracts
harness_dir=dependencies/robotics-acceptance-harness

contracts_revision="$(git -C "${contracts_dir}" rev-parse HEAD)"
harness_revision="$(git -C "${harness_dir}" rev-parse HEAD)"
contracts_tag="$(git -C "${contracts_dir}" describe --tags --exact-match)"
harness_tag="$(git -C "${harness_dir}" describe --tags --exact-match)"
for image in "${SIMULATION_IMAGE}" "${OBSERVER_IMAGE}"; do
  test "$(
    docker run --rm --entrypoint jq "${image}" \
      -er '.repositories["robotics-runtime-contracts"].version' \
      /usr/share/robotics-runtime/foundation-lock.json
  )" = "${contracts_revision}"
  test "$(
    docker run --rm --entrypoint jq "${image}" \
      -er '.repositories["robotics-acceptance-harness"].version' \
      /usr/share/robotics-runtime/foundation-lock.json
  )" = "${harness_revision}"
done
contracts_version="$(
  docker run --rm \
    --entrypoint /opt/venv/bin/python "${OBSERVER_IMAGE}" \
    -c 'from importlib.metadata import version; print(version("robotics-runtime-contracts"))'
)"
harness_version="$(
  docker run --rm \
    --entrypoint /opt/venv/bin/python "${OBSERVER_IMAGE}" \
    -c 'from importlib.metadata import version; print(version("robotics-acceptance-harness"))'
)"
test "${contracts_tag}" = "v${contracts_version}"
test "${harness_tag}" = "v${harness_version}"
