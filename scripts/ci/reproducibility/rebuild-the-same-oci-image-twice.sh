#!/usr/bin/env bash
set -Eeuo pipefail

created="$(git show --no-patch --format=%cI HEAD)"
epoch="$(git show --no-patch --format=%ct HEAD)"
build=(
  docker buildx build
  --no-cache
  --platform linux/amd64
  --target evidence-sink
  --provenance=false
  --build-arg "IMAGE_CREATED=${created}"
  --build-arg "IMAGE_SOURCE=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
  --build-arg "IMAGE_VERSION=reproducibility"
  --build-arg "SOURCE_DATE_EPOCH=${epoch}"
  --build-arg "VCS_REF=${GITHUB_SHA}"
  .
)
"${build[@]}" --output \
  type=oci,dest=first.tar,rewrite-timestamp=true
"${build[@]}" --output \
  type=oci,dest=second.tar,rewrite-timestamp=true
first_digest="$(tar -xOf first.tar index.json | jq -er '.manifests[0].digest')"
second_digest="$(tar -xOf second.tar index.json | jq -er '.manifests[0].digest')"
test "${first_digest}" = "${second_digest}"
printf 'reproducible OCI manifest: %s\n' "${first_digest}"
