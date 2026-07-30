#!/usr/bin/env bash
set -Eeuo pipefail

work_dir="$(
  mktemp -d \
    "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/robotics-reproducibility.XXXXXX"
)"
trap 'rm -rf -- "${work_dir}"' EXIT

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
  "type=oci,dest=${work_dir}/first.tar,rewrite-timestamp=true"
"${build[@]}" --output \
  "type=oci,dest=${work_dir}/second.tar,rewrite-timestamp=true"
first_digest="$(
  tar -xOf "${work_dir}/first.tar" index.json |
    jq -er '.manifests[0].digest'
)"
second_digest="$(
  tar -xOf "${work_dir}/second.tar" index.json |
    jq -er '.manifests[0].digest'
)"
if test "${first_digest}" != "${second_digest}"; then
  printf 'first OCI manifest:  %s\n' "${first_digest}" >&2
  printf 'second OCI manifest: %s\n' "${second_digest}" >&2
  exit 1
fi
printf 'reproducible OCI manifest: %s\n' "${first_digest}"
