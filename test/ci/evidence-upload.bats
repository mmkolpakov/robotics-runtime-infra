#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  SINK="${ROOT}/docker/evidence-sink/evidence-sink"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI before these tests}"
  export ROOT ROBOTICS_CONTRACTS_CLI
  export ROBOTICS_RUN_ID=run-00000000-0000-4000-8000-000000000001
  export EVIDENCE_SPOOL_DIR="${BATS_TEST_TMPDIR}/spool"
  export EVIDENCE_REGISTRATION_DIR="${BATS_TEST_TMPDIR}/registrations"
  export EVIDENCE_SUMMARY_DIR="${BATS_TEST_TMPDIR}/summaries"
  export EVIDENCE_MODE=s3 EVIDENCE_BUCKET=fixture-bucket EVIDENCE_PREFIX='runs #/%'
  export UPLOAD_METADATA="${BATS_TEST_TMPDIR}/head.json"
  unset AWS_ENDPOINT_URL
  mkdir -p "$EVIDENCE_SPOOL_DIR/nested directory"
  SOURCE="${EVIDENCE_SPOOL_DIR}/nested directory/recording # %_0000.mcap"
  cp "${ROOT}/test/fixtures/playback/golden/golden_0.mcap" "$SOURCE"
  DIGEST="$(sha256sum "$SOURCE" | cut -d' ' -f1)"
  jq -n --arg digest "$DIGEST" --argjson size "$(stat -c '%s' "$SOURCE")" '
    {VersionId: "retained-1", ContentLength: $size,
      ContentType: "application/mcap", Metadata: {sha256: $digest}}
  ' >"$UPLOAD_METADATA"
  # Network observations and the early Go doctor call are explicit doubles.
  # The recording summary is produced by the installed contracts MCAP reader.
  mcap() { [[ "$1" == --color && "$3" == doctor ]]; }
  mcap-summary() { bash "${ROOT}/docker/evidence-sink/mcap-summary" "$@"; }
  rclone() { [[ "$1" == copyto || "$1" == check ]]; }
  aws() {
    [[ "$1" == s3api ]] || return 1
    case "$2" in
      get-bucket-versioning) printf 'Enabled\n' ;;
      head-object) cat "$UPLOAD_METADATA" ;;
      *) return 1 ;;
    esac
  }
  export -f mcap mcap-summary rclone aws
}

@test "uploaded object keys preserve delimiters through canonical URI encoding" {
  run bash "$SINK" segment "$SOURCE"
  [ "$status" -eq 0 ]
  run jq -e --arg digest "$DIGEST" --arg run_id "$ROBOTICS_RUN_ID" '
    .version_id == "retained-1" and .upload_status == "confirmed" and
    .uri == ("s3://fixture-bucket/runs%20%23/%25/" + $run_id +
      "/0-" + $digest + "/recording%20%23%20%25_0000.mcap")
  ' "${EVIDENCE_REGISTRATION_DIR}/0-${DIGEST}.json"
  [ "$status" -eq 0 ]
}

@test "a mutable S3 null version cannot be registered as retained evidence" {
  jq '.VersionId = "null"' "$UPLOAD_METADATA" >"${BATS_TEST_TMPDIR}/null.json"
  mv "${BATS_TEST_TMPDIR}/null.json" "$UPLOAD_METADATA"
  run bash "$SINK" segment "$SOURCE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'version ID must be a non-null string'* ]]
  [ ! -e "${EVIDENCE_REGISTRATION_DIR}/0-${DIGEST}.json" ]
}

@test "a non-string S3 version cannot enter a retention registration" {
  jq '.VersionId = 123' "$UPLOAD_METADATA" >"${BATS_TEST_TMPDIR}/numeric.json"
  mv "${BATS_TEST_TMPDIR}/numeric.json" "$UPLOAD_METADATA"
  run bash "$SINK" segment "$SOURCE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'version ID must be a non-null string'* ]]
  [ ! -e "${EVIDENCE_REGISTRATION_DIR}/0-${DIGEST}.json" ]
}
