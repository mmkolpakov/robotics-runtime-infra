#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"

docker buildx bake \
  --file docker-bake.hcl \
  simulation acceptance-observer evidence-sink policy-tooling \
  --load \
  --set '*.platform=linux/amd64' \
  --set '*.cache-from=type=gha,scope=foundation-amd64' \
  --set '*.cache-to=type=gha,mode=max,scope=foundation-amd64'
