#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  cd "${ROOT}" || return
  # shellcheck source=scripts/ci/lib.sh
  source scripts/ci/lib.sh
  # shellcheck source=scripts/ci/foundation/run-policy.sh
  source scripts/ci/foundation/run-policy.sh
  PYTHON="${ROBOTICS_CONTRACTS_PYTHON:-${ROOT}/dependencies/robotics-runtime/.venv/bin/python}"
  INPUT="${BATS_TEST_TMPDIR}/input.json"
  OUTPUT="${BATS_TEST_TMPDIR}/policy.json"
  unset ROBOTICS_RUNTIME_MODE
  # Called indirectly by the sourced production policy adapter.
  # shellcheck disable=SC2329
  ci_opa() { run_policy_engine "$@"; }
}

# Use the real pinned engine on both local Windows and hosted Linux. The extra
# read-only mount exposes only this test's temporary inputs to the container.
run_policy_engine() {
  if [[ -n "${ROBOTICS_TEST_OPA_BIN:-}" ]]; then
    "${ROBOTICS_TEST_OPA_BIN}" "$@"
  else
    docker run --rm --volume "${ROOT}:${ROOT}:ro" \
      --volume "${BATS_TEST_TMPDIR}:${BATS_TEST_TMPDIR}:ro" --workdir "${ROOT}" \
      "${POLICY_TOOLING_IMAGE:-local/robotics-runtime-infra/policy-tooling:ci}" "$@"
  fi
}

@test "the consumer scenario snapshot passes through the production policy adapter" {
  run foundation_require_scenario_policy "$PYTHON" test/acceptance/stepped-smoke.yaml "$OUTPUT"
  [ "$status" -eq 0 ]
  jq -e '.execution.plant_backend == "simulated_physics"' "$OUTPUT"
}

@test "consumer interface mock with a performance verdict is rejected" {
  run foundation_require_scenario_policy "$PYTHON" test/policy/mock-physical-verdict.yaml "$OUTPUT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"interface mocks are limited to interface_smoke"* ]]
}

@test "policy parsing rejects duplicate keys like the verifier" {
  printf 'execution: {}\nexecution: {}\n' >"${BATS_TEST_TMPDIR}/scenario.yaml"
  run foundation_require_scenario_policy "$PYTHON" "${BATS_TEST_TMPDIR}/scenario.yaml" "$OUTPUT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate object key"* ]]
}

@test "released consumer cannot replace the caller mode with source" {
  printf '%s\n' '{"x-robotics-runtime":{"mode":"source"},"services":{"simulation":{"image":"local/robotics-runtime-infra/simulation:dev"}}}' >"$INPUT"
  ROBOTICS_RUNTIME_MODE=released run foundation_require_release_images_policy "$INPUT" "$OUTPUT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"falls back to a local development image"* ]]
  jq -e '."x-robotics-runtime".mode == "released"' "$OUTPUT"
}

@test "released consumer rejects its own local image when Compose loses the extension" {
  printf '%s\n' '{"services":{"product":{"image":"local/consumer/product:dev"}}}' >"$INPUT"
  ROBOTICS_RUNTIME_MODE=released run foundation_require_release_images_policy "$INPUT" "$OUTPUT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"service \"product\" falls back"* ]]
}

@test "released pinned image and source local image remain usable" {
  jq -n --arg digest "$(printf '%064d' 1)" '{services:{simulation:{image:("ghcr.io/mmkolpakov/robotics-runtime-infra/simulation:0.9.0@sha256:" + $digest)}}}' >"$INPUT"
  ROBOTICS_RUNTIME_MODE=released run foundation_require_release_images_policy "$INPUT" "$OUTPUT"
  [ "$status" -eq 0 ]
  printf '%s\n' '{"services":{"product":{"image":"local/consumer/product:dev"}}}' >"$INPUT"
  ROBOTICS_RUNTIME_MODE=source run foundation_require_release_images_policy "$INPUT" "$OUTPUT"
  [ "$status" -eq 0 ]
}

@test "unknown mode and policy engine failure cannot allow execution" {
  printf '%s\n' '{"services":{}}' >"$INPUT"
  ROBOTICS_RUNTIME_MODE=relased run foundation_require_release_images_policy "$INPUT" "$OUTPUT"
  [ "$status" -eq 64 ]
  [[ "$output" == *"unsupported runtime mode"* ]]
  ci_opa() { return 42; }
  ROBOTICS_RUNTIME_MODE=released run foundation_require_release_images_policy "$INPUT" "$OUTPUT"
  [ "$status" -eq 42 ]
}
