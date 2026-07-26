#!/usr/bin/env bash
set -Eeuo pipefail

bats \
  test/ci/workflow-architecture.bats \
  test/ci/hardware-cleanup.bats
