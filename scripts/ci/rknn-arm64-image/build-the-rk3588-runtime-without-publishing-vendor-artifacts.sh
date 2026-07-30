#!/usr/bin/env bash
set -Eeuo pipefail

docker buildx bake \
  inference-rknn-rk3588 \
  provider-conformance-rknn-rk3588 \
  --set '*.output=type=docker'
