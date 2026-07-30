#!/usr/bin/env bash
set -Eeuo pipefail

docker buildx bake intel \
  --load \
  --set '*.platform=linux/amd64' \
  --set '*.cache-from=type=gha,scope=runtime-infra-intel-amd64' \
  --set '*.cache-to=type=gha,mode=max,scope=runtime-infra-intel-amd64'
