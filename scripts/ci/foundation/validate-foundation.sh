#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"

contracts_dir=dependencies/robotics-runtime-contracts
harness_dir=dependencies/robotics-acceptance-harness

bash scripts/ci/foundation/render-compatibility.sh \
  docs/foundation-compatibility.md --check
uv sync --project "${contracts_dir}" --locked --no-dev
uv sync --project "${harness_dir}" --locked --no-dev
ROBOTICS_CONTRACTS_CLI="${contracts_dir}/.venv/bin/robotics-contracts" \
  bats test/qualification/qualification.bats
ROBOTICS_CONTRACTS_CLI="${contracts_dir}/.venv/bin/robotics-contracts" \
  bash test/qualification/real-cosign.sh
