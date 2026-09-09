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
export DIFFOCI_BACKEND=local
export DIFFOCI_LOCAL_CACHE="${work_dir}/diffoci-cache"
report_dir="${ROBOTICS_CI_REPRODUCIBILITY_ARTIFACT_DIR:-${PWD}/artifacts/reproducibility}"
build=(
  docker buildx bake
  "--allow=fs.write=${work_dir}"
  --file docker-bake.hcl
  evidence-sink
  --provenance=false
  --set evidence-sink.no-cache=true
  --set evidence-sink.platform=linux/amd64
)
"${build[@]}" --set evidence-sink.tags=localhost/robotics-reproducibility:first --set \
  "evidence-sink.output=type=oci,dest=${work_dir}/first.tar,rewrite-timestamp=true"
"${build[@]}" --set evidence-sink.tags=localhost/robotics-reproducibility:second --set \
  "evidence-sink.output=type=oci,dest=${work_dir}/second.tar,rewrite-timestamp=true"
scripts/ci/reproducibility/compare-oci-archives.sh \
  "${work_dir}/first.tar" "${work_dir}/second.tar" "${report_dir}"
