#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"

foundation_require_env SIMULATION_IMAGE OBSERVER_IMAGE

workspace_dir=dependencies/robotics-runtime
workspace_revision="$(git -C "${workspace_dir}" rev-parse HEAD)"
python3 scripts/ci/foundation/sync-workspace-pins.py --check
for image in "${SIMULATION_IMAGE}" "${OBSERVER_IMAGE}"; do
  test "$(
    docker run --rm --entrypoint jq "${image}" \
      -er '.repositories["robotics-runtime"].version' \
      /usr/share/robotics-runtime/foundation-lock.json
  )" = "${workspace_revision}"
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
test "${contracts_version}" = "$(jq -er '.packages.contracts.version' config/foundation-lock.json)"
test "${harness_version}" = "$(jq -er '.packages.harness.version' config/foundation-lock.json)"
