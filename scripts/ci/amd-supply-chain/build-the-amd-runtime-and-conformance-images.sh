#!/usr/bin/env bash
set -Eeuo pipefail

docker buildx bake amd \
  --set '*.platform=linux/amd64' \
  --set '*.output=type=docker' \
  --set 'inference-amd.cache-from=type=gha,scope=runtime-infra-amd-amd64' \
  --set 'provider-conformance-amd.cache-from=type=gha,scope=runtime-infra-amd-amd64' \
  --set 'provider-conformance-amd.cache-to=type=gha,mode=max,scope=runtime-infra-amd-amd64'
