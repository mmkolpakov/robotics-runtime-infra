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
    local action="$1" file_list='' immutable=false checksum=false one_way=false
    local -a selected=()
    [[ "$action" == copy || "$action" == check ]] || return 1
    [[ "$2" == "$(dirname "$SOURCE")" ]] || return 1
    [[ "$3" == "evidence:${EVIDENCE_BUCKET}/${EVIDENCE_PREFIX}/${ROBOTICS_RUN_ID}/0-${DIGEST}/" ]] || return 1
    shift 3
    while (($#)); do
      case "$1" in
        --files-from-raw) file_list="$2"; shift 2 ;;
        --immutable) immutable=true; shift ;;
        --checksum) checksum=true; shift ;;
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
      [[ "$immutable" == true && "$checksum" == true ]] || return 1
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
    [[ "$output" == *'MCAP path cannot contain line breaks'* ]]
    [ ! -e "$UPLOAD_CALLS" ]
  done
}

@test "a trailing newline cannot redirect segment registration to another file" {
  file="${SOURCE}"$'\n'
  cp "$SOURCE" "$file"
  run bash "$SINK" segment "$file"
  [ "$status" -ne 0 ]
  [[ "$output" == *'MCAP path cannot contain line breaks'* ]]
  [ ! -e "$UPLOAD_CALLS" ]
}

@test "nonportable source names cannot select rclone encoded aliases" {
  for name in $'recording\t_0000.mcap' 'recording␉_0000.mcap' 'recording‛␉_0000.mcap'; do
    file="${EVIDENCE_SPOOL_DIR}/${name}"
    cp "$SOURCE" "$file"
    run bash "$SINK" segment "$file"
    [ "$status" -ne 0 ]
    [[ "$output" == *'S3 MCAP filename must use portable ASCII'* ]]
    [ ! -e "$UPLOAD_CALLS" ]
    [ ! -e "$UPLOAD_AWS_CALLS" ]
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

generic_source() {
  local media="$1" name="$2" content="$3"
  SOURCE="${EVIDENCE_SPOOL_DIR}/${name}"
  printf '%s' "$content" >"$SOURCE"
  DIGEST="$(sha256sum "$SOURCE" | cut -d' ' -f1)"
  export SOURCE DIGEST
  jq -n --arg digest "$DIGEST" --arg media "$media" \
    --argjson size "$(stat -c '%s' "$SOURCE")" '
    {VersionId: "retained-1", ContentLength: $size,
      ContentType: $media, Metadata: {sha256: $digest}}
  ' >"$UPLOAD_METADATA"
}

@test "JSONL and PNG generic artifacts use the current immutable S3 upload path" {
  for media in application/x-ndjson image/png; do
    generic_source "$media" attachment '{"data":"opaque"}'
    # A separate registration scope models a new run attempt; previous bytes stay untouched.
    export EVIDENCE_REGISTRATION_DIR="${BATS_TEST_TMPDIR}/${media##*/}"
    run bash "$SINK" artifact "$SOURCE" "$media" 0
    [ "$status" -eq 0 ]
    run jq -e --arg media "$media" --arg sha "$DIGEST" '
      .upload_status == "confirmed" and .media_type == $media and .sha256 == $sha and
      .version_id == "retained-1" and (.uri | startswith("s3://fixture-bucket/"))
    ' "${EVIDENCE_REGISTRATION_DIR}/0-${DIGEST}.json"
    [ "$status" -eq 0 ]
  done
}

@test "a zero-byte opaque artifact retains original hash size and media remotely" {
  generic_source text/plain empty.log ''
  run bash "$SINK" artifact "$SOURCE" text/plain 0
  [ "$status" -eq 0 ]
  run jq -e --arg sha "$DIGEST" '
    .upload_status == "confirmed" and .size_bytes == 0 and .sha256 == $sha and
    .media_type == "text/plain" and .version_id == "retained-1"
  ' "${EVIDENCE_REGISTRATION_DIR}/0-${DIGEST}.json"
  [ "$status" -eq 0 ]
}

@test "matching current generic registration is reused without another upload" {
  generic_source text/plain repeat.log opaque
  run bash "$SINK" artifact "$SOURCE" text/plain 0
  [ "$status" -eq 0 ]
  run bash "$SINK" artifact "$SOURCE" text/plain 0
  [ "$status" -eq 0 ]
  [ "$(cat "$UPLOAD_CALLS")" = $'copy\ncheck' ]
}

@test "a local registration cannot silently satisfy a selected S3 request" {
  generic_source text/plain empty.log ''
  EVIDENCE_MODE=local run bash "$SINK" artifact "$SOURCE" text/plain 0
  [ "$status" -eq 0 ]
  run bash "$SINK" artifact "$SOURCE" text/plain 0
  [ "$status" -ne 0 ]
  [[ "$output" == *'registration differs from selected identity or mode'* ]]
  [ ! -e "$UPLOAD_CALLS" ]
  run jq -e '.upload_status == "local"' "${EVIDENCE_REGISTRATION_DIR}/0-${DIGEST}.json"
  [ "$status" -eq 0 ]
}

@test "same empty-byte SHA and index cannot reuse another declared media" {
  generic_source text/plain empty.log ''
  run bash "$SINK" artifact "$SOURCE" text/plain 0
  [ "$status" -eq 0 ]
  run bash "$SINK" artifact "$SOURCE" image/png 0
  [ "$status" -ne 0 ]
  [[ "$output" == *'registration differs from selected identity or mode'* ]]
  run jq -e '.media_type == "text/plain"' "${EVIDENCE_REGISTRATION_DIR}/0-${DIGEST}.json"
  [ "$status" -eq 0 ]
}

@test "generic artifact entry cannot bypass the current MCAP validator" {
  export EVIDENCE_ARTIFACT_MEDIA_TYPES='application/mcap'
  run bash "$SINK" artifact "$SOURCE" application/mcap 0
  [ "$status" -ne 0 ]
  [[ "$output" == *'MCAP recordings require segment registration'* ]]
  [ ! -e "$UPLOAD_CALLS" ]
}

@test "a sparse generic source beyond verifier admission is refused before hash or network" {
  SOURCE="${EVIDENCE_SPOOL_DIR}/oversized.log"
  truncate -s 1073741825 "$SOURCE"
  export SOURCE
  before="$(stat -c '%i:%s:%Y:%Z' "$SOURCE")"
  sha256sum() { printf called >"${BATS_TEST_TMPDIR}/hash-called"; return 1; }
  export -f sha256sum
  run bash "$SINK" artifact "$SOURCE" text/plain 0
  [ "$status" -ne 0 ]
  [[ "$output" == *'EVIDENCE_MAX_ARTIFACT_BYTES budget'* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/hash-called" ]
  [ ! -e "$UPLOAD_CALLS" ]
  [ ! -e "$UPLOAD_AWS_CALLS" ]
  [ ! -d "$EVIDENCE_REGISTRATION_DIR" ]
  [ "$(stat -c '%i:%s:%Y:%Z' "$SOURCE")" = "$before" ]
}

@test "invalid generic artifact budget cannot reach hashing or remote effects" {
  for limit in 0 -1 invalid 1073741825 999999999999999999999999999; do
    generic_source text/plain bounded.log opaque
    EVIDENCE_MAX_ARTIFACT_BYTES="$limit" run bash "$SINK" artifact "$SOURCE" text/plain 0
    [ "$status" -ne 0 ]
    [[ "$output" == *'EVIDENCE_MAX_ARTIFACT_BYTES must be positive'* ]]
    [ ! -e "$UPLOAD_CALLS" ]
    [ ! -e "$UPLOAD_AWS_CALLS" ]
  done
}

@test "selected verifier byte budget also admits MCAP before hashing or upload" {
  before="$(stat -c '%i:%s:%Y:%Z' "$SOURCE")"
  export EVIDENCE_MAX_ARTIFACT_BYTES=1
  sha256sum() { printf called >"${BATS_TEST_TMPDIR}/hash-called"; return 1; }
  export -f sha256sum
  run bash "$SINK" segment "$SOURCE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'EVIDENCE_MAX_ARTIFACT_BYTES budget'* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/hash-called" ]
  [ ! -e "$UPLOAD_CALLS" ]
  [ ! -e "$UPLOAD_AWS_CALLS" ]
  [ ! -d "$EVIDENCE_REGISTRATION_DIR" ]
  [ "$(stat -c '%i:%s:%Y:%Z' "$SOURCE")" = "$before" ]
}
