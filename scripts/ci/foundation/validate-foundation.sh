#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"

contracts_dir=dependencies/robotics-runtime-contracts
harness_dir=dependencies/robotics-acceptance-harness

uv sync --project "${contracts_dir}" --locked --all-groups
uv sync --project "${harness_dir}" --locked --all-groups
(
  cd "${contracts_dir}"
  uv run --no-sync pytest \
    --junitxml "${root}/artifacts/contracts.xml"
)
uv pip install \
  --python "${harness_dir}/.venv/bin/python" \
  --reinstall \
  "./${contracts_dir}"
(
  cd "${harness_dir}"
  .venv/bin/pytest \
    -p robotics_acceptance_harness.plugin \
    tests \
    --robotics-scenario "${root}/foundation/acceptance-scenario.yaml" \
    --robotics-runtime "${root}/foundation/runtime-manifest.yaml" \
    --junitxml "${root}/artifacts/harness.xml"
)
