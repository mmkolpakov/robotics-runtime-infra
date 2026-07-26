#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  bats can-utils socat "linux-modules-extra-$(uname -r)"
ci_set_compose_fixture_env
ci_export_local_image_digest \
  ROBOTICS_COSIGN_IMAGE_DIGEST \
  "${PERMIT_PREFLIGHT_IMAGE}"
docker compose \
  -f compose.yaml \
  -f compose.edge-attach.yaml \
  -f compose.real-observation.yaml \
  -f compose.real-observation.test.yaml \
  --profile real-observation \
  --profile real-observation-test \
  --profile real-observation-test-negative \
  config --quiet
bats test/ci/physical-attach.bats
bash scripts/ci/physical-attach.sh
