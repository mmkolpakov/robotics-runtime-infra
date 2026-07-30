#!/usr/bin/env bash
set -Eeuo pipefail

docker buildx bake rknn-converter-verification \
  --set '*.output=type=cacheonly'
