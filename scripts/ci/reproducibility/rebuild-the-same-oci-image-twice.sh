#!/usr/bin/env bash
set -Eeuo pipefail

work_dir="$(
  mktemp -d \
    "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/robotics-reproducibility.XXXXXX"
)"
trap 'rm -rf -- "${work_dir}"' EXIT

created="$(git show --no-patch --format=%cI HEAD)"
epoch="$(git show --no-patch --format=%ct HEAD)"
export IMAGE_CREATED="${created}"
export IMAGE_SOURCE="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
export SOURCE_DATE_EPOCH="${epoch}"
export VCS_REF="${GITHUB_SHA}"
export VERSION=reproducibility
build=(
  docker buildx bake
  --file docker-bake.hcl
  evidence-sink
  --set evidence-sink.no-cache=true
  --set evidence-sink.platform=linux/amd64
  --set evidence-sink.provenance=false
)
"${build[@]}" --set \
  "evidence-sink.output=type=oci,dest=${work_dir}/first.tar,rewrite-timestamp=true"
"${build[@]}" --set \
  "evidence-sink.output=type=oci,dest=${work_dir}/second.tar,rewrite-timestamp=true"
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
