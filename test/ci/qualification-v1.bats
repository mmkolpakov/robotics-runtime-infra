#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  CREATE="$ROOT/scripts/qualification/create-statement"
  VERIFY="$ROOT/scripts/qualification/verify-bundle"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI before these tests}"
  export QUALIFICATION_TEST_ROOT="$BATS_TEST_TMPDIR/qualification"
  CASE="$QUALIFICATION_TEST_ROOT/transport"
  mkdir -p "$QUALIFICATION_TEST_ROOT/bin" "$QUALIFICATION_TEST_ROOT/work"
  # Inputs belong to the exact pinned workspace. This tests the infra adapter;
  # these provider/ROS observations and the verifier below are explicit fixtures.
  cp -R "$ROOT/dependencies/robotics-runtime/packages/contracts/tests/fixtures/qualification/transport" "$CASE"
  printf 'original diagnostics\n' >"$QUALIFICATION_TEST_ROOT/diagnostics.txt"
  printf '{"trustedRoot":"fixture"}\n' >"$QUALIFICATION_TEST_ROOT/trusted-root.json"
  jq -n --arg digest "$(sha256sum "$QUALIFICATION_TEST_ROOT/trusted-root.json" | cut -d' ' -f1)" '{
    schema_version: "qualification-policy.v1", policy_id: "fixture-policy",
    predicate_type: "https://robotics-runtime-contracts.dev/attestations/qualification-bundle/v1",
    certificate_identities: ["https://example.invalid/qualification"],
    certificate_oidc_issuer: "https://issuer.example.invalid",
    trusted_root_sha256: $digest,
    required_artifact_kinds: ["scenario", "runtime_manifest", "acceptance_run",
      "domain_result", "acceptance_aggregate", "evidence_index", "recording_summary"]
  }' >"$QUALIFICATION_TEST_ROOT/policy.json"
  cat >"$QUALIFICATION_TEST_ROOT/bin/cosign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == verify-blob-attestation ]]
shift
bundle='' digest='' identity='' issuer='' predicate='' trusted_root=''
while (($#)); do
  case "$1" in
    --bundle) bundle="$2"; shift 2 ;;
    --digest) digest="$2"; shift 2 ;;
    --digestAlg) [[ "$2" == sha256 ]]; shift 2 ;;
    --certificate-identity) identity="$2"; shift 2 ;;
    --certificate-oidc-issuer) issuer="$2"; shift 2 ;;
    --type) predicate="$2"; shift 2 ;;
    --trusted-root) trusted_root="$2"; shift 2 ;;
    *) exit 64 ;;
  esac
done
[[ -f "$bundle" && -f "$trusted_root" ]]
[[ "$bundle" != "$QUALIFICATION_TEST_ROOT/bundle.json" ]]
[[ "$trusted_root" != "$QUALIFICATION_TEST_ROOT/trusted-root.json" ]]
[[ "$identity" == https://example.invalid/qualification ]]
[[ "$issuer" == https://issuer.example.invalid ]]
[[ "$predicate" == https://robotics-runtime-contracts.dev/attestations/qualification-bundle/v1 ]]
[[ "$digest" == "$(sha256sum "$QUALIFICATION_TEST_ROOT/transport/aggregate.json" | cut -d' ' -f1)" ]]
printf 'called\n' >>"$QUALIFICATION_TEST_ROOT/verifier.log"
case "${QUALIFICATION_TEST_ACTION:-}" in
  reject) exit 1 ;;
  replace-original) printf '{}\n' >"$QUALIFICATION_TEST_ROOT/bundle.json" ;;
  change-subject) printf 'changed after verification\n' >"$QUALIFICATION_TEST_ROOT/diagnostics.txt" ;;
esac
SH
  chmod +x "$QUALIFICATION_TEST_ROOT/bin/cosign"
  export PATH="$QUALIFICATION_TEST_ROOT/bin:$PATH"
  unset QUALIFICATION_TEST_ACTION
  ARGS=()
  local kind subject file
  while IFS=$'\t' read -r kind subject file; do
    ARGS+=(--artifact "$kind:$subject=$CASE/$file")
  done < <(jq -r '.[] | [.kind, .subject_name, .file] | @tsv' "$CASE/artifacts.json")
  ARGS+=(--evidence "other_evidence:diagnostics.txt=$QUALIFICATION_TEST_ROOT/diagnostics.txt")
}

create_bundle() {
  bash "$CREATE" "${ARGS[@]}" --output "$QUALIFICATION_TEST_ROOT/statement.json"
  jq -n --arg payload "$(base64 -w 0 "$QUALIFICATION_TEST_ROOT/statement.json")" '{
    mediaType: "application/vnd.dev.sigstore.bundle.v0.3+json",
    dsseEnvelope: {payloadType: "application/vnd.in-toto+json", payload: $payload,
      signatures: [{sig: "explicit-verifier-fixture"}]}, verificationMaterial: {}
  }' >"$QUALIFICATION_TEST_ROOT/bundle.json"
}

verify_bundle() {
  TMPDIR="$QUALIFICATION_TEST_ROOT/work" bash "$VERIFY" "${ARGS[@]}" \
    --bundle "$QUALIFICATION_TEST_ROOT/bundle.json" \
    --trusted-root "$QUALIFICATION_TEST_ROOT/trusted-root.json" \
    --policy "$QUALIFICATION_TEST_ROOT/policy.json"
}

@test "qualification adapter produces exactly the public v1 writer bytes" {
  create_bundle
  # The public CLI receives the same native inventory plus the adapter's label.
  local command=("$ROBOTICS_CONTRACTS_CLI" qualification statement)
  command+=("${ARGS[@]:0:${#ARGS[@]}-2}")
  command+=(--artifact "other_evidence:evidence/diagnostics.txt=$QUALIFICATION_TEST_ROOT/diagnostics.txt")
  "${command[@]}" --output "$QUALIFICATION_TEST_ROOT/direct.json"
  cmp --silent "$QUALIFICATION_TEST_ROOT/statement.json" "$QUALIFICATION_TEST_ROOT/direct.json"
  run verify_bundle
  [ "$status" -eq 0 ]
  [[ "$output" == *'qualification bundle verified'* ]]
  [ -z "$(find "$QUALIFICATION_TEST_ROOT/work" -mindepth 1 -print -quit)" ]
}

@test "named v1 flags preserve the native artifact inventory" {
  create_bundle
  local named=() kind subject file path label
  while IFS=$'\t' read -r kind subject file; do
    path="$CASE/$file"
    label="${subject##*/}"
    label="${label%.json}"
    case "$kind" in
      scenario) named+=(--scenario "$path") ;;
      acceptance_run) named+=(--acceptance-run "$path") ;;
      acceptance_aggregate) named+=(--aggregate "$path") ;;
      runtime_manifest) named+=(--runtime-manifest "$label=$path") ;;
      domain_result) named+=(--result "$label=$path") ;;
      evidence_index) named+=(--evidence-index "$label=$path") ;;
      recording_summary) named+=(--recording-summary "$label=$path") ;;
      transport_qualification) named+=(--transport-qualification "$path") ;;
      *) named+=(--artifact "$kind:$subject=$path") ;;
    esac
  done < <(jq -r '.[] | [.kind, .subject_name, .file] | @tsv' "$CASE/artifacts.json")
  named+=(--evidence "other_evidence:diagnostics.txt=$QUALIFICATION_TEST_ROOT/diagnostics.txt")
  run bash "$CREATE" "${named[@]}" --output "$QUALIFICATION_TEST_ROOT/named.json"
  [ "$status" -eq 0 ]
  cmp --silent "$QUALIFICATION_TEST_ROOT/named.json" "$QUALIFICATION_TEST_ROOT/statement.json"
}

@test "qualification rejects a multi-document bundle before verification" {
  create_bundle
  printf '{}\n' >>"$QUALIFICATION_TEST_ROOT/bundle.json"
  run verify_bundle
  [ "$status" -eq 65 ]
  [[ "$output" == *'expected exactly one JSON document'* ]]
  [ ! -f "$QUALIFICATION_TEST_ROOT/verifier.log" ]
  [ -z "$(find "$QUALIFICATION_TEST_ROOT/work" -mindepth 1 -print -quit)" ]
}

@test "qualification verifies and consumes one private bundle snapshot" {
  create_bundle
  local QUALIFICATION_TEST_ACTION=replace-original
  export QUALIFICATION_TEST_ACTION
  run verify_bundle
  [ "$status" -eq 0 ]
  [ "$(cat "$QUALIFICATION_TEST_ROOT/bundle.json")" = '{}' ]
  [ -z "$(find "$QUALIFICATION_TEST_ROOT/work" -mindepth 1 -print -quit)" ]
}

@test "qualification rechecks subject bytes after external signature verification" {
  create_bundle
  local QUALIFICATION_TEST_ACTION=change-subject
  export QUALIFICATION_TEST_ACTION
  run verify_bundle
  [ "$status" -eq 65 ]
  [[ "$output" == *'[qualification.statement_mismatch]'* ]]
  [ -z "$(find "$QUALIFICATION_TEST_ROOT/work" -mindepth 1 -print -quit)" ]
}

@test "qualification rejects external verifier failure and removes temporary files" {
  create_bundle
  local QUALIFICATION_TEST_ACTION=reject
  export QUALIFICATION_TEST_ACTION
  run verify_bundle
  [ "$status" -eq 65 ]
  [[ "$output" == *'Sigstore verification failed'* ]]
  [ -z "$(find "$QUALIFICATION_TEST_ROOT/work" -mindepth 1 -print -quit)" ]
}

@test "qualification rejects unbound provider evidence before invoking the verifier" {
  create_bundle
  printf '\n' >>"$CASE/provider-config.json"
  run verify_bundle
  [ "$status" -eq 65 ]
  [[ "$output" == *'qualification artifact set is invalid'* ]]
  [ ! -f "$QUALIFICATION_TEST_ROOT/verifier.log" ]
}

@test "qualification rejects a policy whose required evidence kind is absent" {
  create_bundle
  jq '.required_artifact_kinds += ["junit"]' "$QUALIFICATION_TEST_ROOT/policy.json" \
    >"$QUALIFICATION_TEST_ROOT/new-policy.json"
  mv "$QUALIFICATION_TEST_ROOT/new-policy.json" "$QUALIFICATION_TEST_ROOT/policy.json"
  run verify_bundle
  [ "$status" -eq 65 ]
  [[ "$output" == *'missing policy-required artifact kinds: junit'* ]]
  [ ! -f "$QUALIFICATION_TEST_ROOT/verifier.log" ]
}

@test "qualification rejects a different trust root before invoking the verifier" {
  create_bundle
  printf '\n' >>"$QUALIFICATION_TEST_ROOT/trusted-root.json"
  run verify_bundle
  [ "$status" -eq 65 ]
  [[ "$output" == *'trusted root digest does not match'* ]]
  [ ! -f "$QUALIFICATION_TEST_ROOT/verifier.log" ]
}

@test "qualification refuses to replace an input subject or existing output on invalid inventory" {
  local source="$QUALIFICATION_TEST_ROOT/diagnostics.txt"
  run bash "$CREATE" "${ARGS[@]}" --output "$source"
  [ "$status" -eq 65 ]
  [[ "$output" == *'must not replace input'* ]]
  [ "$(cat "$source")" = 'original diagnostics' ]
  printf 'previous statement\n' >"$QUALIFICATION_TEST_ROOT/statement.json"
  run bash "$CREATE" "${ARGS[@]}" --artifact "other_evidence:evidence/diagnostics.txt=$source" \
    --output "$QUALIFICATION_TEST_ROOT/statement.json"
  [ "$status" -eq 65 ]
  [[ "$output" == *'unique'* ]]
  [ "$(cat "$QUALIFICATION_TEST_ROOT/statement.json")" = 'previous statement' ]
}
