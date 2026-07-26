#!/usr/bin/env bash
set -Eeuo pipefail

docker buildx bake policy-tooling \
  --load \
  --set '*.platform=linux/amd64'
docker run --rm \
  local/robotics-runtime-infra/policy-tooling:ci version
