#!/usr/bin/env bash
set -Eeuo pipefail

uv pip compile docker/python/inference-amd.in \
  --python-version 3.12 \
  --python-platform x86_64-unknown-linux-gnu \
  --generate-hashes \
  --output-file docker/python/inference-amd.lock
git diff --exit-code -- docker/python/inference-amd.lock
