#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"

uv sync --project dependencies/contracts --locked --all-groups
uv sync --project dependencies/harness --locked --all-groups
(
  cd dependencies/contracts
  uv run --no-sync pytest \
    --junitxml "${root}/artifacts/contracts.xml"
)
uv pip install \
  --python dependencies/harness/.venv/bin/python \
  --reinstall \
  ./dependencies/contracts
(
  cd dependencies/harness
  .venv/bin/pytest \
    -p robotics_acceptance_harness.plugin \
    tests \
    --robotics-scenario "${root}/foundation/acceptance-scenario.yaml" \
    --robotics-runtime "${root}/foundation/runtime-manifest.yaml" \
    --junitxml "${root}/artifacts/harness.xml"
)
