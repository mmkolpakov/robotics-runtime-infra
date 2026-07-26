#!/usr/bin/env bash
set -Eeuo pipefail

verify_digest() {
  local reference="$1"
  local expected="$2"
  local actual
  actual="$(docker buildx imagetools inspect "${reference}" \
    --format '{{.Manifest.Digest}}')"
  test "${actual}" = "${expected}"
}
verify_digest \
  nvcr.io/nvidia/cuda-dl-base:26.06-cuda13.3-inference-devel-ubuntu24.04 \
  sha256:8d74c381b9842610edcd770dd2bfef12ff37dc76a6fa283215a372db99fca5fc
verify_digest \
  nvidia/cuda:13.3.0-runtime-ubuntu24.04 \
  sha256:789e629e49401647e22b7054ae9c6c4f6427dba68010ba428deb4cc6b063676e
