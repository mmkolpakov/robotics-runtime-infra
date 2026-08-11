#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
}

@test "release plan is unique, complete, and consumable as a matrix" {
  output_file="${BATS_TEST_TMPDIR}/github-output"
  release_plan="${BATS_TEST_TMPDIR}/release-plan.json"
  run env \
    GITHUB_OUTPUT="${output_file}" \
    GITHUB_REF_NAME=v0.8.0 \
    scripts/ci/release/prepare-plan.sh \
      config/ci/release-environment.json \
      "${release_plan}"

  [ "${status}" -eq 0 ]
  matrix="$(sed -n 's/^matrix=//p' "${output_file}")"
  version="$(sed -n 's/^version=//p' "${output_file}")"
  expected_count="$(jq '.images | length' "${release_plan}")"
  [ "${version}" = 0.8.0 ]
  run jq -e --argjson expected_count "${expected_count}" '
    (.include | length) == $expected_count and
    ([.include[].id] | length == (unique | length)) and
    ([.include[].environment_variable] | length == (unique | length)) and
    any(.include[]; .id == "simulation" and .platforms == ["linux/amd64"]) and
    any(.include[];
      .id == "provider-conformance-cpu" and
      .environment_variable == "INFERENCE_CPU_CONFORMANCE_IMAGE"
    ) and
    any(.include[];
      .id == "sensor-inference-cpu" and
      .environment_variable == "SENSOR_INFERENCE_IMAGE"
    ) and
    any(.include[];
      .id == "inference-intel-cpu" and
      .environment_variable == "INFERENCE_INTEL_CPU_IMAGE"
    ) and
    any(.include[];
      .id == "sensor-inference-intel-cpu" and
      .environment_variable == "SENSOR_INFERENCE_INTEL_CPU_IMAGE"
    ) and
    any(.include[];
      .id == "permit-preflight" and
      .environment_variable == "PERMIT_PREFLIGHT_IMAGE"
    )
  ' <<<"${matrix}"
  [ "${status}" -eq 0 ]
}

@test "release workflow gates untagged candidates before promotion" {
  run grep -F 'uses: ./.github/workflows/ci.yml' \
    .github/workflows/release-image.yml
  [ "${status}" -eq 0 ]
  run grep -F 'uses: ./.github/workflows/foundation-integration.yml' \
    .github/workflows/release-image.yml
  [ "${status}" -eq 0 ]
  run grep -F 'push-by-digest=true' .github/workflows/release-image.yml
  [ "${status}" -eq 0 ]
  run grep -F \
    'uses: docker/bake-action@d3418bd7d0e9324001bca92fa8ba175ea7e6dc9b' \
    .github/workflows/release-image.yml
  [ "${status}" -eq 0 ]
  run grep -F 'uses: docker/build-push-action@' \
    .github/workflows/release-image.yml
  [ "${status}" -eq 1 ]
  run grep -F 'scripts/ci/security/scan-image.sh' \
    .github/workflows/release-image.yml
  [ "${status}" -eq 0 ]
  run grep -F 'scripts/ci/release/promote-candidates.sh' \
    .github/workflows/release-image.yml
  [ "${status}" -eq 0 ]
  run grep -R -F -- '--ignore-unfixed' \
    scripts/ci/security .github/workflows
  [ "${status}" -eq 1 ]

}

@test "release workflow delegates the permissions required by reusable gates" {
  foundation_gate="$(
    sed -n '/^  foundation-gate:/,/^  prepare:/p' \
      .github/workflows/release-image.yml
  )"

  grep -F 'contents: read' <<<"${foundation_gate}"
  grep -F 'id-token: write' <<<"${foundation_gate}"
}

@test "release scan uploads use one category per candidate platform" {
  workflow=.github/workflows/release-image.yml

  grep -F \
    'sarif_file: artifacts/security/${{ matrix.id }}-linux-amd64.sarif' \
    "${workflow}"
  grep -F \
    'category: release-candidate-${{ matrix.id }}-linux-amd64' \
    "${workflow}"
  grep -F \
    'sarif_file: artifacts/security/${{ matrix.id }}-linux-arm64.sarif' \
    "${workflow}"
  grep -F \
    'category: release-candidate-${{ matrix.id }}-linux-arm64' \
    "${workflow}"
  run grep -E '^[[:space:]]+sarif_file: artifacts/security$' "${workflow}"
  [ "${status}" -eq 1 ]
}

@test "cross-platform build tooling is immutable in every publishing path" {
  action=.github/actions/setup-buildx/action.yml
  run grep -R -F 'tonistiigi/binfmt:latest' .github
  [ "${status}" -eq 1 ]
  run grep -F \
    'image: docker.io/tonistiigi/binfmt:qemu-v10.2.3-68@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0' \
    "${action}"
  [ "${status}" -eq 0 ]
  run grep -F \
    'image=moby/buildkit:v0.31.1@sha256:6b59b7df63a8cb9902736f9ddf7fcff8261613d3e7449b8ea8b7537fc399c03a' \
    "${action}"
  [ "${status}" -eq 0 ]
  run grep -R -E 'uses: docker/setup-(qemu|buildx)-action@' \
    .github/workflows
  [ "${status}" -eq 1 ]
}

@test "candidate promotion emits a complete immutable runtime lock" {
  candidate_dir="${BATS_TEST_TMPDIR}/candidates"
  output_dir="${BATS_TEST_TMPDIR}/release"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  release_plan="${BATS_TEST_TMPDIR}/release-plan.json"
  state_dir="${BATS_TEST_TMPDIR}/docker-state"
  mkdir -p "${candidate_dir}" "${fake_bin}" "${state_dir}"
  GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github-output" \
    GITHUB_REF_NAME=v0.8.0 \
    scripts/ci/release/prepare-plan.sh \
      config/ci/release-environment.json \
      "${release_plan}"

  while IFS= read -r row; do
    id="$(jq -r '.id' <<<"${row}")"
    environment_variable="$(jq -r '.environment_variable' <<<"${row}")"
    platforms="$(jq -r '.platforms | join(",")' <<<"${row}")"
    digest="sha256:$(printf '%s' "${id}" | sha256sum | cut -d' ' -f1)"
    scripts/ci/release/record-candidate.sh \
      "${id}" \
      "${environment_variable}" \
      "ghcr.io/test-owner/robotics-runtime-infra/${id}" \
      "${digest}" \
      "${platforms}" \
      "${candidate_dir}/${id}.json"
  done < <(jq -c '.images[]' "${release_plan}")

  cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
test "$1" = buildx
test "$2" = imagetools
case "$3" in
  create)
    shift 3
    tags=()
    metadata=
    source=
    while test "$#" -gt 0; do
      case "$1" in
        --tag)
          tags+=("$2")
          shift 2
          ;;
        --metadata-file)
          metadata="$2"
          shift 2
          ;;
        *)
          source="$1"
          shift
          ;;
      esac
    done
    digest="${source##*@}"
    printf '{}\n' >"${metadata}"
    for tag in "${tags[@]}"; do
      key="$(printf '%s' "${tag}" | sha256sum | cut -d' ' -f1)"
      printf '%s\n' "${digest}" >"${FAKE_DOCKER_STATE}/${key}"
    done
    ;;
  inspect)
    reference="${@: -1}"
    key="$(printf '%s' "${reference}" | sha256sum | cut -d' ' -f1)"
    if test -f "${FAKE_DOCKER_STATE}/${key}"; then
      jq -n --arg digest "$(<"${FAKE_DOCKER_STATE}/${key}")" \
        '{digest: $digest}'
    else
      printf 'manifest unknown\n' >&2
      exit 1
    fi
    ;;
  *)
    exit 64
    ;;
esac
EOF
  chmod +x "${fake_bin}/docker"

  run env \
    "PATH=${fake_bin}:${PATH}" \
    FAKE_DOCKER_STATE="${state_dir}" \
    GITHUB_REPOSITORY_OWNER=test-owner \
    GITHUB_REF=refs/tags/v0.8.0 \
    GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
    scripts/ci/release/promote-candidates.sh \
      "${release_plan}" \
      "${candidate_dir}" \
      0.8.0 \
      "${output_dir}"

  [ "${status}" -eq 0 ]
  expected_count="$(jq '.images | length' "${release_plan}")"
  [ "$(grep -c '_IMAGE=' "${output_dir}/release.env")" -eq "${expected_count}" ]
  [ "$(grep -c '^ROBOTICS_RUNTIME_MODE=released$' "${output_dir}/release.env")" -eq 1 ]
  [ "$(grep -c '^ROBOTICS_RELEASE_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567$' "${output_dir}/release.env")" -eq 1 ]
  [ "$(grep -c '^ROBOTICS_RELEASE_SOURCE_REF=refs/tags/v0.8.0$' "${output_dir}/release.env")" -eq 1 ]
  [ "$(find "${output_dir}/digests" -type f -name '*.txt' | wc -l)" -eq "${expected_count}" ]
  run grep -Ev '^[A-Z][A-Z0-9_]+=ghcr\.io/.+:[^@]+@sha256:[a-f0-9]{64}$|^ROBOTICS_RUNTIME_MODE=released$|^ROBOTICS_RELEASE_SOURCE_SHA=[a-f0-9]{40}$|^ROBOTICS_RELEASE_SOURCE_REF=refs/tags/v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' \
    "${output_dir}/release.env"
  [ "${status}" -eq 1 ]

  run env \
    ROBOTICS_DOMAIN_ID=0 \
    ROBOTICS_RUN_ID=run-release-lock-test \
    docker compose \
    --env-file "${output_dir}/release.env" \
    -f compose.yaml \
    -f compose.high-throughput.yaml \
    -f compose.observability.yaml \
    -f compose.sensor-inference.yaml \
    --profile observability \
    --profile sensor-inference \
    config --format json
  [ "${status}" -eq 0 ]
  compose_json="${output}"
  run jq -e '
    ."x-robotics-runtime".mode == "released" and
    ([.services[].image | select(startswith("local/"))] | length == 0)
  ' <<<"${compose_json}"
  [ "${status}" -eq 0 ]
  run jq -e '
    .services["sensor-inference-probe"].image |
    startswith(
      "ghcr.io/test-owner/robotics-runtime-infra/" +
      "sensor-inference-cpu:0.8.0@sha256:"
    )
  ' <<<"${compose_json}"
  [ "${status}" -eq 0 ]
  run jq -e '.services["otel-collector"].user == "1000:1000"' \
    <<<"${compose_json}"
  [ "${status}" -eq 0 ]
}

@test "immutable promotion refuses collisions and registry ambiguity" {
  fake_bin="${BATS_TEST_TMPDIR}/promotion-bin"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
test "$1 $2 $3" = "buildx imagetools inspect"
case "${FAKE_REGISTRY_STATE}" in
  collision)
    jq -n --arg digest "sha256:$(printf '%064d' 9)" \
      '{digest: $digest}'
    ;;
  unavailable)
    printf 'registry transport failed\n' >&2
    exit 1
    ;;
  *)
    exit 64
    ;;
esac
EOF
  chmod +x "${fake_bin}/docker"
  image=ghcr.io/test-owner/robotics-runtime-infra/simulation
  digest="sha256:$(printf '%064d' 1)"

  run env \
    "PATH=${fake_bin}:${PATH}" \
    FAKE_REGISTRY_STATE=collision \
    scripts/ci/release/promote-immutable-tags.sh \
      check "${image}" "${digest}" - "${image}:0.8.0"
  [ "${status}" -eq 73 ]
  [[ "${output}" == *"refusing to overwrite immutable tag"* ]]

  run env \
    "PATH=${fake_bin}:${PATH}" \
    FAKE_REGISTRY_STATE=unavailable \
    scripts/ci/release/promote-immutable-tags.sh \
      check "${image}" "${digest}" - "${image}:0.8.0"
  [ "${status}" -eq 70 ]
  [[ "${output}" == *"registry state could not be determined"* ]]
}

@test "conformance publication attests before assigning its immutable tag" {
  scan_line="$(
    grep -n 'name: Scan the untagged qualification candidate' \
      .github/workflows/publish-conformance-image.yml |
      cut -d: -f1
  )"
  promote_line="$(
    grep -n 'name: Promote the attested qualification image' \
      .github/workflows/publish-conformance-image.yml |
      cut -d: -f1
  )"
  attest_line="$(
    grep -n 'name: Attest and verify publication' \
      .github/workflows/publish-conformance-image.yml |
      cut -d: -f1
  )"
  verify_line="$(
    grep -n 'name: Verify immutable reference' \
      .github/workflows/publish-conformance-image.yml |
      cut -d: -f1
  )"
  [ "${scan_line}" -lt "${promote_line}" ]
  [ "${scan_line}" -lt "${attest_line}" ]
  [ "${attest_line}" -lt "${verify_line}" ]
  [ "${verify_line}" -lt "${promote_line}" ]
  run grep -F 'push-by-digest=true' \
    .github/workflows/publish-conformance-image.yml
  [ "${status}" -eq 0 ]
  run grep -F 'test "${DISPATCH_SHA}" = "${SOURCE_SHA}"' \
    .github/workflows/publish-conformance-image.yml
  [ "${status}" -eq 0 ]
}
