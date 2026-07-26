#!/usr/bin/env bash
set -Eeuo pipefail

revision="$(git ls-remote \
  https://github.com/microsoft/onnxruntime.git \
  refs/tags/v1.27.0 | awk '{print $1}')"
test "${revision}" = \
  8f0278c77bf44b0cc83c098c6c722b92a36ac4b5
curl --fail --location --silent --show-error \
  https://pypi.org/pypi/onnxruntime-gpu/1.27.0/json \
  | jq -e \
    '[.urls[].filename | select(test("manylinux.*aarch64"))] | length == 0'
