#!/usr/bin/env bats

setup() {
  export REPOSITORY_ROOT
  REPOSITORY_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export FIXTURES="$REPOSITORY_ROOT/test/qualification/fixtures"
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
  https://robotics-runtime-contracts.dev/attestations/qualification-bundle/v2 ]]
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
  cp "$FIXTURES/acceptance-scenario.yaml" "$artifacts/scenario.yaml"
  cp "$FIXTURES/acceptance-run.json" "$artifacts/run.json"
  cp "$FIXTURES/runtime-manifest.json" "$artifacts/runtime.json"
  cp "$FIXTURES/acceptance-result.json" "$artifacts/result.json"
  cp "$FIXTURES/acceptance-aggregate.json" "$artifacts/aggregate.json"
  cp "$FIXTURES/evidence-index.json" "$artifacts/evidence-index.json"
  cp "$FIXTURES/mcap-summary.json" "$artifacts/mcap-summary.json"
  cp "$FIXTURES/diagnostics.json" "$artifacts/diagnostics.json"
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
      schema_version: "qualification-policy.v2",
      policy_id: "qualification-main",
      predicate_type: "https://robotics-runtime-contracts.dev/attestations/qualification-bundle/v2",
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
$TEST_ROOT/artifacts/scenario.yaml
--runtime-manifest
primary=$TEST_ROOT/artifacts/runtime.json
--acceptance-run
$TEST_ROOT/artifacts/run.json
--result
primary=$TEST_ROOT/artifacts/result.json
--aggregate
$TEST_ROOT/artifacts/aggregate.json
--evidence-index
primary=$TEST_ROOT/artifacts/evidence-index.json
--mcap-summary
control-0=$TEST_ROOT/artifacts/mcap-summary.json
--evidence
other_evidence:diagnostics.json=$TEST_ROOT/artifacts/diagnostics.json
--evidence
raw_mcap:recording-0.mcap=$REPOSITORY_ROOT/test/fixtures/playback/golden/golden_0.mcap
--evidence
metrics:metrics.otlp.json=$FIXTURES/metrics.otlp.json
--evidence
traces:traces.otlp.jsonl=$FIXTURES/traces.otlp.jsonl
EOF
  if [[ -f "$TEST_ROOT/artifacts/transport.json" ]]; then
    cat <<EOF
--runtime-manifest
secondary=$TEST_ROOT/artifacts/runtime.json
--result
secondary=$TEST_ROOT/artifacts/result-secondary.json
--transport-qualification
$TEST_ROOT/artifacts/transport.json
--evidence-index
secondary=$TEST_ROOT/artifacts/evidence-index-secondary.json
--evidence
causal_chain_contract:primary-to-secondary.json=$FIXTURES/transport-causal-chain.json
--evidence
channel_contract:primary-commands.json=$FIXTURES/transport-channel.json
--evidence
channel_observation:primary-commands-observation.json=$FIXTURES/transport-channel-observation.json
--evidence
traces:traces-secondary.otlp.jsonl=$FIXTURES/traces-secondary.otlp.jsonl
--evidence
other_evidence:zenoh-source.json5=$REPOSITORY_ROOT/config/zenoh/source.json5
EOF
  fi
}

create_evaluated_artifacts() {
  local artifacts="$TEST_ROOT/artifacts"
  cp "$FIXTURES/acceptance-run-transport.json" "$artifacts/run.json"
  cp "$FIXTURES/acceptance-result-secondary.json" \
    "$artifacts/result-secondary.json"
  cp "$FIXTURES/evidence-index-secondary.json" \
    "$artifacts/evidence-index-secondary.json"
  cp "$FIXTURES/transport-qualification.json" "$artifacts/transport.json"
  cp "$FIXTURES/acceptance-aggregate-transport.json" \
    "$artifacts/aggregate.json"
  jq '
    .required_artifact_kinds += [
      "transport_qualification",
      "causal_chain_contract",
      "channel_contract",
      "channel_observation"
    ]
  ' "$artifacts/policy.json" >"$artifacts/policy.updated.json"
  mv "$artifacts/policy.updated.json" "$artifacts/policy.json"
}

bind_primary_runtime() {
  local artifacts="$TEST_ROOT/artifacts"
  jq --arg digest "$(sha256 "$artifacts/runtime.json")" \
    '.runtime_manifest_sha256 = $digest' \
    "$artifacts/result.json" >"$artifacts/result.updated.json"
  mv "$artifacts/result.updated.json" "$artifacts/result.json"
  jq --arg digest "$(sha256 "$artifacts/result.json")" \
    '.per_domain_results[0].result_sha256 = $digest' \
    "$artifacts/aggregate.json" >"$artifacts/aggregate.updated.json"
  mv "$artifacts/aggregate.updated.json" "$artifacts/aggregate.json"
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

@test "verifies a fully bound evaluated transport qualification" {
  create_evaluated_artifacts
  create_statement_and_bundle

  run verify_bundle

  [ "$status" -eq 0 ]
  [[ "$output" == *'qualification bundle verified'* ]]
}

@test "rejects an unsupported scenario contract" {
  sed -i \
    's/schema_version: acceptance-scenario.v4/schema_version: acceptance-scenario.v3/' \
    "$TEST_ROOT/artifacts/scenario.yaml"
  mapfile -t args < <(artifact_arguments)

  run "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" --output "$TEST_ROOT/artifacts/statement.json"

  [ "$status" -eq 65 ]
  [[ "$output" == *"unsupported scenario schema_version 'acceptance-scenario.v3'"* ]]
  [[ "$output" == *'[qualification.invalid]'* ]]
}

@test "rejects a multi-document Sigstore bundle" {
  create_statement_and_bundle
  printf '%s\n' '{}' >>"$TEST_ROOT/artifacts/bundle.json"

  run verify_bundle

  [ "$status" -eq 65 ]
  [[ "$output" == *"expected exactly one JSON document"* ]]
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

@test "rejects a schema-invalid result before statement creation" {
  mapfile -t args < <(artifact_arguments)
  jq 'del(.run_id)' "$TEST_ROOT/artifacts/result.json" \
    >"$TEST_ROOT/artifacts/result.invalid.json"
  mv "$TEST_ROOT/artifacts/result.invalid.json" \
    "$TEST_ROOT/artifacts/result.json"

  run "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" --output "$TEST_ROOT/artifacts/invalid-statement.json"

  [ "$status" -ne 0 ]
  [[ "$output" == *"does not satisfy acceptance-result.v4"* ]]
}

@test "rejects an unretained Fast DDS profile referenced by a runtime manifest" {
  mapfile -t args < <(artifact_arguments)
  jq \
    '.data_plane.fastdds_profile_sha256 =
      "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$TEST_ROOT/artifacts/runtime.json" \
    >"$TEST_ROOT/artifacts/runtime.with-profile.json"
  mv "$TEST_ROOT/artifacts/runtime.with-profile.json" \
    "$TEST_ROOT/artifacts/runtime.json"
  bind_primary_runtime

  run "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" --output "$TEST_ROOT/artifacts/missing-profile-statement.json"

  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime manifest primary Fast DDS profile"* ]]
  [[ "$output" == *"retained raw artifact"* ]]
}

@test "binds a runtime manifest to retained Fast DDS profile bytes" {
  local profile="$REPOSITORY_ROOT/config/fastdds/udp-only.xml"
  local profile_sha256
  profile_sha256="$(sha256 "$profile")"
  jq --arg digest "$profile_sha256" \
    '.data_plane.fastdds_profile_sha256 = $digest' \
    "$TEST_ROOT/artifacts/runtime.json" \
    >"$TEST_ROOT/artifacts/runtime.with-profile.json"
  mv "$TEST_ROOT/artifacts/runtime.with-profile.json" \
    "$TEST_ROOT/artifacts/runtime.json"
  bind_primary_runtime
  mapfile -t args < <(artifact_arguments)

  run "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" \
    --evidence "other_evidence:fastdds-profile.xml=$profile" \
    --output "$TEST_ROOT/artifacts/profile-bound-statement.json"

  [ "$status" -eq 0 ]
  run jq -e --arg digest "$profile_sha256" '
    any(
      .subject[];
      .name == "evidence/fastdds-profile.xml" and
      .digest.sha256 == $digest
    )
  ' "$TEST_ROOT/artifacts/profile-bound-statement.json"
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
