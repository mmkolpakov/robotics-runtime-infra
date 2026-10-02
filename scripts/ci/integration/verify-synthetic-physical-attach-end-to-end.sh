#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  can-utils socat "linux-modules-extra-$(uname -r)"
# The runtime producer consumes this identity; the static Compose placeholder
# is not a valid acceptance-run UUID and must never reach a live fixture.
if [[ -z "${ROBOTICS_RUN_ID:-}" ]]; then
  export ROBOTICS_RUN_ID
  ROBOTICS_RUN_ID="$(python3 -c 'import uuid; print(f"run-{uuid.uuid4()}")')"
fi
ci_set_compose_fixture_env

bash scripts/ci/physical-attach.sh
