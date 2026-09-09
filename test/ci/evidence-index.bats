#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  SINK="${ROOT}/docker/evidence-sink/evidence-sink"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI before these tests}"
  export ROBOTICS_CONTRACTS_CLI
  export ROBOTICS_RECEIPT_INPUTS_CLI="${ROOT}/test/ci/receipt-inputs"
  export ROBOTICS_RUN_ID=run-00000000-0000-4000-8000-000000000001
  export EVIDENCE_SPOOL_DIR="${BATS_TEST_TMPDIR}/spool"
  export EVIDENCE_REGISTRATION_DIR="${BATS_TEST_TMPDIR}/registrations"
  export EVIDENCE_RECEIPT_DIR="${BATS_TEST_TMPDIR}/receipts"
  export EVIDENCE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  export EVIDENCE_SUMMARY_DIR="${BATS_TEST_TMPDIR}/summaries"
  export EVIDENCE_INDEX_PATH="${BATS_TEST_TMPDIR}/evidence-index.json"
  export EVIDENCE_MODE=local EVIDENCE_DELETE_CONFIRMED_LOCAL=false
  mkdir -p "$EVIDENCE_SPOOL_DIR"
  SOURCE="${BATS_TEST_TMPDIR}/metrics with spaces.otlp.jsonl"
  printf '{"resourceMetrics":[]}\n' >"$SOURCE"
}

register_local() {
  bash "$SINK" artifact "$SOURCE" application/x-ndjson "${1:-0007}"
}

assert_index_preserved() {
  [ "$status" -ne 0 ]
  [ "$(cat "$EVIDENCE_INDEX_PATH")" = previous ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name '.evidence-index.*' -print -quit)" ]
}

@test "index writer rehashes local NDJSON and encodes its file URI" {
  register_local
  run bash "$SINK" finalize
  [ "$status" -eq 0 ]
  run "$ROBOTICS_CONTRACTS_CLI" validate --schema evidence-index.v1 --quiet "$EVIDENCE_INDEX_PATH"
  [ "$status" -eq 0 ]
  run jq -e --arg digest "$(sha256sum "$SOURCE" | cut -d' ' -f1)" '
    .schema_version == "evidence-index.v1" and .finalized == true and
    .policy_observation.retention_class == "pull-request-7d" and
    .policy_observation.remote_sink_used == false and
    (.artifacts | length) == 1 and
    .artifacts[0].segment_index == 7 and .artifacts[0].sha256 == $digest and
    .artifacts[0].media_type == "application/x-ndjson" and
    (.artifacts[0].uri | contains("metrics%20with%20spaces.otlp.jsonl")) and
    (has("segments") | not)' "$EVIDENCE_INDEX_PATH"
  [ "$status" -eq 0 ]
  if [[ "$(uname -s)" == Linux ]]; then
    [ "$(stat -c '%a' "$EVIDENCE_INDEX_PATH")" = 444 ]
  fi
}

@test "index finalization rejects changed source bytes without replacing output" {
  register_local
  printf 'changed\n' >"$SOURCE"
  printf 'previous\n' >"$EVIDENCE_INDEX_PATH"
  run bash "$SINK" finalize
  assert_index_preserved
  [[ "$output" == *'supplied sha256 does not match'* ]]
}

@test "registrations from another run cannot be reused or finalized" {
  register_local
  export ROBOTICS_RUN_ID=run-00000000-0000-4000-8000-000000000002
  run register_local
  [ "$status" -ne 0 ]
  [[ "$output" == *'belongs to another run'* ]]
  printf 'previous\n' >"$EVIDENCE_INDEX_PATH"
  run bash "$SINK" finalize
  assert_index_preserved
  [[ "$output" == *'belongs to another run'* ]]
}

@test "leading zero indices cannot bypass duplicate registration detection" {
  register_local 0007
  printf 'other bytes\n' >"$SOURCE"
  run register_local 7
  [ "$status" -ne 0 ]
  [[ "$output" == *'segment index 7 already has a different'* ]]
}

@test "empty evidence and missing run IDs fail before publishing an index" {
  printf 'previous\n' >"$EVIDENCE_INDEX_PATH"
  run bash "$SINK" finalize
  assert_index_preserved
  [[ "$output" == *'no artifact registrations exist'* ]]
  unset ROBOTICS_RUN_ID
  run register_local
  [ "$status" -ne 0 ]
  [[ "$output" == *'ROBOTICS_RUN_ID is required'* ]]
}

@test "S3 configuration alone does not claim an observed remote upload" {
  register_local
  run env EVIDENCE_MODE=s3 bash "$SINK" finalize
  [ "$status" -eq 0 ]
  run jq -e '.policy_observation.remote_sink_used == false' "$EVIDENCE_INDEX_PATH"
  [ "$status" -eq 0 ]
}

@test "recording registration binds the actual MCAP summary into the public index" {
  local test_python recording_source
  recording_source="${EVIDENCE_SPOOL_DIR}/recording_0000.mcap"
  test_python="$(dirname "$ROBOTICS_CONTRACTS_CLI")/python"
  if [[ -f "${test_python}.exe" ]]; then test_python+='.exe'; fi
  "$test_python" - "$recording_source" <<'PY'
import sys
from mcap.writer import CompressionType, Writer
with open(sys.argv[1], "wb") as stream:
    writer = Writer(stream, compression=CompressionType.ZSTD)
    writer.start()
    schema = writer.register_schema("fixture.Sample", "jsonschema", b'{"type":"object"}')
    channel = writer.register_channel("/observations", "json", schema)
    writer.add_message(channel, 1_000_000_000, b"{}", 1_000_000_000)
    writer.finish()
PY
  # Only the early Go doctor call is a test double. The actual contracts MCAP
  # reader validates records/CRCs, and its actual evidence writer binds all bytes.
  mcap() { [[ "$1" == --color && "$3" == doctor ]]; }
  mcap-summary() { bash "${ROOT}/docker/evidence-sink/mcap-summary" "$@"; }
  export ROOT
  export -f mcap mcap-summary
  run bash "$SINK" finalize
  [ "$status" -eq 0 ]
  run "$ROBOTICS_CONTRACTS_CLI" validate --schema evidence-index.v1 --quiet "$EVIDENCE_INDEX_PATH"
  [ "$status" -eq 0 ]
  local digest summary
  digest="$(sha256sum "$recording_source" | cut -d' ' -f1)"
  summary="${EVIDENCE_SUMMARY_DIR}/0-${digest}.recording-summary.json"
  run jq -e --arg digest "$digest" --arg summary "$(sha256sum "$summary" | cut -d' ' -f1)" '
    .artifacts[0].kind == "recording" and .artifacts[0].segment_index == 0 and
    .artifacts[0].sha256 == $digest and .artifacts[0].recording_summary.sha256 == $summary
  ' "$EVIDENCE_INDEX_PATH"
  [ "$status" -eq 0 ]
  run verify_inventory_with_harness 0
  [ "$status" -eq 0 ]
}

seed_remote_verification_fixture() {
  # This tests document assembly. The upload and external verifier observations
  # are fixtures; it is not a network, signature, or S3 qualification test.
  local slot="${1:-7}"
  register_local "$slot"
  export EVIDENCE_MODE=s3
  DIGEST="$(sha256sum "$SOURCE" | cut -d' ' -f1)"
  REGISTRATION="${EVIDENCE_REGISTRATION_DIR}/${slot}-${DIGEST}.json"
  RECEIPT="${EVIDENCE_RECEIPT_DIR}/${slot}-${DIGEST}.json"
  VERIFICATION="${BATS_TEST_TMPDIR}/verification-${slot}.json"
  jq --arg slot "$slot" '.upload_status = "confirmed" | .uri = ("s3://fixture-bucket/metrics-" + $slot + ".otlp.jsonl") |
    .version_id = "fixture-version-1"' "$REGISTRATION" >"${BATS_TEST_TMPDIR}/registration.json"
  mv "${BATS_TEST_TMPDIR}/registration.json" "$REGISTRATION"
  for name in statement trust-policy verification-evidence; do
    printf '{"fixture":"%s"}\n' "$name" >"${BATS_TEST_TMPDIR}/${name}.json"
  done
  jq -n --slurpfile registration "$REGISTRATION" \
    --arg statement "$(sha256sum "${BATS_TEST_TMPDIR}/statement.json" | cut -d' ' -f1)" \
    --arg policy "$(sha256sum "${BATS_TEST_TMPDIR}/trust-policy.json" | cut -d' ' -f1)" \
    --arg evidence "$(sha256sum "${BATS_TEST_TMPDIR}/verification-evidence.json" | cut -d' ' -f1)" '{
      schema_version: "artifact-verification.v1", verification_id: "fixture.verification",
      statement_sha256: $statement, trust_policy_sha256: $policy,
      verification_evidence_sha256: $evidence,
      artifact: ($registration[0] | {uri, sha256, size_bytes, media_type,
        immutable_revision: .version_id}),
      producer_identity: "fixture-producer", producer_implementation: "fixture-uploader",
      verifier: {identity: "fixture-verifier", implementation: "fixture", version: "1"},
      verified_at: "2026-01-01T00:00:00Z", status: "passed"
    }' >"$VERIFICATION"
}

create_fixture_receipt() {
  bash "$SINK" receipt "${1:-$SOURCE}" "$(jq -r '.segment_index' "$REGISTRATION")" --verification "$VERIFICATION" \
    --dependency "${BATS_TEST_TMPDIR}/statement.json" \
    --dependency "${BATS_TEST_TMPDIR}/trust-policy.json" \
    --dependency "${BATS_TEST_TMPDIR}/verification-evidence.json"
}

verify_inventory_with_harness() {
  local test_python
  test_python="$(dirname "$ROBOTICS_CONTRACTS_CLI")/python"
  if [[ -f "${test_python}.exe" ]]; then test_python+='.exe'; fi
  "$test_python" - "$EVIDENCE_INDEX_PATH" "${BATS_TEST_TMPDIR}/receipt-inventory.json" "${1:-1}" <<'PY'
import sys
from robotics_acceptance_harness.evidence import load_evidence_index
from robotics_acceptance_harness.receipts import ReceiptInventory
evidence = load_evidence_index(sys.argv[1], receipt_paths=ReceiptInventory(sys.argv[2]))
assert len(evidence.receipts) == int(sys.argv[3])
PY
}

@test "a confirmed upload without a typed receipt cannot finalize retained evidence" {
  seed_remote_verification_fixture
  printf 'previous\n' >"$EVIDENCE_INDEX_PATH"
  run bash "$SINK" finalize
  assert_index_preserved
  [[ "$output" == *'verified artifact receipt is missing'* ]]
}

@test "remote index binds a receipt created from the supplied verification fixture" {
  seed_remote_verification_fixture
  create_fixture_receipt
  run bash "$SINK" finalize
  [ "$status" -eq 0 ]
  run "$ROBOTICS_CONTRACTS_CLI" validate --schema evidence-index.v1 --quiet "$EVIDENCE_INDEX_PATH"
  [ "$status" -eq 0 ]
  run jq -e --arg receipt "$(sha256sum "$RECEIPT" | cut -d' ' -f1)" '
    .policy_observation.remote_sink_used == true and
    .artifacts[0].storage_state == "retained" and
    .artifacts[0].immutable_revision == "fixture-version-1" and
    .artifacts[0].receipt_sha256 == $receipt' "$EVIDENCE_INDEX_PATH"
  [ "$status" -eq 0 ]
  run verify_inventory_with_harness
  [ "$status" -eq 0 ]
}

@test "receipt creation preserves previous output if verification describes another upload" {
  seed_remote_verification_fixture
  create_fixture_receipt
  local before
  before="$(sha256sum "$RECEIPT")"
  jq '.artifact.immutable_revision = "another-version"' "$VERIFICATION" \
    >"${BATS_TEST_TMPDIR}/changed.json"
  mv "${BATS_TEST_TMPDIR}/changed.json" "$VERIFICATION"
  run create_fixture_receipt
  [ "$status" -ne 0 ]
  [[ "$output" == *'receipt does not match the uploaded artifact and run'* ]]
  [ "$(sha256sum "$RECEIPT")" = "$before" ]
  [ -z "$(find "$EVIDENCE_RECEIPT_DIR" -name '.receipt*' -print -quit)" ]
}

@test "shared provenance is listed once for distinct retained artifacts" {
  seed_remote_verification_fixture 7
  create_fixture_receipt
  SOURCE="${BATS_TEST_TMPDIR}/second-metrics.jsonl"
  printf '{"resourceMetrics":[],"fixture":2}\n' >"$SOURCE"
  seed_remote_verification_fixture 8
  create_fixture_receipt
  run bash "$SINK" finalize
  [ "$status" -eq 0 ]
  run jq -e '(.receipts | length) == 2 and (.verifications | length) == 2 and
    (.dependencies | length) == 3' "${BATS_TEST_TMPDIR}/receipt-inventory.json"
  [ "$status" -eq 0 ]
  run verify_inventory_with_harness 2
  [ "$status" -eq 0 ]
}

@test "receipt creation retains subsecond order after a fresh verification" {
  seed_remote_verification_fixture
  jq '.verified_at = "2026-09-08T12:00:00.800000Z"' "$VERIFICATION" \
    >"${BATS_TEST_TMPDIR}/recent.json"
  mv "${BATS_TEST_TMPDIR}/recent.json" "$VERIFICATION"
  date() { command date --date='2026-09-08T12:00:00.900000000Z' "$@"; }
  export -f date
  run create_fixture_receipt
  [ "$status" -eq 0 ]
  run jq -e '.created_at == "2026-09-08T12:00:00.900000000Z"' "$RECEIPT"
  [ "$status" -eq 0 ]
}

@test "changed provenance cannot replace an existing inventory or index" {
  seed_remote_verification_fixture
  create_fixture_receipt
  printf 'changed statement\n' >"${BATS_TEST_TMPDIR}/statement.json"
  printf 'previous\n' >"$EVIDENCE_INDEX_PATH"
  printf 'previous inventory\n' >"${BATS_TEST_TMPDIR}/receipt-inventory.json"
  run bash "$SINK" finalize
  assert_index_preserved
  [[ "$output" == *'provenance dependencies are missing'* ]]
  [ "$(cat "${BATS_TEST_TMPDIR}/receipt-inventory.json")" = 'previous inventory' ]
}

@test "inventory output cannot replace local evidence" {
  SOURCE="${BATS_TEST_TMPDIR}/receipt-inventory.json"
  printf 'original evidence\n' >"$SOURCE"
  register_local
  printf 'previous\n' >"$EVIDENCE_INDEX_PATH"
  run bash "$SINK" finalize
  assert_index_preserved
  [[ "$output" == *'inventory output must not replace an evidence input'* ]]
  [ "$(cat "$SOURCE")" = 'original evidence' ]
}

@test "receipt output cannot replace the upload registration" {
  seed_remote_verification_fixture
  local before
  before="$(sha256sum "$REGISTRATION")"
  export EVIDENCE_RECEIPT_DIR="$EVIDENCE_REGISTRATION_DIR"
  run create_fixture_receipt
  [ "$status" -ne 0 ]
  [[ "$output" == *'receipt output must not replace an input'* ]]
  [ "$(sha256sum "$REGISTRATION")" = "$before" ]
}

@test "receipt input binding reserves the inventory output path" {
  seed_remote_verification_fixture
  create_fixture_receipt
  run "$ROBOTICS_RECEIPT_INPUTS_CLI" bind --root "$BATS_TEST_TMPDIR" \
    --registration "$REGISTRATION" --receipt "$RECEIPT" \
    --destination "${BATS_TEST_TMPDIR}/receipt-inventory.json" \
    --verification "$VERIFICATION" \
    --dependency "${BATS_TEST_TMPDIR}/statement.json" \
    --dependency "${BATS_TEST_TMPDIR}/trust-policy.json" \
    --dependency "${BATS_TEST_TMPDIR}/verification-evidence.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *'receipt output must not replace the receipt inventory'* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/receipt-inventory.json" ]
}

@test "final index destination cannot alias a registered evidence source" {
  register_local
  local before
  before="$(sha256sum "$SOURCE")"
  run env EVIDENCE_INDEX_PATH="$SOURCE" bash "$SINK" finalize
  [ "$status" -ne 0 ]
  [[ "$output" == *'index output must not replace an evidence input'* ]]
  [ "$(sha256sum "$SOURCE")" = "$before" ]
}

@test "receipt destination cannot alias its source file" {
  seed_remote_verification_fixture
  mkdir -p "$EVIDENCE_RECEIPT_DIR"
  cp "$SOURCE" "$RECEIPT"
  local before
  before="$(sha256sum "$RECEIPT")"
  run create_fixture_receipt "$RECEIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *'receipt output must not replace an input'* ]]
  [ "$(sha256sum "$RECEIPT")" = "$before" ]
}
