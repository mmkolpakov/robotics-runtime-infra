#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  can-utils socat "linux-modules-extra-$(uname -r)"
ci_set_compose_fixture_env

bash scripts/ci/physical-attach.sh
