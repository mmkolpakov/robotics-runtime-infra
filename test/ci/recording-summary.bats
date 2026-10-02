#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI with the mcap extra}"
  export ROBOTICS_CONTRACTS_CLI
  WRAPPER="${ROOT}/docker/evidence-sink/mcap-summary"
  SOURCE="${BATS_TEST_TMPDIR}/input.mcap"
  OUTPUT="${BATS_TEST_TMPDIR}/summary.json"
  cp "${ROOT}/test/fixtures/playback/golden/golden_0.mcap" "$SOURCE"
}

@test "recording summary uses the installed contracts producer on a real MCAP" {
  run bash "$WRAPPER" "$SOURCE" "$OUTPUT"
  [ "$status" -eq 0 ]
  run "$ROBOTICS_CONTRACTS_CLI" validate --schema recording-summary.v1 --quiet "$OUTPUT"
  [ "$status" -eq 0 ]
  run jq -e --arg digest "$(sha256sum "$SOURCE" | cut -d' ' -f1)" '
    .schema_version == "recording-summary.v1" and .source_sha256 == $digest and
    .statistics.message_count == 40 and
    ([.channels[].topic] == ["/playback_probe"])' "$OUTPUT"
  [ "$status" -eq 0 ]
  cp "$OUTPUT" "${BATS_TEST_TMPDIR}/first.json"
  run bash "$WRAPPER" "$SOURCE" "$OUTPUT"
  [ "$status" -eq 0 ]
  cmp "$OUTPUT" "${BATS_TEST_TMPDIR}/first.json"
  if [[ "$(uname -s)" == Linux ]]; then
    [ "$(stat -c '%a' "$OUTPUT")" = 444 ]
  fi
}

@test "recording summary preserves existing output and cleans staging on invalid MCAP" {
  printf 'not an MCAP recording\n' >"$SOURCE"
  printf 'previous\n' >"$OUTPUT"
  run bash "$WRAPPER" "$SOURCE" "$OUTPUT"
  [ "$status" -ne 0 ]
  [[ "$output" == *MCAP* ]]
  [ "$(cat "$OUTPUT")" = previous ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name '.recording-summary.*' -print -quit)" ]
}

@test "recording summary rejects an output alias of the source" {
  local before
  before="$(sha256sum "$SOURCE")"
  run bash "$WRAPPER" "$SOURCE" "$SOURCE"
  [ "$status" -eq 65 ]
  [[ "$output" == *'destination must not replace source'* ]]
  [ "$(sha256sum "$SOURCE")" = "$before" ]
}
