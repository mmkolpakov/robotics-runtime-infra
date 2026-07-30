#!/usr/bin/env bash
set -Eeuo pipefail

evidence_dir="${PWD}/artifacts/evidence-s3"
project="evidence-s3-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mkdir -p "${evidence_dir}"
sudo chown -R 10001:10001 "${evidence_dir}"
export ROBOTICS_BAG_DIR="${PWD}/test/fixtures/playback/golden"
export ROBOTICS_EVIDENCE_DIR="${evidence_dir}"
compose=(
  docker compose -p "${project}"
  -f compose.yaml
  -f compose.evidence.yaml
  -f compose.evidence.test.yaml
)
cleanup() {
  "${compose[@]}" --profile test --profile evidence \
    down --volumes --remove-orphans || true
}
trap cleanup EXIT
"${compose[@]}" --profile test --profile evidence \
  run --rm evidence-finalize
jq -e '
  .schema_version == "evidence-index.v2" and
  .finalized == true and
  .policy_observation.upload_mode == "closed_segments_during_run" and
  .policy_observation.remote_sink_used == true and
  (.segments | length) == 1 and
  .segments[0].upload_status == "confirmed" and
  (.segments[0].version_id | length) > 0 and
  (.segments[0].mcap_summary.sha256 | length) == 64
' "${evidence_dir}/evidence-index.json"
