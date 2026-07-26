#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo
mkdir -p tmp
ci_opa fmt --list --fail policy
ci_opa test \
  policy \
  test/policy/model_artifact \
  test/policy/execution \
  --fail-on-empty
