#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  CORE="${REPOSITORY_ROOT}/docker/permit-preflight/core.sh"
  FIXTURES="${REPOSITORY_ROOT}/dependencies/robotics-runtime/packages/contracts/tests/fixtures/qualification/physical"
  TEMPLATE="${REPOSITORY_ROOT}/test/physical/hil-runtime.input.json"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI before these tests}"
  export ROBOTICS_CONTRACTS_CLI
}

@test "physical preflight writes a v1 runtime with the input authorization digests" {
  run bash -c '
    set -Eeuo pipefail
    source "$1"
    robotics-contracts() { "$ROBOTICS_CONTRACTS_CLI" "$@"; }
    printf "{}\n" >"$4/trust-policy.json"
    materialize_runtime "$2" "$3/permit.json" "$3/verification.json" \
      "$4/trust-policy.json" "$4/runtime.json"
    "$ROBOTICS_CONTRACTS_CLI" validate --schema runtime-manifest.v1 --quiet "$4/runtime.json"
    jq -e \
      --arg permit "$(sha256_file "$3/permit.json")" \
      --arg verification "$(sha256_file "$3/verification.json")" \
      --arg policy "$(sha256_file "$4/trust-policy.json")" \
      ".authorization.permit_sha256 == \$permit and
       .authorization.execution_verification_sha256 == \$verification and
       .authorization.trust_policy_sha256 == \$policy" "$4/runtime.json"
    if [[ "$(uname -s)" == Linux ]]; then
      test "$(stat -c %a "$4/runtime.json")" = 444
    fi
  ' _ "$CORE" "$TEMPLATE" "$FIXTURES" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

@test "physical preflight rejects a valid document of the wrong caller role" {
  local role
  for role in template permit verification; do
    run bash -c '
      set -Eeuo pipefail
      source "$1"
      robotics-contracts() { "$ROBOTICS_CONTRACTS_CLI" "$@"; }
      template_input="$2"
      permit_input="$3/permit.json"
      verification_input="$3/verification.json"
      case "$5" in
        template) template_input="$permit_input" ;;
        permit) permit_input="$verification_input" ;;
        verification) verification_input="$permit_input" ;;
      esac
      printf "{}\n" >"$4/trust-policy.json"
      materialize_runtime "$template_input" "$permit_input" "$verification_input" \
        "$4/trust-policy.json" "$4/runtime.json"
    ' _ "$CORE" "$TEMPLATE" "$FIXTURES" "$BATS_TEST_TMPDIR" "$role"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[schema.validation_failed]"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/runtime.json" ]
  done
}

@test "physical clock facts retain absolute maxima from both supported instruments" {
  run bash -c '
    set -Eeuo pipefail
    source "$1/scripts/ci/physical-attach/observation.sh"
    jq -n "{resourceMetrics:[{scopeMetrics:[{metrics:[
      {name:\"robotics.hardware.clock.offset\",gauge:{dataPoints:[{asDouble:-0.75},{asDouble:0.1}]}},
      {name:\"robotics.hardware.clock.drift\",sum:{dataPoints:[{asInt:\"-2\"},{asInt:\"1\"}]}},
      {name:\"unrelated\",histogram:{dataPoints:[]}}
    ]}]}]}" >"$2/time.jsonl"
    write_clock_facts "$2/time.jsonl" "$2/clock.json"
    jq -e ".offset_ms == 0.75 and .drift_ppm == 2" "$2/clock.json"
  ' _ "$REPOSITORY_ROOT" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

@test "physical runtime retention preserves public evidence and excludes unknown files" {
  run bash -c '
    set -Eeuo pipefail
    source "$1/scripts/ci/physical-attach/observation.sh"
    work_root="$2"
    report_output="$2/physical.json"
    case_report="$2/report.json"
    printf "{}\n" >"$case_report"
    mkdir -p "$2/runtime/inputs" "$2/runtime/provider" "$2/preflight-positive/output"
    for filename in template.json host-platform.json target-evidence.json serial-received.txt \
      serial-reverse-received.txt can-received.txt clock.json observer.policy.xml; do
      printf "observation\n" >"$2/runtime/inputs/$filename"
    done
    for filename in profile.json configuration.json conformance.json runtime-manifest.input.json; do
      printf "document\n" >"$2/runtime/provider/$filename"
    done
    printf "private fixture\n" >"$2/runtime/inputs/private.key"
    printf "runtime\n" >"$2/preflight-positive/output/runtime-manifest.json"
    retain_runtime_evidence
    retained="$2/$(jq -er .runtime_evidence_directory "$case_report")"
    cmp "$retained/provider/conformance.json" "$2/runtime/provider/conformance.json"
    cmp "$retained/inputs/serial-received.txt" "$2/runtime/inputs/serial-received.txt"
    cmp "$retained/runtime-manifest.json" "$2/preflight-positive/output/runtime-manifest.json"
    test ! -e "$retained/inputs/private.key"
  ' _ "$REPOSITORY_ROOT" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}
