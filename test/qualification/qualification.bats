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
aggregate="$TEST_ROOT/artifacts/acceptance-aggregate.json"
if [[ "$QUALIFICATION_FIXTURE_CASE" == transport ]]; then
  aggregate="$TEST_ROOT/artifacts/acceptance-aggregate-transport.json"
fi
[[ "$digest" == "${COSIGN_TEST_AGGREGATE_SHA256:-$(sha256sum "$aggregate" | cut -d' ' -f1)}" ]]
[[ "$digest_algorithm" == sha256 ]]
[[ "$predicate_type" == \
  https://robotics-runtime-contracts.dev/attestations/qualification-bundle/v1 ]]
[[ "$identity" == "$COSIGN_TEST_BUNDLE_IDENTITY" &&
  "$issuer" == "$COSIGN_TEST_BUNDLE_ISSUER" ]]
EOF
  chmod +x "$TEST_BIN/cosign"
  export QUALIFICATION_FIXTURE_CASE=single
  create_artifacts
}

sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

create_artifacts() {
  local artifacts="$TEST_ROOT/artifacts"
  cp "$FIXTURES/"* "$artifacts/"
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
        "recording_summary"
      ]
    }' >"$TEST_ROOT/artifacts/policy.json"
}

artifact_arguments() {
  jq -r --arg root "$TEST_ROOT/artifacts" '
    .artifacts[] | "--artifact", "\(.kind):\(.subject_name)=\($root)/\(.file)"
  ' "$FIXTURES/${QUALIFICATION_FIXTURE_CASE}-artifacts.json"
}

create_evaluated_artifacts() {
  export QUALIFICATION_FIXTURE_CASE=transport
  local artifacts="$TEST_ROOT/artifacts"
  jq '
    .required_artifact_kinds += [
      "transport_qualification", "causal_chain_contract", "channel_contract",
      "channel_observation", "clock_relation"
    ]
  ' "$artifacts/policy.json" >"$artifacts/policy.updated.json"
  mv "$artifacts/policy.updated.json" "$artifacts/policy.json"
}

bind_primary_runtime() {
  local artifacts="$TEST_ROOT/artifacts"
  jq --arg digest "$(sha256 "$artifacts/runtime-manifest.json")" \
    --slurpfile runtime "$artifacts/runtime-manifest.json" \
    '.runtime_manifest_sha256 = $digest |
     .runtime_observation.middleware_configuration_sha256 =
       $runtime[0].data_plane.middleware_configuration_sha256'  \
    "$artifacts/acceptance-result.json" >"$artifacts/result.updated.json"
  mv "$artifacts/result.updated.json" "$artifacts/acceptance-result.json"
  jq --arg digest "$(sha256 "$artifacts/acceptance-result.json")" \
    '.per_domain_results[0].result_sha256 = $digest' \
    "$artifacts/acceptance-aggregate.json" >"$artifacts/aggregate.updated.json"
  mv "$artifacts/aggregate.updated.json" "$artifacts/acceptance-aggregate.json"
}

create_statement_and_bundle() {
  mapfile -t args < <(artifact_arguments)
  "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" "$@" --output "$TEST_ROOT/artifacts/statement.json"
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
    's/schema_version: acceptance-scenario.v1/schema_version: acceptance-scenario.v3/' \
    "$TEST_ROOT/artifacts/acceptance-scenario.yaml"
  mapfile -t args < <(artifact_arguments)

  run "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" --output "$TEST_ROOT/artifacts/statement.json"

  [ "$status" -eq 65 ]
  [[ "$output" == *"unsupported scenario schema_version 'acceptance-scenario.v3'"* ]]
  [[ "$output" == *'"error_id": "qualification.invalid"'* ]]
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
  jq 'del(.run_id)' "$TEST_ROOT/artifacts/acceptance-result.json" \
    >"$TEST_ROOT/artifacts/result.invalid.json"
  mv "$TEST_ROOT/artifacts/result.invalid.json" \
    "$TEST_ROOT/artifacts/acceptance-result.json"

  run "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" --output "$TEST_ROOT/artifacts/invalid-statement.json"

  [ "$status" -ne 0 ]
  [[ "$output" == *"'run_id' is a required property"* ]]
  [[ "$output" == *'"error_id": "schema.validation_failed"'* ]]
}

@test "rejects an unretained Fast DDS profile referenced by a runtime manifest" {
  mapfile -t args < <(artifact_arguments)
  jq \
    '.data_plane.middleware_configuration_sha256 =
      "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$TEST_ROOT/artifacts/runtime-manifest.json" \
    >"$TEST_ROOT/artifacts/runtime.with-profile.json"
  mv "$TEST_ROOT/artifacts/runtime.with-profile.json" \
    "$TEST_ROOT/artifacts/runtime-manifest.json"
  bind_primary_runtime

  run "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" --output "$TEST_ROOT/artifacts/missing-profile-statement.json"

  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime manifest primary middleware configuration"* ]]
  [[ "$output" == *"retained raw artifact"* ]]
}

@test "binds a runtime manifest to retained Fast DDS profile bytes" {
  local profile="$TEST_ROOT/artifacts/fastdds-profile.xml"
  printf '\n' >>"$profile"
  local profile_sha256
  profile_sha256="$(sha256 "$profile")"
  jq --arg digest "$profile_sha256" \
    '.data_plane.middleware_configuration_sha256 = $digest' \
    "$TEST_ROOT/artifacts/runtime-manifest.json" \
    >"$TEST_ROOT/artifacts/runtime.with-profile.json"
  mv "$TEST_ROOT/artifacts/runtime.with-profile.json" \
    "$TEST_ROOT/artifacts/runtime-manifest.json"
  bind_primary_runtime
  mapfile -t args < <(artifact_arguments)

  run "$REPOSITORY_ROOT/scripts/qualification/create-statement" \
    "${args[@]}" \
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

package_inventory() {
  mapfile -t args < <(artifact_arguments)
  (
    cd "$TEST_ROOT"
    "$REPOSITORY_ROOT/scripts/qualification/package-artifacts" \
      --scenario "${PACKAGE_SCENARIO:-$TEST_ROOT/artifacts/acceptance-scenario.yaml}" "${args[@]:2}" \
      --output "$TEST_ROOT/portable" "$@"
  )
}

verify_portable() {
  local directory="$1"
  local trust="${2:-$TEST_ROOT/artifacts}"
  (
    cd "$directory"
    mapfile -t portable_arguments <qualification-arguments.txt
    "$REPOSITORY_ROOT/scripts/qualification/verify-bundle" \
      "${portable_arguments[@]}" --bundle "$trust/bundle.json" \
      --trusted-root "$trust/trusted-root.json" --policy "$trust/policy.json"
  )
}

@test "relocates exact YAML subjects and schema extras for independent verification" {
  local artifacts="$TEST_ROOT/artifacts"
  printf '%s\n' '{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}' \
    >"$artifacts/extension.schema.json"
  printf '%s\n' 'type: object' >"$artifacts/extension.schema.yaml"
  local nested="other_evidence:logs/copies/diagnostics.json=$artifacts/diagnostics.json"
  create_statement_and_bundle --artifact "$nested"

  run package_inventory --artifact "$nested" \
    --extension-schema "urn:test:json=$artifacts/extension.schema.json" \
    --extension-schema "urn:test:json-alias=$artifacts/extension.schema.json" \
    --extension-schema "urn:test:yaml=$artifacts/extension.schema.yaml"

  [ "$status" -eq 0 ]
  cmp "$artifacts/acceptance-scenario.yaml" \
    "$TEST_ROOT/portable/subjects/scenario.json.yaml"
  cmp "$artifacts/diagnostics.json" \
    "$TEST_ROOT/portable/subjects/logs/copies/diagnostics.json"
  cmp "$artifacts/extension.schema.yaml" \
    "$TEST_ROOT/portable/extension-schemas/$(sha256 "$artifacts/extension.schema.yaml")/extension.schema.yaml"
  run grep -F "$TEST_ROOT" "$TEST_ROOT/portable/qualification-arguments.txt"
  [ "$status" -eq 1 ]
  mkdir "$TEST_ROOT/independent-trust"
  cp "$artifacts/bundle.json" "$artifacts/trusted-root.json" "$artifacts/policy.json" \
    "$TEST_ROOT/independent-trust/"
  export COSIGN_TEST_AGGREGATE_SHA256
  COSIGN_TEST_AGGREGATE_SHA256="$(sha256 "$artifacts/acceptance-aggregate.json")"
  mv "$TEST_ROOT/portable" "$TEST_ROOT/relocated"
  mv "$artifacts" "$TEST_ROOT/unavailable-producer-inputs"

  run verify_portable "$TEST_ROOT/relocated" "$TEST_ROOT/independent-trust"

  [ "$status" -eq 0 ]
  [[ "$output" == *'qualification bundle verified'* ]]
  printf '%s\n' --bundle missing-bundle --trusted-root missing-root --policy missing-policy \
    >>"$TEST_ROOT/relocated/qualification-arguments.txt"

  run verify_portable "$TEST_ROOT/relocated" "$TEST_ROOT/independent-trust"

  [ "$status" -eq 0 ]
}

@test "preserves native document parsing for YAML text and extensionless sources" {
  create_statement_and_bundle
  local artifacts="$TEST_ROOT/artifacts"
  local suffix expected
  for suffix in yaml yml txt ''; do
    export PACKAGE_SCENARIO="$artifacts/scenario${suffix:+.$suffix}"
    cp "$artifacts/acceptance-scenario.yaml" "$PACKAGE_SCENARIO"
    run package_inventory
    [ "$status" -eq 0 ]
    expected="$TEST_ROOT/portable/subjects/scenario.json.${suffix:-data}"
    cmp "$PACKAGE_SCENARIO" "$expected"
    run verify_portable "$TEST_ROOT/portable"
    [ "$status" -eq 0 ]
    rm -r "$TEST_ROOT/portable"
  done
}

@test "retains nested file dependencies and their qualified digests after relocation" {
  local artifacts="$TEST_ROOT/artifacts"
  local product="$artifacts/product"
  local package="$product/ros/fixture_description"
  mkdir -p "$product/sim" "$package/description" "$package/meshes"
  printf '%s\n' '<package format="3"><name>fixture_description</name></package>' \
    >"$package/package.xml"
  printf '%s\n' '<robot name="fixture"><link name="base"><visual><geometry>' \
    '<mesh filename="package://fixture_description/meshes/base.stl"/>' \
    '</geometry></visual><collision><geometry>' \
    '<mesh filename="package://fixture_description/meshes/tip.stl"/>' \
    '</geometry></collision></link></robot>' >"$package/description/model.urdf"
  printf '%s\n' 'solid base' 'endsolid base' >"$package/meshes/base.stl"
  printf '%s\n' 'solid tip' 'endsolid tip' >"$package/meshes/tip.stl"
  jq -n --arg description_sha "$(sha256 "$package/description/model.urdf")" \
    --arg base_sha "$(sha256 "$package/meshes/base.stl")" \
    --arg tip_sha "$(sha256 "$package/meshes/tip.stl")" '{
      schema_version: "robot-description.v1", robot_id: "fixture",
      source: {path: "ros/fixture_description/description/model.urdf", sha256: $description_sha},
      package: {name: "fixture_description", path: "ros/fixture_description"},
      description: {
        format: "urdf", path: "ros/fixture_description/description/model.urdf",
        sha256: $description_sha
      },
      meshes: [
        {path: "ros/fixture_description/meshes/base.stl", sha256: $base_sha},
        {path: "ros/fixture_description/meshes/tip.stl", sha256: $tip_sha}
      ],
      mass_kg: 1, center_of_mass_m: [0, 0, 0],
      inertia_check: {status: "not_checked"}, spawn: {frame: "world", pose: [0, 0, 0, 0, 0, 0]}
    }' >"$product/sim/robot-description.json"
  local product_arguments=()
  local relative
  for relative in sim/robot-description.json ros/fixture_description/package.xml \
    ros/fixture_description/description/model.urdf \
    ros/fixture_description/meshes/base.stl ros/fixture_description/meshes/tip.stl; do
    product_arguments+=(--artifact "other_evidence:products/fixture/$relative=$product/$relative")
  done
  "$ROBOTICS_CONTRACTS_CLI" validate "$product/sim/robot-description.json"
  create_statement_and_bundle "${product_arguments[@]}"
  local package_sha
  package_sha="$(sha256 "$package/package.xml")"
  run package_inventory "${product_arguments[@]}"
  [ "$status" -eq 0 ]
  run grep -F "$TEST_ROOT" "$TEST_ROOT/portable/qualification-arguments.txt"
  [ "$status" -eq 1 ]
  mkdir "$TEST_ROOT/independent-trust"
  cp "$artifacts/"{bundle.json,trusted-root.json,policy.json,statement.json} \
    "$TEST_ROOT/independent-trust/"
  jq -e --arg sha "$package_sha" '.subject | any(
    .name == "products/fixture/ros/fixture_description/package.xml" and .digest.sha256 == $sha
  )' "$TEST_ROOT/independent-trust/statement.json"
  export COSIGN_TEST_AGGREGATE_SHA256
  COSIGN_TEST_AGGREGATE_SHA256="$(sha256 "$artifacts/acceptance-aggregate.json")"
  mv "$TEST_ROOT/portable" "$TEST_ROOT/relocated"
  rm -r "$artifacts"

  run verify_portable "$TEST_ROOT/relocated" "$TEST_ROOT/independent-trust"
  [ "$status" -eq 0 ]
  (
    cd "$TEST_ROOT/relocated"
    mapfile -t portable_arguments <qualification-arguments.txt
    "$REPOSITORY_ROOT/scripts/qualification/create-statement" "${portable_arguments[@]}" \
      --output "$TEST_ROOT/independent-trust/relocated-statement.json"
  )
  cmp "$TEST_ROOT/independent-trust/statement.json" \
    "$TEST_ROOT/independent-trust/relocated-statement.json"
  "$ROBOTICS_CONTRACTS_CLI" validate \
    "$TEST_ROOT/relocated/subjects/products/fixture/sim/robot-description.json"
  python3 - "$TEST_ROOT/relocated/subjects/products/fixture" \
    "$TEST_ROOT/independent-trust/statement.json" <<'PY'
import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "sim/robot-description.json").read_bytes())
subjects = {
    item["name"]: item["digest"]["sha256"]
    for item in json.loads(Path(sys.argv[2]).read_bytes())["subject"]
}
for artifact in (manifest["source"], manifest["description"], *manifest["meshes"]):
    path = root / artifact["path"]
    raw_digest = hashlib.sha256(path.read_bytes()).hexdigest()
    assert raw_digest == artifact["sha256"]
    assert raw_digest == subjects[f"products/fixture/{artifact['path']}"]
package = manifest["package"]
package_xml = root / package["path"] / "package.xml"
assert ET.parse(package_xml).getroot().findtext("name") == package["name"]
assert hashlib.sha256(package_xml.read_bytes()).hexdigest() == subjects[
    f"products/fixture/{package['path']}/package.xml"
]
prefix = f"package://{package['name']}/"
mesh_paths = set()
for mesh in ET.parse(root / manifest["description"]["path"]).iter("mesh"):
    uri = mesh.attrib["filename"]
    assert uri.startswith(prefix)
    mesh_paths.add(f"{package['path']}/{uri[len(prefix):]}")
assert mesh_paths == {artifact["path"] for artifact in manifest["meshes"]}
assert len(list(root.rglob("*.*"))) == 5
PY
}

@test "rejects suffix mapped artifact collisions while preserving schema aliases" {
  local artifacts="$TEST_ROOT/artifacts"
  for subjects in 'logs:logs.json' 'logs.json:logs.json.data'; do
    local first="${subjects%%:*}"
    local second="${subjects#*:}"
    local source="$artifacts/diagnostics.json"
    if [[ "$first" == logs.json ]]; then
      source="$TEST_ROOT/extensionless"
      cp "$artifacts/diagnostics.json" "$source"
    fi
    run package_inventory --artifact "other_evidence:$first=$source" \
      --artifact "other_evidence:$second=$source"
    [ "$status" -eq 65 ]
    [[ "$output" == *'artifact storage paths collide'* ]]
    [ ! -e "$TEST_ROOT/portable" ]
  done
}

@test "rejects a changed or missing portable subject through existing verification" {
  create_statement_and_bundle
  package_inventory
  printf '%s\n' '{"diagnostics":"tampered"}' \
    >"$TEST_ROOT/portable/subjects/evidence/diagnostics.json"

  run verify_portable "$TEST_ROOT/portable"

  [ "$status" -eq 65 ]
  [[ "$output" == *'authenticated statement does not exactly match'* ]]
  rm "$TEST_ROOT/portable/subjects/evidence/diagnostics.json"

  run verify_portable "$TEST_ROOT/portable"

  [ "$status" -eq 65 ]
  [[ "$output" == *'required regular file is not readable'* ]]
}

@test "refuses existing outputs and paths outside the consumer root without writing" {
  printf '%s\n' 'retained' >"$TEST_ROOT/sentinel"
  mkdir "$TEST_ROOT/portable"
  cp "$TEST_ROOT/sentinel" "$TEST_ROOT/portable/sentinel"
  run package_inventory
  [ "$status" -eq 65 ]
  cmp "$TEST_ROOT/sentinel" "$TEST_ROOT/portable/sentinel"
  rm -r "$TEST_ROOT/portable"
  run package_inventory --output "$BATS_TEST_TMPDIR/outside-consumer"
  [ "$status" -eq 65 ]
  [[ "$output" == *'outside the consumer root'* ]]
  [ ! -e "$BATS_TEST_TMPDIR/outside-consumer" ]
  cp "$TEST_ROOT/artifacts/diagnostics.json" "$BATS_TEST_TMPDIR/outside-input.json"
  run package_inventory --artifact "other_evidence:logs/outside.json=$BATS_TEST_TMPDIR/outside-input.json"
  [ "$status" -eq 65 ]
  [[ "$output" == *'outside the consumer root'* ]]
  [ ! -e "$TEST_ROOT/portable" ]
}

@test "refuses missing inputs symlink paths and unsafe inventory subjects" {
  rm "$TEST_ROOT/artifacts/diagnostics.json"
  run package_inventory
  [ "$status" -eq 65 ]
  [ ! -e "$TEST_ROOT/portable" ]
  cp "$FIXTURES/diagnostics.json" "$TEST_ROOT/artifacts/diagnostics.json"
  ln -s "$TEST_ROOT/artifacts" "$TEST_ROOT/linked-inputs"
  run package_inventory \
    --artifact "other_evidence:logs/linked.json=$TEST_ROOT/linked-inputs/diagnostics.json"
  [ "$status" -eq 65 ]
  [[ "$output" == *'symlink path is not supported'* ]]
  [ ! -e "$TEST_ROOT/portable" ]
  run package_inventory --artifact "other_evidence:../escape=$TEST_ROOT/artifacts/diagnostics.json"
  [ "$status" -eq 65 ]
  [[ "$output" == *'non-canonical qualification subject name'* ]]
  [ ! -e "$TEST_ROOT/portable" ]
  run package_inventory --extension-schema "--key=$TEST_ROOT/artifacts/diagnostics.json"
  [ "$status" -eq 65 ]
  [[ "$output" == *'unsafe artifact or schema label'* ]]
  [ ! -e "$TEST_ROOT/portable" ]
}

@test "refuses colliding storage paths and output symlink or input aliases" {
  cp "$TEST_ROOT/artifacts/diagnostics.json" "$TEST_ROOT/x"
  mkdir "$TEST_ROOT/inputs"
  cp "$TEST_ROOT/x" "$TEST_ROOT/inputs/y"
  run package_inventory --artifact "other_evidence:logs=$TEST_ROOT/x" \
    --artifact "other_evidence:logs/x=$TEST_ROOT/inputs/y"
  [ "$status" -eq 65 ]
  [[ "$output" == *'file and directory paths collide'* ]]
  [ ! -e "$TEST_ROOT/portable" ]
  ln -s "$TEST_ROOT" "$TEST_ROOT/linked-output"
  run package_inventory --output "$TEST_ROOT/linked-output/new"
  [ "$status" -eq 65 ]
  [[ "$output" == *'symlink path is not supported'* ]]
  run package_inventory --output "$TEST_ROOT/artifacts/diagnostics.json"
  [ "$status" -eq 65 ]
  cmp "$FIXTURES/diagnostics.json" "$TEST_ROOT/artifacts/diagnostics.json"
}

@test "removes only its new output if source bytes change after validation" {
  export REAL_CONTRACTS_CLI="$ROBOTICS_CONTRACTS_CLI"
  cat >"$TEST_BIN/changing-contracts" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_CONTRACTS_CLI" "$@"
printf '\n' >>"$TEST_ROOT/artifacts/diagnostics.json"
EOF
  chmod +x "$TEST_BIN/changing-contracts"
  export ROBOTICS_CONTRACTS_CLI="$TEST_BIN/changing-contracts"
  printf '%s\n' 'retained' >"$TEST_ROOT/sentinel"
  run package_inventory
  [ "$status" -eq 65 ]
  [[ "$output" == *'input changed during packaging'* ]]
  [ ! -e "$TEST_ROOT/portable" ]
  [ "$(cat "$TEST_ROOT/sentinel")" = retained ]
}

@test "does not publish when the public CLI returns false empty or nonzero output" {
  for response in false '{}' ''; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$response" >"$TEST_BIN/invalid-contracts"
    chmod +x "$TEST_BIN/invalid-contracts"
    export ROBOTICS_CONTRACTS_CLI="$TEST_BIN/invalid-contracts"
    run package_inventory
    [ "$status" -eq 65 ]
    [ ! -e "$TEST_ROOT/portable" ]
  done
  printf '#!/usr/bin/env bash\nexit 13\n' >"$TEST_BIN/invalid-contracts"
  run package_inventory
  [ "$status" -eq 65 ]
  [ ! -e "$TEST_ROOT/portable" ]
}

@test "refuses LF and CR paths before writing a portable arguments file" {
  for control in $'\n' $'\r'; do
    run package_inventory --output "$TEST_ROOT/bad${control}output"
    [ "$status" -eq 65 ]
    [[ "$output" == *'unsafe path'* ]]
    [ ! -e "$TEST_ROOT/bad${control}output" ]
    run package_inventory --extension-schema "urn:test:bad${control}uri=$TEST_ROOT/artifacts/diagnostics.json"
    [ "$status" -eq 65 ]
    [[ "$output" == *'unsafe artifact or schema label'* ]]
    [ ! -e "$TEST_ROOT/portable" ]
  done
}

@test "trusted native verification and explain refuse renamed stock as expected playback" {
  printf '{"scope":"opaque playback attachment"}\n' >"$TEST_ROOT/artifacts/playback-attachment.json"
  create_statement_and_bundle \
    --artifact "other_evidence:playback/attachment.json=$TEST_ROOT/artifacts/playback-attachment.json"
  mapfile -t args < <(artifact_arguments)
  local package="$TEST_ROOT/renamed-playback"
  (
    cd "$TEST_ROOT"
    "$REPOSITORY_ROOT/scripts/qualification/package-artifacts" \
      --output "$package" "${args[@]}" \
      --artifact "other_evidence:playback/attachment.json=$TEST_ROOT/artifacts/playback-attachment.json"
  )
  cp "$TEST_ROOT/artifacts/"{bundle.json,policy.json,trusted-root.json} "$package/"
  (
    cd "$package"
    mapfile -t portable <qualification-arguments.txt
    "$REPOSITORY_ROOT/scripts/qualification/verify-bundle" "${portable[@]}" \
      --bundle bundle.json --trusted-root trusted-root.json --policy policy.json
  )
  # Public qualification accepts this genuine simulator fixture plus opaque
  # bytes. The caller must still demand playback after native trusted verify.
  source "$REPOSITORY_ROOT/scripts/ci/foundation/lib.sh"
  local acceptance_cli="${ROBOTICS_ACCEPTANCE_CLI:-$REPOSITORY_ROOT/dependencies/robotics-runtime/.venv/bin/robotics-acceptance}"
  run foundation_explain_qualification "$package" "$TEST_ROOT/source-explain.json" simulator \
    "${acceptance_cli}"
  [ "$status" -eq 0 ]
  run foundation_explain_qualification "$package" "$TEST_ROOT/playback-explain.json" recording_playback \
    "${acceptance_cli}"
  [ "$status" -ne 0 ]
  jq -e '.execution.data_source == "simulator"' "$TEST_ROOT/playback-explain.json"
}
