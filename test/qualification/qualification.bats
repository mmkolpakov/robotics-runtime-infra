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

@test "rejects a schema-invalid result before statement creation" {
  mapfile -t args < <(artifact_arguments)
  jq 'del(.run_id)' "$TEST_ROOT/artifacts/result.json" \
    >"$TEST_ROOT/artifacts/result.invalid.json"
  mv "$TEST_ROOT/artifacts/result.invalid.json" \
    "$TEST_ROOT/artifacts/result.json"

  run "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" --output "$TEST_ROOT/artifacts/invalid-statement.json"

  [ "$status" -ne 0 ]
  [[ "$output" == *"one or more documents do not satisfy"* ]]
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
