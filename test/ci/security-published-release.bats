#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  FIXTURE_ROOT="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${FIXTURE_ROOT}/scripts/ci/security" "${BATS_TEST_TMPDIR}/bin" "${BATS_TEST_TMPDIR}/digests"
  cp "${REPO_ROOT}/scripts/ci/security/scan-published-release.sh" "${FIXTURE_ROOT}/scripts/ci/security/"
  cp "${REPO_ROOT}/scripts/ci/lib.sh" "${FIXTURE_ROOT}/scripts/ci/"
  export INSPECT_FILE="${BATS_TEST_TMPDIR}/inspect.json"
  export INSPECT_CALLS="${BATS_TEST_TMPDIR}/inspect.calls"
  export SCAN_CALLS="${BATS_TEST_TMPDIR}/scan.calls"
  export INSPECT_STATUS=0 SCAN_FAIL='' TRIVY_IMAGE=registry.example/trivy@sha256:fixture
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  PIN=sha256:12e9ba894213e65f9c076aec1180a36ceeab7eeb9a742c3f5ccdda6d66cb25df
  REF="ghcr.io/mmkolpakov/robotics-runtime-infra/benchmark:0.11.0-rc2@${PIN}"
  printf 'BENCHMARK_IMAGE=%s\n' "${REF}" >"${BATS_TEST_TMPDIR}/release.env"
  printf '%s\n' "${REF}" >"${BATS_TEST_TMPDIR}/digests/benchmark.txt"
  cat >"${BATS_TEST_TMPDIR}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -eu
[[ "$#" == 6 && "$1 $2 $3 $4" == 'buildx imagetools inspect --format' &&
  "$5" == '{"manifest":{{json .Manifest}},"image":{{json .Image}}}' ]] || exit 64
printf '%s\n' "$6" >>"${INSPECT_CALLS}"
[[ "${INSPECT_STATUS}" == 0 ]] || exit "${INSPECT_STATUS}"
cat "${INSPECT_FILE}"
SH
  cat >"${FIXTURE_ROOT}/scripts/ci/security/scan-image.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s|%s|%s\n' "$1" "$2" "$3" >>"${SCAN_CALLS}"
[[ "$1" != "${SCAN_FAIL}" ]]
SH
  chmod +x "${BATS_TEST_TMPDIR}/bin/docker" "${FIXTURE_ROOT}/scripts/ci/security/scan-image.sh"
  benchmark_index
  jq -n --arg digest "${PIN}" --slurpfile raw "${BATS_TEST_TMPDIR}/index.json" '
    {manifest: ($raw[0] + {digest: $digest}), image: {
      "linux/amd64": {os: "linux", architecture: "amd64"},
      "linux/arm64": {os: "linux", architecture: "arm64"}}}
  ' >"${INSPECT_FILE}"
}

scan_release() {
  "${FIXTURE_ROOT}/scripts/ci/security/scan-published-release.sh" \
    "${BATS_TEST_TMPDIR}/release.env" "${BATS_TEST_TMPDIR}/digests"
}

mutate() {
  jq "$1" "${INSPECT_FILE}" >"${INSPECT_FILE}.new"
  mv "${INSPECT_FILE}.new" "${INSPECT_FILE}"
}

assert_metadata_refused() {
  run scan_release
  [ "${status}" -eq 65 ]
  [ ! -e "${SCAN_CALLS}" ]
}

benchmark_index() {
  # Exact registry index bytes for benchmark:0.11.0-rc2, without a trailing newline.
  printf '%s' "$(cat <<'JSON'
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:fa5be5ecf194a8d531e89397d4fcce643b8f29f787f68f474a750c21c13c7b61",
      "size": 6326,
      "platform": {
        "architecture": "amd64",
        "os": "linux"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:e1fd103772e4b8a37c0b66caeef402db9ece1e0aa5faae45c72c5b1991b63c94",
      "size": 6326,
      "platform": {
        "architecture": "arm64",
        "os": "linux"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:eb88141f93ab664d53255bb6f9105947673997f61488a0456e7b659f436a019f",
      "size": 841,
      "annotations": {
        "vnd.docker.reference.digest": "sha256:fa5be5ecf194a8d531e89397d4fcce643b8f29f787f68f474a750c21c13c7b61",
        "vnd.docker.reference.type": "attestation-manifest"
      },
      "platform": {
        "architecture": "unknown",
        "os": "unknown"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:da3b21600249f1b484073699db5580726cf6a398980d98a0ddcc3d89194ee83f",
      "size": 841,
      "annotations": {
        "vnd.docker.reference.digest": "sha256:e1fd103772e4b8a37c0b66caeef402db9ece1e0aa5faae45c72c5b1991b63c94",
        "vnd.docker.reference.type": "attestation-manifest"
      },
      "platform": {
        "architecture": "unknown",
        "os": "unknown"
      }
    }
  ]
}
JSON
)" >"${BATS_TEST_TMPDIR}/index.json"
}

@test "retired benchmark target scans both runtime platforms from its published index" {
  [ "$(sha256sum "${BATS_TEST_TMPDIR}/index.json" | cut -d' ' -f1)" = "${PIN#sha256:}" ]
  run scan_release
  [ "${status}" -eq 0 ]
  [ "$(cat "${INSPECT_CALLS}")" = "${REF}" ]
  [ "$(cat "${SCAN_CALLS}")" = "${REF}|published-benchmark|linux/amd64,linux/arm64" ]
}

@test "Docker manifest list uses the same complete platform coverage" {
  mutate '.manifest.mediaType = "application/vnd.docker.distribution.manifest.list.v2+json"'
  run scan_release
  [ "${status}" -eq 0 ]
  [[ "$(cat "${SCAN_CALLS}")" == *'|linux/amd64,linux/arm64' ]]
}

@test "single OCI and Docker manifests use the actual image config" {
  for media in application/vnd.oci.image.manifest.v1+json application/vnd.docker.distribution.manifest.v2+json; do
    jq -n --arg digest "${PIN}" --arg media "${media}" \
      '{manifest: {digest: $digest, mediaType: $media}, image: {os: "linux", architecture: "arm64"}}' >"${INSPECT_FILE}"
    run scan_release
    [ "${status}" -eq 0 ]
  done
  [ "$(grep -c '|linux/arm64$' "${SCAN_CALLS}")" -eq 2 ]
}

@test "wrong root digest and unknown media types fail closed" {
  for change in '.manifest.digest = "sha256:foreign"' '.manifest.mediaType = "text/plain"'; do
    cp "${INSPECT_FILE}" "${INSPECT_FILE}.original"
    mutate "${change}"
    assert_metadata_refused
    mv "${INSPECT_FILE}.original" "${INSPECT_FILE}"
  done
}

@test "unavailable malformed and multiple inspect results fail closed" {
  export INSPECT_STATUS=1
  assert_metadata_refused
  export INSPECT_STATUS=0
  printf '{' >"${INSPECT_FILE}"
  assert_metadata_refused
  printf '{}\n{}\n' >"${INSPECT_FILE}"
  assert_metadata_refused
}

@test "attestations need explicit type and a reference to an indexed runtime image" {
  for change in \
    '.manifest.manifests[2].annotations["vnd.docker.reference.type"] = "other"' \
    '.manifest.manifests[2].annotations["vnd.docker.reference.digest"] = ("sha256:" + ("f" * 64))' \
    'del(.manifest.manifests[2].annotations["vnd.docker.reference.digest"])' \
    '.manifest.manifests[2].annotations["com.docker.reference.digest"] = ("sha256:" + ("f" * 64))'; do
    cp "${INSPECT_FILE}" "${INSPECT_FILE}.original"
    mutate "${change}"
    assert_metadata_refused
    mv "${INSPECT_FILE}.original" "${INSPECT_FILE}"
  done
}

@test "an attestation cannot hide a runtime platform" {
  mutate '.manifest.manifests[2].platform = {os: "linux", architecture: "arm64"}'
  assert_metadata_refused
}

@test "reference-only descriptors cannot be silently removed by the Buildx loader" {
  mutate '.manifest.manifests[0].annotations = {"vnd.docker.reference.digest": .manifest.manifests[1].digest}'
  assert_metadata_refused
}

@test "unknown missing and unsupported runtime platforms are not skipped" {
  for change in \
    '.manifest.manifests[0].platform = {os: "unknown", architecture: "unknown"}' \
    'del(.manifest.manifests[0].platform)' \
    '.manifest.manifests[0].platform.architecture = "ppc64le"' \
    '.manifest.manifests[0].platform.variant = "v9"'; do
    cp "${INSPECT_FILE}" "${INSPECT_FILE}.original"
    mutate "${change}"
    assert_metadata_refused
    mv "${INSPECT_FILE}.original" "${INSPECT_FILE}"
  done
}

@test "duplicate platform descriptors cannot overwrite each other in the Buildx map" {
  mutate '.manifest.manifests += [.manifest.manifests[0] | .digest = ("sha256:" + ("3" * 64))]'
  assert_metadata_refused
}

@test "duplicate descriptor digests and invalid runtime digests fail closed" {
  for change in \
    '.manifest.manifests += [.manifest.manifests[0]]' \
    '.manifest.manifests[0].digest = "not-a-digest"'; do
    cp "${INSPECT_FILE}" "${INSPECT_FILE}.original"
    mutate "${change}"
    assert_metadata_refused
    mv "${INSPECT_FILE}.original" "${INSPECT_FILE}"
  done
}

@test "missing empty and inconsistent image config maps fail closed" {
  for change in \
    '.image = null' '.image = {}' \
    'del(.image["linux/arm64"])' \
    '.image["linux/amd64"].architecture = "arm64"' \
    '.image["linux/amd64"].os = "windows"'; do
    cp "${INSPECT_FILE}" "${INSPECT_FILE}.original"
    mutate "${change}"
    assert_metadata_refused
    mv "${INSPECT_FILE}.original" "${INSPECT_FILE}"
  done
}

@test "empty descriptor lists fail closed" {
  mutate '.manifest.manifests = []'
  assert_metadata_refused
}

@test "release digest records and immutable pins remain required" {
  printf '%s\n' 'ghcr.io/foreign/benchmark@sha256:other' >"${BATS_TEST_TMPDIR}/digests/benchmark.txt"
  assert_metadata_refused
  [ ! -e "${INSPECT_CALLS}" ]
  printf 'BENCHMARK_IMAGE=ghcr.io/mmkolpakov/robotics-runtime-infra/benchmark:latest\n' >"${BATS_TEST_TMPDIR}/release.env"
  assert_metadata_refused
  [ ! -e "${INSPECT_CALLS}" ]
}

@test "external images retain the explicit two-architecture policy without registry lookup" {
  external="registry.k8s.io/pause:3.10.1@${PIN}"
  printf 'EXTERNAL_IMAGE=%s\n' "${external}" >"${BATS_TEST_TMPDIR}/release.env"
  run scan_release
  [ "${status}" -eq 0 ]
  [ ! -e "${INSPECT_CALLS}" ]
  [ "$(cat "${SCAN_CALLS}")" = "${external}|published-pause|linux/amd64,linux/arm64" ]
}

@test "scan failure remains red and does not omit later published images" {
  second="ghcr.io/mmkolpakov/robotics-runtime-infra/retired-other:0.11.0-rc2@${PIN}"
  printf 'OTHER_IMAGE=%s\n' "${second}" >>"${BATS_TEST_TMPDIR}/release.env"
  printf '%s\n' "${second}" >"${BATS_TEST_TMPDIR}/digests/retired-other.txt"
  export SCAN_FAIL="${REF}"
  run scan_release
  [ "${status}" -eq 1 ]
  [ "$(wc -l <"${SCAN_CALLS}")" -eq 2 ]
  grep -Fx "${second}|published-retired-other|linux/amd64,linux/arm64" "${SCAN_CALLS}"
}

@test "all fifteen legacy image ids are visited even when target names have changed" {
  # Reuse benchmark metadata to isolate cohort traversal from registry access.
  : >"${BATS_TEST_TMPDIR}/release.env"
  for id in acceptance-observer benchmark edge evidence-sink inference-cpu inference-intel-cpu \
    permit-preflight policy-tooling provider-conformance-cpu sensor sensor-inference-cpu \
    sensor-inference-intel-cpu simulation; do
    reference="ghcr.io/mmkolpakov/robotics-runtime-infra/${id}:0.11.0-rc2@${PIN}"
    variable="${id^^}"
    variable="${variable//-/_}"
    printf '%s_IMAGE=%s\n' "${variable}" "${reference}" >>"${BATS_TEST_TMPDIR}/release.env"
    printf '%s\n' "${reference}" >"${BATS_TEST_TMPDIR}/digests/${id}.txt"
  done
  printf 'OTEL_IMAGE=otel/opentelemetry-collector-contrib:0.153.0@%s\n' "${PIN}" >>"${BATS_TEST_TMPDIR}/release.env"
  printf 'PAUSE_IMAGE=registry.k8s.io/pause:3.10.1@%s\n' "${PIN}" >>"${BATS_TEST_TMPDIR}/release.env"
  run scan_release
  [ "${status}" -eq 0 ]
  [ "$(wc -l <"${SCAN_CALLS}")" -eq 15 ]
  [ "$(wc -l <"${INSPECT_CALLS}")" -eq 13 ]
  [ "$(cut -d'|' -f2 "${SCAN_CALLS}" | sort -u | wc -l)" -eq 15 ]
  [ "$(grep -c '|linux/amd64,linux/arm64$' "${SCAN_CALLS}")" -eq 15 ]
}
