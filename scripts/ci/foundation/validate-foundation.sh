#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"

foundation_project=dependencies/robotics-runtime
foundation_bin="${foundation_project}/.venv/bin"

bash scripts/ci/foundation/render-compatibility.sh \
  docs/foundation-compatibility.md --check
uv sync --project "${foundation_project}" --locked --all-packages --no-default-groups --no-editable
uv pip check --python "${foundation_bin}/python"
ROBOTICS_CONTRACTS_CLI="${foundation_bin}/robotics-contracts" \
  bats test/qualification/qualification.bats
ROBOTICS_CONTRACTS_CLI="${foundation_bin}/robotics-contracts" \
  bash test/qualification/real-cosign.sh
