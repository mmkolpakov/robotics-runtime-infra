#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export AWS_ACCESS_KEY_ID=test-key
  export AWS_SECRET_ACCESS_KEY=test-secret
  export AWS_SESSION_TOKEN=test-session
  export AWS_DEFAULT_REGION=eu-north-1
  export AWS_ENDPOINT_URL=http://s3.example.test:9000
  export EVIDENCE_MODE=s3
  export ROBOTICS_RUN_ID=run-00000000-0000-4000-8000-000000000001
  unset RCLONE_REMOTE RCLONE_S3_PROVIDER
}

@test "production S3 services configure the selected default remote and AWS credentials" {
  docker compose -f "${ROOT}/compose.evidence.yaml" --profile evidence \
    config --format json >"${BATS_TEST_TMPDIR}/model.json"
  run jq -e '
    all(.services[]; .environment as $e |
      $e.EVIDENCE_MODE == "s3" and $e.RCLONE_REMOTE == "evidence" and
      $e.RCLONE_CONFIG == "/dev/null" and
      $e.RCLONE_CONFIG_EVIDENCE_TYPE == "s3" and
      $e.RCLONE_CONFIG_EVIDENCE_ENV_AUTH == "true" and
      $e.RCLONE_CONFIG_EVIDENCE_REGION == $e.AWS_DEFAULT_REGION and
      $e.RCLONE_CONFIG_EVIDENCE_ENDPOINT == $e.AWS_ENDPOINT_URL and
      $e.RCLONE_CONFIG_EVIDENCE_PROVIDER == "AWS" and
      $e.AWS_ACCESS_KEY_ID == "test-key" and
      $e.AWS_SECRET_ACCESS_KEY == "test-secret" and
      $e.AWS_SESSION_TOKEN == "test-session" and
      ($e | has("RCLONE_CONFIG_EVIDENCE_ACCESS_KEY_ID") | not))
  ' "${BATS_TEST_TMPDIR}/model.json"
  [ "${status}" -eq 0 ]
}

@test "S3 integration overlay inherits production remote type and env authentication" {
  docker compose -f "${ROOT}/compose.evidence.yaml" \
    -f "${ROOT}/compose.evidence.test.yaml" --profile evidence --profile test \
    config --format json >"${BATS_TEST_TMPDIR}/model.json"
  run jq -e '
    .services["evidence-finalize"].environment |
    .RCLONE_CONFIG_EVIDENCE_TYPE == "s3" and
    .RCLONE_CONFIG_EVIDENCE_ENV_AUTH == "true" and
    .RCLONE_CONFIG_EVIDENCE_ENDPOINT == .AWS_ENDPOINT_URL and
    .RCLONE_CONFIG_EVIDENCE_PROVIDER == "Other" and
    .AWS_ACCESS_KEY_ID == "robotics-test" and
    (has("RCLONE_CONFIG_EVIDENCE_SECRET_ACCESS_KEY") | not)
  ' "${BATS_TEST_TMPDIR}/model.json"
  [ "${status}" -eq 0 ]
}

@test "producer and observer share recording paths beneath the evidence index" {
  docker compose -f "${ROOT}/compose.yaml" -f "${ROOT}/compose.evidence.yaml" \
    --profile evidence --profile acceptance config --format json >"${BATS_TEST_TMPDIR}/model.json"
  run jq -e '
    .services as $services |
    $services["acceptance-observer"] as $observer |
    ($observer.volumes[] | select(.target == "/evidence/recordings")) as $recordings |
    ($observer.volumes[] | select(.target == "/evidence")) as $evidence |
    ($observer.command | index("--receipt-inventory")) as $flag |
    $recordings.read_only == true and $evidence.read_only == true and
    $flag != null and $observer.command[$flag + 1] == "/evidence/receipt-inventory.json" and
    all(["evidence-sink", "evidence-finalize"][]; $services[.] as $producer |
      $producer.environment.EVIDENCE_SPOOL_DIR == $recordings.target and
      any($producer.volumes[]; .target == $recordings.target and .source == $recordings.source) and
      any($producer.volumes[]; .target == $evidence.target and .source == $evidence.source))
  ' "${BATS_TEST_TMPDIR}/model.json"
  [ "${status}" -eq 0 ]
}
