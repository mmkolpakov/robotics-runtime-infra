#!/usr/bin/env bash
set -Eeuo pipefail

rm -rf tmp/model-artifact-layout
jq '.manifest' tmp/model-artifact-valid.json \
  > tmp/model-artifact-manifest.json
jq '.observations.conformance_report' tmp/model-artifact-valid.json \
  > tmp/model-conformance-report.json
oras=(
  docker run --rm --volume "${PWD}:/work" --workdir /work
  "${ORAS_IMAGE}"
)
"${oras[@]}" push --oci-layout \
  --artifact-type application/vnd.robotics.model.fixture.v1 \
  --annotation org.opencontainers.image.title=model-fixture \
  tmp/model-artifact-layout:model
subject_digest="$(
  "${oras[@]}" resolve --oci-layout tmp/model-artifact-layout:model
)"
"${oras[@]}" attach --oci-layout \
  --artifact-type application/vnd.robotics.model-artifact-manifest.v1 \
  tmp/model-artifact-layout:model \
  tmp/model-artifact-manifest.json:application/vnd.robotics.model-artifact-manifest.v1
"${oras[@]}" attach --oci-layout \
  --artifact-type application/vnd.robotics.model-conformance-report.v1 \
  tmp/model-artifact-layout:model \
  tmp/model-conformance-report.json:application/vnd.robotics.model-conformance-report.v1
"${oras[@]}" discover --no-tty --oci-layout \
  --format json --depth 1 tmp/model-artifact-layout:model \
  > tmp/model-artifact-referrers.json
jq -e --arg digest "${subject_digest}" '
  .digest == $digest and
  ([.referrers[].artifactType] | sort) == [
    "application/vnd.robotics.model-artifact-manifest.v1",
    "application/vnd.robotics.model-conformance-report.v1"
  ]
' tmp/model-artifact-referrers.json
