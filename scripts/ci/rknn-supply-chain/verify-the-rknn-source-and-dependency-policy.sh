#!/usr/bin/env bash
set -Eeuo pipefail

revision="$(git ls-remote \
  https://github.com/airockchip/rknn-toolkit2.git \
  refs/tags/v2.3.2 | awk '{print $1}')"
test "${revision}" = \
  42aa1d426c0a9e0869b6374edba009f7208a1926
if grep -Eq '^(nvidia-|triton==)' \
  docker/python/rknn-converter.lock; then
  echo "RKNN converter lock contains a prohibited GPU package" >&2
  exit 1
fi
if grep -Eq '^(nvidia-|triton==)' \
  docker/python/rknn-runtime.lock; then
  echo "RKNN runtime lock contains a prohibited GPU package" >&2
  exit 1
fi
docker buildx bake --file docker-bake.hcl rknn-source-verification \
  --set '*.output=type=cacheonly'
