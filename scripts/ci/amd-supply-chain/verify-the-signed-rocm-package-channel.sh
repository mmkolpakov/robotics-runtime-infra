#!/usr/bin/env bash
set -Eeuo pipefail

docker run --rm \
  ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90 \
  bash -euo pipefail -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg >/dev/null
  install -d -m 0755 /etc/apt/keyrings
  curl --fail --location --silent --show-error \
    https://repo.radeon.com/rocm/rocm.gpg.key \
    --output /tmp/rocm.asc
  echo \
    "2de99e2354646a90d9903e2a669fc4e36b02c1bbff7075c481e12d7edab2c88b  /tmp/rocm.asc" \
    | sha256sum --check --strict
  cp /tmp/rocm.asc /etc/apt/keyrings/rocm.asc
  rocm_repo=https://repo.radeon.com/rocm/apt/7.2.4
  printf \
    "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.asc] %s noble main\n" \
    "$rocm_repo" \
    > /etc/apt/sources.list.d/rocm.list
  apt-get update >/dev/null
  test "$(apt-cache policy migraphx | awk "/Candidate:/ {print \$2}")" \
    = "2.15.0.70204-93~24.04"
'
