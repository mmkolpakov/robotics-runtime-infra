#!/usr/bin/env bats

setup() {
  export REPOSITORY_ROOT
  REPOSITORY_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export ROBOTICS_CONTRACT_SCHEMA_DIR="${ROBOTICS_CONTRACT_SCHEMA_DIR:-$REPOSITORY_ROOT/../robotics-runtime-contracts/src/robotics_runtime_contracts/schemas}"
  export TEST_ROOT="$BATS_TEST_TMPDIR/qualification"
  export TEST_BIN="$TEST_ROOT/bin"
  mkdir -p "$TEST_BIN" "$TEST_ROOT/artifacts"
  export PATH="$TEST_BIN:$PATH"
  export EXPECTED_IDENTITY='https://github.com/example/robotics/.github/workflows/qualification.yml@refs/heads/main'
  export EXPECTED_ISSUER='https://token.actions.githubusercontent.com'
  export COSIGN_TEST_BUNDLE_IDENTITY="$EXPECTED_IDENTITY"
  export COSIGN_TEST_BUNDLE_ISSUER="$EXPECTED_ISSUER"

cat >"$TEST_BIN/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == verify-blob-attestation ]]
shift
identity=''
issuer=''
bundle=''
trusted_root=''
digest=''
digest_algorithm=''
predicate_type=''
while (($# > 0)); do
  case "$1" in
    --bundle)
      bundle="$2"
      shift 2
      ;;
    --trusted-root)
      trusted_root="$2"
      shift 2
      ;;
    --certificate-identity)
      identity="$2"
      shift 2
      ;;
    --certificate-oidc-issuer)
      issuer="$2"
      shift 2
      ;;
    --digest)
      digest="$2"
      shift 2
      ;;
    --digestAlg)
      digest_algorithm="$2"
      shift 2
      ;;
    --type)
      predicate_type="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -f "$bundle" && -f "$trusted_root" ]]
[[ "$digest" == "$(sha256sum "$TEST_ROOT/artifacts/aggregate.json" | cut -d' ' -f1)" ]]
[[ "$digest_algorithm" == sha256 ]]
[[ "$predicate_type" == \
  https://robotics-runtime-contracts.dev/attestations/qualification-bundle/v1 ]]
[[ "$identity" == "$COSIGN_TEST_BUNDLE_IDENTITY" &&
  "$issuer" == "$COSIGN_TEST_BUNDLE_ISSUER" ]]
EOF
  chmod +x "$TEST_BIN/cosign"
  create_artifacts
}

sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

create_artifacts() {
  local artifacts="$TEST_ROOT/artifacts"
  local run_id='run-00000000-0000-4000-8000-000000000001'
  local result_id='result-00000000-0000-4000-8000-000000000001'

  printf '{"schema_version":"acceptance-scenario.v2"}\n' >"$artifacts/scenario.json"
  printf '{"schema_version":"runtime-manifest.v1"}\n' >"$artifacts/runtime.json"
  printf '{"diagnostics":"nominal"}\n' >"$artifacts/diagnostics.json"
  printf '{"schema_version":"mcap-summary.v1","run_id":"%s"}\n' \
    "$run_id" >"$artifacts/mcap-summary.json"

  local scenario_sha256
  local runtime_sha256
  local mcap_sha256
  scenario_sha256="$(sha256 "$artifacts/scenario.json")"
  runtime_sha256="$(sha256 "$artifacts/runtime.json")"
  mcap_sha256="$(sha256 "$artifacts/mcap-summary.json")"

  jq -n \
    --arg run_id "$run_id" \
    --arg scenario_sha256 "$scenario_sha256" \
    '{
      schema_version: "acceptance-run.v1",
      run_id: $run_id,
      created_at: "2026-07-26T12:00:00Z",
      scenario_id: "qualification-smoke",
      scenario_sha256: $scenario_sha256,
      time_authority: {kind: "sim_clock", source_id: "gazebo"},
      domains: [{domain_id: "control", role: "controller"}]
    }' >"$artifacts/run.json"
  local run_sha256
  run_sha256="$(sha256 "$artifacts/run.json")"

  jq -n \
    --arg run_id "$run_id" \
    --arg result_id "$result_id" \
    --arg runtime_sha256 "$runtime_sha256" \
    '{
      schema_version: "acceptance-result.v2",
      result_id: $result_id,
      run_id: $run_id,
      domain_id: "control",
      runtime_manifest_sha256: $runtime_sha256,
      status: "passed"
    }' >"$artifacts/result.json"
  local result_sha256
  result_sha256="$(sha256 "$artifacts/result.json")"

  jq -n \
    --arg run_id "$run_id" \
    --arg run_sha256 "$run_sha256" \
    --arg result_id "$result_id" \
    --arg result_sha256 "$result_sha256" \
    '{
      schema_version: "acceptance-aggregate.v2",
      run_id: $run_id,
      acceptance_run_sha256: $run_sha256,
      generated_at: "2026-07-26T12:05:00Z",
      per_domain_results: [{
        domain_id: "control",
        result_id: $result_id,
        result_sha256: $result_sha256,
        status: "passed"
      }]
    }' >"$artifacts/aggregate.json"

  jq -n \
    --arg run_id "$run_id" \
    --arg mcap_sha256 "$mcap_sha256" \
    '{
      schema_version: "evidence-index.v2",
      run_id: $run_id,
      segments: [{
        media_type: "application/mcap",
        mcap_summary: {sha256: $mcap_sha256}
      }]
    }' >"$artifacts/evidence-index.json"
  printf '{"trustedRoot":"fixture"}\n' >"$artifacts/trusted-root.json"
  create_policy "$EXPECTED_IDENTITY" "$EXPECTED_ISSUER"
}

create_policy() {
  local identity="$1"
  local issuer="$2"
  local trusted_root_sha256
  trusted_root_sha256="$(sha256 "$TEST_ROOT/artifacts/trusted-root.json")"
  jq -n \
    --arg identity "$identity" \
    --arg issuer "$issuer" \
    --arg trusted_root_sha256 "$trusted_root_sha256" \
    '{
      schema_version: "qualification-policy.v1",
      policy_id: "qualification-main",
      predicate_type: "https://robotics-runtime-contracts.dev/attestations/qualification-bundle/v1",
      certificate_identities: [$identity],
      certificate_oidc_issuer: $issuer,
      trusted_root_sha256: $trusted_root_sha256,
      required_artifact_kinds: [
        "scenario",
        "runtime_manifest",
        "acceptance_run",
        "domain_result",
        "acceptance_aggregate",
        "evidence_index",
        "mcap_summary"
      ]
    }' >"$TEST_ROOT/artifacts/policy.json"
}

artifact_arguments() {
  cat <<EOF
--scenario
$TEST_ROOT/artifacts/scenario.json
--runtime-manifest
control=$TEST_ROOT/artifacts/runtime.json
--acceptance-run
$TEST_ROOT/artifacts/run.json
--result
control=$TEST_ROOT/artifacts/result.json
--aggregate
$TEST_ROOT/artifacts/aggregate.json
--evidence-index
control=$TEST_ROOT/artifacts/evidence-index.json
--mcap-summary
control-0=$TEST_ROOT/artifacts/mcap-summary.json
--evidence
other_evidence:diagnostics.json=$TEST_ROOT/artifacts/diagnostics.json
EOF
}

create_statement_and_bundle() {
  mapfile -t args < <(artifact_arguments)
  "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" --output "$TEST_ROOT/artifacts/statement.json"
  local payload
  payload="$(base64 -w 0 "$TEST_ROOT/artifacts/statement.json")"
  jq -n --arg payload "$payload" '{
    mediaType: "application/vnd.dev.sigstore.bundle.v0.3+json",
    dsseEnvelope: {
      payloadType: "application/vnd.in-toto+json",
      payload: $payload,
      signatures: [{sig: "verified-by-cosign-test-double"}]
    },
    verificationMaterial: {}
  }' >"$TEST_ROOT/artifacts/bundle.json"
}

verify_bundle() {
  mapfile -t args < <(artifact_arguments)
  "$REPOSITORY_ROOT/scripts/qualification/verify-bundle" \
    --bundle "$TEST_ROOT/artifacts/bundle.json" \
    --trusted-root "$TEST_ROOT/artifacts/trusted-root.json" \
    --policy "$TEST_ROOT/artifacts/policy.json" \
    "${args[@]}"
}

@test "verifies a bundle with the exact local subject set" {
  create_statement_and_bundle

  run verify_bundle

  [ "$status" -eq 0 ]
  [[ "$output" == *'qualification bundle verified'* ]]
}

@test "produces a byte-for-byte deterministic canonical statement" {
  create_statement_and_bundle
  cp "$TEST_ROOT/artifacts/statement.json" "$TEST_ROOT/artifacts/statement.first.json"
  mapfile -t args < <(artifact_arguments)

  run "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" --output "$TEST_ROOT/artifacts/statement.second.json"

  [ "$status" -eq 0 ]
  cmp --silent \
    "$TEST_ROOT/artifacts/statement.first.json" \
    "$TEST_ROOT/artifacts/statement.second.json"
  run jq -e '.subject == (.subject | sort_by(.name))' \
    "$TEST_ROOT/artifacts/statement.second.json"
  [ "$status" -eq 0 ]
}

@test "rejects a locally tampered subject after signature verification" {
  create_statement_and_bundle
  printf '{"diagnostics":"tampered"}\n' >"$TEST_ROOT/artifacts/diagnostics.json"

  run verify_bundle

  [ "$status" -ne 0 ]
  [[ "$output" == *'authenticated statement does not exactly match'* ]]
}

@test "rejects a certificate identity outside the independent policy" {
  create_statement_and_bundle
  export COSIGN_TEST_BUNDLE_IDENTITY='https://github.com/example/robotics/.github/workflows/foreign.yml@refs/heads/main'

  run verify_bundle

  [ "$status" -ne 0 ]
  [[ "$output" == *'Sigstore verification failed'* ]]
}

@test "rejects a bundle issued outside the independent policy" {
  create_statement_and_bundle
  export COSIGN_TEST_BUNDLE_ISSUER='https://issuer.example.invalid'

  run verify_bundle

  [ "$status" -ne 0 ]
  [[ "$output" == *'Sigstore verification failed'* ]]
}
