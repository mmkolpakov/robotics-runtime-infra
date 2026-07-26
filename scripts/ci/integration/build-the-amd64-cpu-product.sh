#!/usr/bin/env bash
set -Eeuo pipefail

docker buildx bake cpu provider-conformance-cpu \
  --load \
  --set '*.platform=linux/amd64' \
  --set '*.cache-from=type=gha,scope=runtime-infra-amd64' \
  --set '*.cache-to=type=gha,mode=max,scope=runtime-infra-amd64'
