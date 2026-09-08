#!/usr/bin/env bash
set -Eeuo pipefail

test "$#" -eq 3 || {
  printf 'usage: compare-oci-archives.sh FIRST SECOND REPORT_DIR\n' >&2
  exit 64
}

first="$1"
second="$2"
report_dir="$3"
mkdir -p "${report_dir}"

describe_archive() {
  local archive="$1" name="$2" manifest config
  tar -xOf "${archive}" index.json >"${report_dir}/${name}-index.json" || return
  manifest="$(jq -er '
    select((.manifests | length) == 1) | .manifests[0].digest
    | select(test("^sha256:[a-f0-9]{64}$"))
  ' "${report_dir}/${name}-index.json")" || return
  tar -xOf "${archive}" "blobs/sha256/${manifest#sha256:}" \
    >"${report_dir}/${name}-manifest.json" || return
  config="$(jq -er '
    .config.digest | select(test("^sha256:[a-f0-9]{64}$"))
  ' "${report_dir}/${name}-manifest.json")" || return
  tar -xOf "${archive}" "blobs/sha256/${config#sha256:}" \
    >"${report_dir}/${name}-config.json" || return
  printf '%s\n' "${manifest}"
}

first_digest="$(describe_archive "${first}" first)"
second_digest="$(describe_archive "${second}" second)"
printf 'first OCI manifest:  %s\nsecond OCI manifest: %s\n' \
  "${first_digest}" "${second_digest}" | tee "${report_dir}/manifests.txt"
if test "${first_digest}" = "${second_digest}"; then
  printf 'reproducible OCI manifest: %s\n' "${first_digest}"
  exit 0
fi

diagnose_difference() {
  diffoci load --platform linux/amd64 --input "${first}" || return
  diffoci load --platform linux/amd64 --input "${second}" || return
  # Import names differ so both archives remain addressable in the same store.
  # Manifest equality above remains the gate, regardless of this tool's verdict.
  diffoci diff --platform linux/amd64 --pull never --ignore-image-name \
    --report-dir "${report_dir}/diffoci" \
    localhost/robotics-reproducibility:first \
    localhost/robotics-reproducibility:second
}

diagnostic_status=0
diagnose_difference >"${report_dir}/diffoci.log" 2>&1 || diagnostic_status="$?"
cat "${report_dir}/diffoci.log"
printf 'diffoci exit code: %s\n' "${diagnostic_status}" \
  | tee "${report_dir}/diagnostic-status.txt"
exit 1
