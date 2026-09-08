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

# The contracts CLI has its own interpreter; it must not replace the runtime's
# Python, whose ROS message bindings depend on the distribution's NumPy build.
docker run --rm --network none --env PYTHONDONTWRITEBYTECODE=1 \
  "${SIMULATION_IMAGE}" python3 -c \
  'import numpy; from rclpy.node import Node; from robotics_runtime_infra import simulation_control'
docker run --rm --network none "${SIMULATION_IMAGE}" robotics-contracts --version
