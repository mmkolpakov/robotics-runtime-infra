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
    ) and
    any(.include[];
      .id == "policy-tooling" and
      .environment_variable == "POLICY_TOOLING_IMAGE" and
      .platforms == ["linux/amd64", "linux/arm64"]
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

@test "ARM64 release layers are built natively for the candidates" {
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
test "$*" = "buildx bake --file docker-bake.hcl --print release"
cat <<'JSON'
{"target": {
  "simulation": {"platforms": ["linux/amd64"]},
  "edge-runtime": {"platforms": ["linux/amd64", "linux/arm64"]},
  "evidence-sink": {"platforms": ["linux/amd64", "linux/arm64"]}
}}
JSON
EOF
  chmod +x "${fake_bin}/docker"
  output_file="${BATS_TEST_TMPDIR}/github-output"

  run env PATH="${fake_bin}:${PATH}" GITHUB_OUTPUT="${output_file}" \
    GITHUB_REF_NAME=v0.9.0 scripts/ci/release/plan-arm64-layers.sh
  [ "${status}" -eq 0 ]
  grep -Fx "version=0.9.0" "${output_file}"
  grep -Fx "edge-runtime.platform=linux/arm64" "${output_file}"
  grep -Fx "evidence-sink.output=type=cacheonly" "${output_file}"
  grep -Fx \
    "edge-runtime.cache-to=type=gha,mode=max,scope=release-edge-runtime-arm64" \
    "${output_file}"
  run grep -F simulation "${output_file}"
  [ "${status}" -eq 1 ]

  run env PATH="${fake_bin}:${PATH}" GITHUB_OUTPUT="${output_file}" \
    GITHUB_REF_NAME=main scripts/ci/release/plan-arm64-layers.sh
  [ "${status}" -ne 0 ]

  workflow=.github/workflows/release-image.yml
  layers="$(sed -n '/^  arm64-layers:/,/^  prepare:/p' "${workflow}")"
  grep -Fx '    runs-on: ubuntu-24.04-arm' <<<"${layers}"
  grep -F 'test "$(uname -m)" = aarch64' <<<"${layers}"
  candidate="$(sed -n '/^  candidate:/,/^  promote:/p' "${workflow}")"
  grep -Fx '      - arm64-layers' <<<"${candidate}"
  grep -F \
    '.cache-from=type=gha,scope=release-${{ matrix.target }}-arm64' \
    <<<"${candidate}"
}

@test "portable ARM64 CI images build on a native runner" {
  job="$(sed -n '/^  portable-arm64:/,/^  reproducibility:/p' .github/workflows/ci.yml)"
  grep -Fx '    runs-on: ubuntu-24.04-arm' <<<"${job}"
  grep -F 'test "$(uname -m)" = aarch64' <<<"${job}"
  run grep -F 'qemu:' <<<"${job}"
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
  # Versions are tracked by Renovate; the test requires digest pins.
  run grep -E \
    '^ +image: docker\.io/tonistiigi/binfmt:[^@[:space:]]+@sha256:[a-f0-9]{64}$' \
    "${action}"
  [ "${status}" -eq 0 ]
  run grep -E \
    '^ +image=moby/buildkit:v[0-9.]+@sha256:[a-f0-9]{64}$' \
    "${action}"
  [ "${status}" -eq 0 ]
  run grep -R -E 'uses: docker/setup-(qemu|buildx)-action@' \
    .github/workflows
  [ "${status}" -eq 1 ]
}

@test "native candidates produce an immutable lock accepted by the released consumer" {
  export RELEASE_REAL_DOCKER
  RELEASE_REAL_DOCKER="$(command -v docker)"
  # shellcheck source=scripts/ci/lib.sh
  source scripts/ci/lib.sh
  # shellcheck source=scripts/ci/release/upstream-images.sh
  source scripts/ci/release/upstream-images.sh
  expected_collector="$(ci_release_otel_collector_reference)"
  expected_edge_data_plane="$(ci_release_edge_attach_data_plane_reference)"
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
      "ghcr.io/mmkolpakov/robotics-runtime-infra/${id}" \
      "${digest}" \
      "${platforms}" \
      "${candidate_dir}/${id}.json"
  done < <(jq -c '.images[]' "${release_plan}")

  cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == compose ]]; then
  exec "${RELEASE_REAL_DOCKER}" "$@"
fi
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
    OTEL_COLLECTOR_IMAGE=foreign/mutable:latest \
    EDGE_ATTACH_DATA_PLANE_IMAGE=foreign/mutable:latest \
    GITHUB_REPOSITORY_OWNER=mmkolpakov \
    GITHUB_REF=refs/tags/v0.8.0 \
    GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
    scripts/ci/release/promote-candidates.sh \
      "${release_plan}" \
      "${candidate_dir}" \
      0.8.0 \
      "${output_dir}"

  [ "${status}" -eq 0 ]
  expected_count="$(jq '.images | length' "${release_plan}")"
  [ "$(grep -c '_IMAGE=' "${output_dir}/release.env")" -eq "$((expected_count + 2))" ]
  grep -Fx "OTEL_COLLECTOR_IMAGE=${expected_collector}" "${output_dir}/release.env"
  grep -Fx "EDGE_ATTACH_DATA_PLANE_IMAGE=${expected_edge_data_plane}" "${output_dir}/release.env"
  [ "$(grep -c '^ROBOTICS_RUNTIME_MODE=released$' "${output_dir}/release.env")" -eq 1 ]
  [ "$(grep -c '^ROBOTICS_RELEASE_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567$' "${output_dir}/release.env")" -eq 1 ]
  [ "$(grep -c '^ROBOTICS_RELEASE_SOURCE_REF=refs/tags/v0.8.0$' "${output_dir}/release.env")" -eq 1 ]
  [ "$(find "${output_dir}/digests" -type f -name '*.txt' | wc -l)" -eq "${expected_count}" ]
  run grep -Ev '^[A-Z][A-Z0-9_]+=ghcr\.io/.+:[^@]+@sha256:[a-f0-9]{64}$|^ROBOTICS_RUNTIME_MODE=released$|^ROBOTICS_RELEASE_SOURCE_SHA=[a-f0-9]{40}$|^ROBOTICS_RELEASE_SOURCE_REF=refs/tags/v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$|^OTEL_COLLECTOR_IMAGE=otel/opentelemetry-collector-contrib:[0-9]+\.[0-9]+\.[0-9]+@sha256:[a-f0-9]{64}$|^EDGE_ATTACH_DATA_PLANE_IMAGE=registry\.k8s\.io/pause:[0-9]+\.[0-9]+\.[0-9]+@sha256:[a-f0-9]{64}$' \
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
      "ghcr.io/mmkolpakov/robotics-runtime-infra/" +
      "sensor-inference-cpu:0.8.0@sha256:"
    )
  ' <<<"${compose_json}"
  [ "${status}" -eq 0 ]
  run jq -e '.services["otel-collector"].user == "1000:1000"' \
    <<<"${compose_json}"
  [ "${status}" -eq 0 ]
  run jq -e --arg collector "${expected_collector}" \
    '.services["otel-collector"].image == $collector' <<<"${compose_json}"
  [ "${status}" -eq 0 ]

  approved="$(sed -n 's/^[A-Z][A-Z0-9_]*_IMAGE=//p' "${output_dir}/release.env" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  for layout in foundation edge; do
    if [[ "${layout}" == foundation ]]; then
      files=(-f compose.foundation.yaml -f compose.stepped.yaml -f compose.record.yaml
        -f compose.evidence.yaml -f compose.observability.yaml)
    else
      files=(-f compose.edge-attach.yaml)
    fi
    run env ROBOTICS_DOMAIN_ID=0 ROBOTICS_RUN_ID=run-release-lock-test \
      ROBOTICS_ATTACH_NETWORK=release-lock-network docker compose \
      --env-file "${output_dir}/release.env" -f compose.yaml "${files[@]}" \
      -f compose.released.yaml --profile '*' config --format json
    [ "${status}" -eq 0 ]
    locked_model="${output}"
    frozen_model="${BATS_TEST_TMPDIR}/${layout}-resolved.json"
    printf '%s\n' "${locked_model}" >"${frozen_model}"
    run env ROBOTICS_DOMAIN_ID=0 ROBOTICS_RUN_ID=run-release-lock-test \
      ROBOTICS_ATTACH_NETWORK=release-lock-network docker compose \
      --env-file "${output_dir}/release.env" -f "${frozen_model}" \
      --profile '*' config --format json
    [ "${status}" -eq 0 ]
    [ "$(jq -Sc . <<<"${locked_model}")" = "$(jq -Sc . <<<"${output}")" ]
    run jq -e --argjson approved "${approved}" '
      ."x-robotics-runtime".mode == "released" and
      all(.services[];
        (has("build") | not) and (.image as $image | $approved | index($image) != null)
      )
    ' <<<"${output}"
    [ "${status}" -eq 0 ]
  done

  consumer_probe="${BATS_TEST_TMPDIR}/consume-lock.sh"
  cat >"${consumer_probe}" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root="$1" consumer="$2" evidence="$3" producer_plan="$4"
source "${root}/scripts/ci/lib.sh"
source "${root}/scripts/ci/foundation/released-mode.sh"
trace="${evidence}.calls"
: >"${trace}"
gh() {
  printf 'gh %s\n' "$*" >>"${trace}"
  [[ " $* " == *' --repo mmkolpakov/robotics-runtime-infra '* ]] || return 99
  case "$1 $2" in
    'release verify')
      [[ "$3" == "${ROBOTICS_FOUNDATION_RELEASE_TAG}" ]] || return 99
      printf '%s\n' '{"verified":true}'
      ;;
    'release verify-asset')
      [[ "$3" == "${ROBOTICS_FOUNDATION_RELEASE_TAG}" ]] || return 99
      cmp "${ROBOTICS_FOUNDATION_RELEASE_LOCK}" "$4" || return
      printf '%s\n' '{"verified":true}'
      ;;
    'attestation verify')
      [[ " $* " == *' --signer-workflow mmkolpakov/robotics-runtime-infra/.github/workflows/release-image.yml '* &&
         " $* " == *" --source-digest ${ROBOTICS_RELEASE_SOURCE_SHA} "* &&
         " $* " == *" --source-ref refs/tags/${ROBOTICS_FOUNDATION_RELEASE_TAG} "* ]] || return 99
      printf '%s\n' '[{}]'
      ;;
    *) return 99 ;;
  esac
}
docker() {
  if [[ "$1" == compose ]]; then command docker "$@"; return; fi
  printf 'docker %s\n' "$*" >>"${trace}"
  case "$1 ${2:-}" in
    'pull '*) ;;
    'image inspect')
      jq -nc --arg pin "$3" \
        '[{Id: ("sha256:" + ("b" * 64)), RepoDigests: [$pin]}]'
      ;;
    'buildx imagetools')
      jq -nc --arg digest "${*: -1}" \
        '{digest:($digest | split("@")[-1]),mediaType:"application/vnd.oci.image.manifest.v1+json"}'
      ;;
    *) return 99 ;;
  esac
}
export GH_TOKEN=fixture-token ROBOTICS_RUNTIME_MODE=released
export ROBOTICS_FOUNDATION_RELEASE_TAG=v0.8.0
export ROBOTICS_FOUNDATION_RELEASE_LOCK="${consumer}/release.env"
export GITHUB_REF_NAME=consumer-branch GITHUB_OUTPUT="${evidence}.workflow-output"
printf 'caller-sentinel\n' >"${GITHUB_OUTPUT}"
foundation_prepare_execution_mode "${consumer}" "${evidence}"
cmp "${consumer}/release.env" "${evidence}/release.env"
cmp "${producer_plan}" "${evidence}/release-plan.json"
[[ "${GITHUB_REF_NAME}" == consumer-branch && "$(<"${GITHUB_OUTPUT}")" == caller-sentinel ]]
[[ "${BENCHMARK_IMAGE}" == ghcr.io/mmkolpakov/robotics-runtime-infra/benchmark:0.8.0@* &&
   "${EDGE_IMAGE}" == ghcr.io/mmkolpakov/robotics-runtime-infra/edge:0.8.0@* &&
   "${SENSOR_IMAGE}" == ghcr.io/mmkolpakov/robotics-runtime-infra/sensor:0.8.0@* ]]
[[ "${ROBOTICS_RELEASE_IMAGES_PREPARED}" == 1 ]]
expected="$(jq '.images | length + 2' "${producer_plan}")"
jq -e --argjson count "${expected}" 'length == $count' <<<"${ROBOTICS_RELEASE_APPROVED_IMAGES}"
[[ " ${FOUNDATION_RELEASE_ARTIFACT_ARGUMENTS[*]} " == *" other_evidence:release/release-plan.json=${evidence}/release-plan.json "* ]]
[[ "$(stat -c %a "${evidence}/release-plan.json")" == 444 ]]
[[ "$(sed -n '3p' "${trace}")" == *'/policy-tooling:0.8.0@'* ]]
[[ "$(grep -c '^docker pull ' "${trace}")" == 5 ]]
SH
  run bash "${consumer_probe}" "${REPO_ROOT}" "${output_dir}" \
    "${BATS_TEST_TMPDIR}/consumer-evidence" "${release_plan}"
  if [[ "${status}" -ne 0 ]]; then
    printf 'consumer status=%s\n%s\n' "${status}" "${output}"
  fi
  [ "${status}" -eq 0 ]
}

@test "released Compose reset removes trusted base builds and preserves executable configuration" {
  export ROBOTICS_DOMAIN_ID=qualification-domain ROBOTICS_RUN_ID=run-release-reset
  export ROBOTICS_ATTACH_NETWORK=release-reset-network
  common=(docker compose -f compose.yaml)
  for layout in foundation edge; do
    if [[ "${layout}" == foundation ]]; then
      files=(-f compose.foundation.yaml -f compose.stepped.yaml -f compose.record.yaml
        -f compose.evidence.yaml -f compose.observability.yaml)
    else
      files=(-f compose.edge-attach.yaml)
    fi
    run "${common[@]}" "${files[@]}" --profile '*' config --format json
    [ "${status}" -eq 0 ]
    before="${output}"
    run "${common[@]}" "${files[@]}" -f compose.released.yaml --profile '*' config --format json
    [ "${status}" -eq 0 ]
    after="${output}"
    jq -e 'all(.services[]; has("build") | not)' <<<"${after}"
    [ "$(jq -Sc 'del(.services[].build)' <<<"${before}")" = "$(jq -Sc . <<<"${after}")" ]
  done

  cat >"${BATS_TEST_TMPDIR}/consumer.yaml" <<YAML
services:
  product:
    image: local/consumer/product:dev
    build:
      context: ${REPO_ROOT}
YAML
  run "${common[@]}" -f "${BATS_TEST_TMPDIR}/consumer.yaml" \
    -f compose.released.yaml --profile '*' config --format json
  [ "${status}" -eq 0 ]
  jq -e '.services.product | has("build")' <<<"${output}"
}

@test "upstream lock extraction rejects an unpinned trusted default" {
  fixture="${BATS_TEST_TMPDIR}/upstream"
  mkdir "${fixture}"
  printf 'services:\n  simulation:\n    image: local/simulation:dev\n' >"${fixture}/compose.yaml"
  printf 'services:\n  otel-collector:\n    image: "${OTEL_COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:latest}"\n' \
    >"${fixture}/compose.observability.yaml"
  # shellcheck source=scripts/ci/release/upstream-images.sh
  source scripts/ci/release/upstream-images.sh
  CI_REPO_ROOT="${fixture}" run ci_release_otel_collector_reference
  [ "${status}" -ne 0 ]
  printf 'services:\n  edge-attach-data-plane:\n    image: "${EDGE_ATTACH_DATA_PLANE_IMAGE:-registry.k8s.io/pause:latest}"\n' \
    >"${fixture}/compose.edge-attach.yaml"
  CI_REPO_ROOT="${fixture}" run ci_release_edge_attach_data_plane_reference
  [ "${status}" -ne 0 ]
}

@test "immutable promotion distinguishes missing tags from registry ambiguity" {
  fake_bin="${BATS_TEST_TMPDIR}/promotion-bin"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
test "$1 $2 $3" = "buildx imagetools inspect"
case "${FAKE_REGISTRY_STATE}" in
  missing)
    printf 'ERROR: %s: not found\n' "$6" >&2
    exit 1
    ;;
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
    FAKE_REGISTRY_STATE=missing \
    scripts/ci/release/promote-immutable-tags.sh \
      check "${image}" "${digest}" - "${image}:0.8.0"
  [ "${status}" -eq 0 ]

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

@test "released extra images use the runner's transitive selected dependency closure" {
  probe="${BATS_TEST_TMPDIR}/prepare-selected.sh"
  model="${BATS_TEST_TMPDIR}/selected-model.json"
  prepared="${BATS_TEST_TMPDIR}/prepared-images"
  cat >"${probe}" <<'SH'
set -Eeuo pipefail
resolved_model="$1"
shift
extra_services=("$@")
ROBOTICS_RUNTIME_MODE=released
foundation_prepare_released_image() { printf '%s\n' "$1" >>"${PREPARED_IMAGES}"; }
SH
  sed -n '/^if .*released.*extra_services.*; then$/,/^observer=""$/p' \
    scripts/ci/foundation/run-acceptance.sh | sed '$d' >>"${probe}"
  grep -F 'extra_images=' "${probe}"
  digest="$(printf '%064d' 1)"
  jq -n --arg digest "${digest}" '{
    services: {
      selected: {image: ("repo/selected@sha256:" + $digest), depends_on: {left: {}, right: {}}},
      left: {image: ("repo/left@sha256:" + $digest), depends_on: {leaf: {}}},
      right: {image: ("repo/right@sha256:" + $digest), depends_on: {leaf: {}}},
      leaf: {image: ("repo/leaf@sha256:" + $digest)},
      unselected: {image: ("repo/unselected@sha256:" + $digest)}
    }
  }' >"${model}"
  run env PREPARED_IMAGES="${prepared}" bash "${probe}" "${model}" selected selected
  [ "${status}" -eq 0 ]
  expected="$(printf 'repo/%s@sha256:%s\n' leaf "${digest}" left "${digest}" right "${digest}" selected "${digest}")"
  [ "$(<"${prepared}")" = "${expected}" ]

  : >"${prepared}"
  run env PREPARED_IMAGES="${prepared}" bash "${probe}" "${model}" missing
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown requested consumer service: missing"* ]]
  [ ! -s "${prepared}" ]
}
