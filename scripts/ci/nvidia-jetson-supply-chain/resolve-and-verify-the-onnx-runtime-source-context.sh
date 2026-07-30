#!/usr/bin/env bash
set -Eeuo pipefail

docker buildx bake onnxruntime-jetson-source-verification \
  --set '*.output=type=cacheonly' \
  --set '*.cache-from=type=gha,scope=runtime-infra-onnxruntime-source' \
  --set '*.cache-to=type=gha,mode=max,scope=runtime-infra-onnxruntime-source'
