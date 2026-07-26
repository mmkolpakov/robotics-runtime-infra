#!/usr/bin/env bash
set -Eeuo pipefail

docker buildx bake multiarch \
  --set '*.platform=linux/arm64' \
  --set '*.output=type=cacheonly' \
  --set '*.cache-from=type=gha,scope=runtime-infra-arm64' \
  --set '*.cache-to=type=gha,mode=max,scope=runtime-infra-arm64'
