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
  export UPLOAD_CALLS="${BATS_TEST_TMPDIR}/rclone-calls"
  export UPLOAD_LISTS="${BATS_TEST_TMPDIR}/rclone-lists"
  export UPLOAD_AWS_CALLS="${BATS_TEST_TMPDIR}/aws-calls"
  unset UPLOAD_FAIL_COMMAND
  unset AWS_ENDPOINT_URL
  mkdir -p "$EVIDENCE_SPOOL_DIR/nested directory"
  SOURCE="${EVIDENCE_SPOOL_DIR}/nested directory/recording # %_0000.mcap"
  cp "${ROOT}/test/fixtures/playback/golden/golden_0.mcap" "$SOURCE"
  DIGEST="$(sha256sum "$SOURCE" | cut -d' ' -f1)"
  export SOURCE DIGEST
  jq -n --arg digest "$DIGEST" --argjson size "$(stat -c '%s' "$SOURCE")" '
    {VersionId: "retained-1", ContentLength: $size,
      ContentType: "application/mcap", Metadata: {sha256: $digest}}
  ' >"$UPLOAD_METADATA"
  # Network observations and the early Go doctor call are explicit doubles.
  # The recording summary is produced by the installed contracts MCAP reader.
  mcap() { [[ "$1" == --color && "$3" == doctor ]]; }
  mcap-summary() { bash "${ROOT}/docker/evidence-sink/mcap-summary" "$@"; }
  rclone() {
    local action="$1" file_list='' immutable=false one_way=false
    local -a selected=()
    [[ "$action" == copy || "$action" == check ]] || return 1
    [[ "$2" == "$(dirname "$SOURCE")" ]] || return 1
    [[ "$3" == "evidence:${EVIDENCE_BUCKET}/${EVIDENCE_PREFIX}/${ROBOTICS_RUN_ID}/0-${DIGEST}/" ]] || return 1
    shift 3
    while (($#)); do
      case "$1" in
        --files-from-raw) file_list="$2"; shift 2 ;;
        --immutable) immutable=true; shift ;;
        --one-way) one_way=true; shift ;;
        --metadata) shift ;;
        --metadata-set) shift 2 ;;
        *) return 1 ;;
      esac
    done
    [[ -f "$file_list" ]] || return 1
    mapfile -t selected <"$file_list"
    [[ "${#selected[@]}" -eq 1 && "${selected[0]}" == "$(basename "$SOURCE")" ]] || return 1
    if [[ "$action" == copy ]]; then
      [[ "$immutable" == true ]] || return 1
    else
      [[ "$one_way" == true ]] || return 1
    fi
    printf '%s\n' "$action" >>"$UPLOAD_CALLS"
    printf '%s\n' "$file_list" >>"$UPLOAD_LISTS"
    [[ "${UPLOAD_FAIL_COMMAND:-}" != "$action" ]]
  }
  aws() {
    [[ "$1" == s3api ]] || return 1
    printf '%s\n' "$2" >>"$UPLOAD_AWS_CALLS"
    case "$2" in
      get-bucket-versioning) printf 'Enabled\n' ;;
      head-object) cat "$UPLOAD_METADATA" ;;
      *) return 1 ;;
    esac
  }
  export -f mcap mcap-summary rclone aws
}

@test "uploaded object keys preserve delimiters through canonical URI encoding" {
  printf 'unrelated segment\n' >"$(dirname "$SOURCE")/neighbor_0001.mcap"
  run bash "$SINK" segment "$SOURCE"
  [ "$status" -eq 0 ]
  [ "$(cat "$UPLOAD_CALLS")" = $'copy\ncheck' ]
  while IFS= read -r list; do
    [ ! -e "$list" ]
  done <"$UPLOAD_LISTS"
  run jq -e --arg digest "$DIGEST" --arg run_id "$ROBOTICS_RUN_ID" '
    .version_id == "retained-1" and .upload_status == "confirmed" and
    .uri == ("s3://fixture-bucket/runs%20%23/%25/" + $run_id +
      "/0-" + $digest + "/recording%20%23%20%25_0000.mcap")
  ' "${EVIDENCE_REGISTRATION_DIR}/0-${DIGEST}.json"
  [ "$status" -eq 0 ]
}

@test "failed immutable upload cannot create a registration or query object metadata" {
  export UPLOAD_FAIL_COMMAND=copy
  run bash "$SINK" segment "$SOURCE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'rclone upload failed'* ]]
  [ ! -e "${EVIDENCE_REGISTRATION_DIR}/0-${DIGEST}.json" ]
  [ "$(cat "$UPLOAD_CALLS")" = copy ]
  [ "$(cat "$UPLOAD_AWS_CALLS")" = get-bucket-versioning ]
  [ ! -e "$(cat "$UPLOAD_LISTS")" ]
}

@test "failed uploaded byte verification cannot register evidence and removes its file list" {
  export UPLOAD_FAIL_COMMAND=check
  run bash "$SINK" segment "$SOURCE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'rclone verification failed'* ]]
  [ ! -e "${EVIDENCE_REGISTRATION_DIR}/0-${DIGEST}.json" ]
  [ "$(cat "$UPLOAD_CALLS")" = $'copy\ncheck' ]
  [ "$(cat "$UPLOAD_AWS_CALLS")" = get-bucket-versioning ]
  while IFS= read -r list; do
    [ ! -e "$list" ]
  done <"$UPLOAD_LISTS"
}

@test "line breaks in segment names cannot select additional upload paths" {
  for separator in $'\n' $'\r'; do
    file="${EVIDENCE_SPOOL_DIR}/recording${separator}neighbor_0000.mcap"
    cp "$SOURCE" "$file"
    run bash "$SINK" segment "$file"
    [ "$status" -ne 0 ]
    [[ "$output" == *'MCAP filename cannot contain line breaks'* ]]
    [ ! -e "$UPLOAD_CALLS" ]
  done
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
