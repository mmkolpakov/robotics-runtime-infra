#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
  FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
  REPORT="${BATS_TEST_TMPDIR}/report"
  mkdir -p "${FAKE_BIN}"
  cat >"${FAKE_BIN}/diffoci" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'diagnostic invocation: %s\n' "$*"
if test "$1" = diff; then
  exit "${DIFFOCI_EXIT:-0}"
fi
EOF
  chmod +x "${FAKE_BIN}/diffoci"
}

make_archive() {
  local name="$1" marker="$2" archive_dir config manifest
  archive_dir="${BATS_TEST_TMPDIR}/${name}"
  mkdir -p "${archive_dir}/blobs/sha256"
  jq -nc --arg marker "${marker}" '{
    architecture: "amd64", os: "linux", config: {Env: [$marker]},
    rootfs: {type: "layers", diff_ids: []}, history: []
  }' >"${archive_dir}/config.json"
  config="$(sha256sum "${archive_dir}/config.json" | cut -d ' ' -f 1)"
  cp "${archive_dir}/config.json" "${archive_dir}/blobs/sha256/${config}"
  jq -nc --arg digest "sha256:${config}" '{
    schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json",
    config: {mediaType: "application/vnd.oci.image.config.v1+json", digest: $digest},
    layers: []
  }' >"${archive_dir}/manifest.json"
  manifest="$(sha256sum "${archive_dir}/manifest.json" | cut -d ' ' -f 1)"
  cp "${archive_dir}/manifest.json" "${archive_dir}/blobs/sha256/${manifest}"
  jq -nc --arg digest "sha256:${manifest}" '{
    schemaVersion: 2, manifests: [{digest: $digest}]
  }' >"${archive_dir}/index.json"
  tar -cf "${BATS_TEST_TMPDIR}/${name}.tar" -C "${archive_dir}" index.json blobs
}

compare_archives() {
  run env "PATH=${FAKE_BIN}:${PATH}" "DIFFOCI_EXIT=${1:-0}" \
    scripts/ci/reproducibility/compare-oci-archives.sh \
      "${BATS_TEST_TMPDIR}/first.tar" "${BATS_TEST_TMPDIR}/second.tar" "${REPORT}"
}

@test "identical OCI manifests pass without invoking the diagnostic tool" {
  make_archive first same
  make_archive second same
  compare_archives 2
  [ "${status}" -eq 0 ]
  [ -s "${REPORT}/first-config.json" ]
  [ ! -e "${REPORT}/diffoci.log" ]
}

@test "different OCI manifests fail even when the diagnostic tool accepts them" {
  make_archive first first-content
  make_archive second second-content
  compare_archives 0
  [ "${status}" -eq 1 ]
  [ -s "${REPORT}/first-manifest.json" ]
  [ -s "${REPORT}/second-manifest.json" ]
  [ "$(jq -r '.config.Env[0]' "${REPORT}/first-config.json")" = first-content ]
  [ "$(jq -r '.config.Env[0]' "${REPORT}/second-config.json")" = second-content ]
  [ "$(cat "${REPORT}/diagnostic-status.txt")" = 'diffoci exit code: 0' ]
}

@test "diagnostic failure retains the original manifest mismatch and metadata" {
  make_archive first first-content
  make_archive second second-content
  compare_archives 2
  [ "${status}" -eq 1 ]
  [ -s "${REPORT}/manifests.txt" ]
  [ -s "${REPORT}/diffoci.log" ]
  [ "$(cat "${REPORT}/diagnostic-status.txt")" = 'diffoci exit code: 2' ]
}

@test "a missing manifest blob cannot turn an unreadable digest into a pass" {
  make_archive first same
  make_archive second same
  # Retain the index but omit the blob it references.
  tar -cf "${BATS_TEST_TMPDIR}/first.tar" -C "${BATS_TEST_TMPDIR}/first" index.json
  compare_archives
  [ "${status}" -ne 0 ]
  [[ "${output}" != *'reproducible OCI manifest:'* ]]
}
