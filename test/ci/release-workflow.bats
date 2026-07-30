#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
}

@test "release plan is unique, complete, and consumable as a matrix" {
  output_file="${BATS_TEST_TMPDIR}/github-output"
  run env \
    GITHUB_OUTPUT="${output_file}" \
    GITHUB_REF_NAME=v0.8.0 \
    scripts/ci/release/prepare-plan.sh

  [ "${status}" -eq 0 ]
  matrix="$(sed -n 's/^matrix=//p' "${output_file}")"
  version="$(sed -n 's/^version=//p' "${output_file}")"
  [ "${version}" = 0.8.0 ]
  run jq -e '
    (.include | length) == 11 and
    ([.include[].id] | length == (unique | length)) and
    ([.include[].environment_variable] | length == (unique | length)) and
    any(.include[]; .id == "simulation" and .platforms_csv == "linux/amd64") and
    any(.include[];
      .id == "provider-conformance-cpu" and
      .environment_variable == "INFERENCE_CPU_CONFORMANCE_IMAGE"
    ) and
    any(.include[];
      .id == "sensor-inference-cpu" and
      .environment_variable == "SENSOR_INFERENCE_IMAGE"
    ) and
    any(.include[];
      .id == "permit-preflight" and
      .environment_variable == "PERMIT_PREFLIGHT_IMAGE"
    )
  ' <<<"${matrix}"
  [ "${status}" -eq 0 ]
}

@test "release workflow gates untagged candidates before promotion" {
  run bash -c '
    docker buildx bake \
      --file docker-bake.hcl \
      --print permit-preflight 2>/dev/null
  '
  [ "${status}" -eq 0 ]
  bake_plan="${output}"
  run jq -e '
    .target["permit-preflight"].contexts["opa-source"] |
    startswith("https://github.com/open-policy-agent/opa.git?")
  ' <<<"${bake_plan}"
  [ "${status}" -eq 0 ]

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

  candidate_line="$(grep -n '^  candidate:' .github/workflows/release-image.yml | cut -d: -f1)"
  promote_line="$(grep -n '^  promote:' .github/workflows/release-image.yml | cut -d: -f1)"
  release_line="$(grep -n '^  release:' .github/workflows/release-image.yml | cut -d: -f1)"
  [ "${candidate_line}" -lt "${promote_line}" ]
  [ "${promote_line}" -lt "${release_line}" ]
}

@test "cross-platform build tooling is immutable in every publishing path" {
  binfmt_reference=\
'docker.io/tonistiigi/binfmt:qemu-v10.2.3-68@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0'
  workflows=(
    .github/workflows/ci.yml
    .github/workflows/release-image.yml
    .github/workflows/publish-conformance-image.yml
  )

  run grep -R -F 'tonistiigi/binfmt:latest' .github/workflows
  [ "${status}" -eq 1 ]

  for workflow in "${workflows[@]}"; do
    run grep -F "BINFMT_IMAGE: ${binfmt_reference}" "${workflow}"
    [ "${status}" -eq 0 ]
    qemu_steps="$(grep -Fc 'uses: docker/setup-qemu-action@' "${workflow}")"
    pinned_images="$(grep -Fc 'image: ${{ env.BINFMT_IMAGE }}' "${workflow}")"
    [ "${qemu_steps}" -eq "${pinned_images}" ]
  done

  run grep -F 'BUILDX_VERSION: v0.35.0' \
    .github/workflows/publish-conformance-image.yml
  [ "${status}" -eq 0 ]
  run grep -F \
    'BUILDKIT_IMAGE: moby/buildkit:v0.31.1@sha256:6b59b7df63a8cb9902736f9ddf7fcff8261613d3e7449b8ea8b7537fc399c03a' \
    .github/workflows/publish-conformance-image.yml
  [ "${status}" -eq 0 ]
}

@test "candidate promotion emits a complete immutable runtime lock" {
  candidate_dir="${BATS_TEST_TMPDIR}/candidates"
  output_dir="${BATS_TEST_TMPDIR}/release"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  state_dir="${BATS_TEST_TMPDIR}/docker-state"
  mkdir -p "${candidate_dir}" "${fake_bin}" "${state_dir}"

  while IFS= read -r row; do
    id="$(jq -r '.id' <<<"${row}")"
    environment_variable="$(jq -r '.environment_variable' <<<"${row}")"
    repository="$(jq -r '.repository' <<<"${row}")"
    platforms="$(jq -r '.platforms | join(",")' <<<"${row}")"
    digest="sha256:$(printf '%s' "${id}" | sha256sum | cut -d' ' -f1)"
    scripts/ci/release/record-candidate.sh \
      "${id}" \
      "${environment_variable}" \
      "ghcr.io/test-owner/robotics-runtime-infra/${repository}" \
      "${digest}" \
      "${platforms}" \
      "${candidate_dir}/${id}.json"
  done < <(jq -c '.images[]' config/ci/release-images.json)

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
    GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
    scripts/ci/release/promote-candidates.sh \
      config/ci/release-images.json \
      "${candidate_dir}" \
      0.8.0 \
      "${output_dir}"

  [ "${status}" -eq 0 ]
  [ "$(grep -c '_IMAGE=' "${output_dir}/release.env")" -eq 11 ]
  [ "$(grep -c '^ROBOTICS_RUNTIME_MODE=released$' "${output_dir}/release.env")" -eq 1 ]
  [ "$(grep -c '^ROBOTICS_COSIGN_IMAGE_DIGEST=sha256:' "${output_dir}/release.env")" -eq 1 ]
  [ "$(find "${output_dir}/digests" -type f -name '*.txt' | wc -l)" -eq 11 ]
  run grep -Ev '^[A-Z][A-Z0-9_]+=ghcr\.io/.+:[^@]+@sha256:[a-f0-9]{64}$|^ROBOTICS_COSIGN_IMAGE_DIGEST=sha256:[a-f0-9]{64}$|^ROBOTICS_RUNTIME_MODE=released$' \
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
