#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${root}"

command -v cosign >/dev/null 2>&1
: "${ROBOTICS_CONTRACTS_CLI:?ROBOTICS_CONTRACTS_CLI is required}"

work="$(mktemp -d)"
cleanup() {
  rm -rf -- "${work}"
}
trap cleanup EXIT HUP INT TERM

fixtures="${root}/test/qualification/fixtures"
cp "${fixtures}/acceptance-scenario.yaml" "${work}/scenario.yaml"
cp "${fixtures}/acceptance-run.json" "${work}/run.json"
cp "${fixtures}/runtime-manifest.json" "${work}/runtime.json"
cp "${fixtures}/acceptance-result.json" "${work}/result.json"
cp "${fixtures}/acceptance-aggregate.json" "${work}/aggregate.json"
cp "${fixtures}/evidence-index.json" "${work}/evidence-index.json"
cp "${fixtures}/mcap-summary.json" "${work}/mcap-summary.json"
cp "${fixtures}/diagnostics.json" "${work}/diagnostics.json"

profile="${root}/config/fastdds/udp-only.xml"
profile_sha256="$(sha256sum "${profile}" | cut -d' ' -f1)"
jq --arg digest "${profile_sha256}" \
  '.data_plane.fastdds_profile_sha256 = $digest' \
  "${work}/runtime.json" >"${work}/runtime.with-profile.json"
mv "${work}/runtime.with-profile.json" "${work}/runtime.json"
jq --arg digest "$(sha256sum "${work}/runtime.json" | cut -d' ' -f1)" \
  '.runtime_manifest_sha256 = $digest' \
  "${work}/result.json" >"${work}/result.with-runtime.json"
mv "${work}/result.with-runtime.json" "${work}/result.json"
jq --arg digest "$(sha256sum "${work}/result.json" | cut -d' ' -f1)" \
  '.per_domain_results[0].result_sha256 = $digest' \
  "${work}/aggregate.json" >"${work}/aggregate.with-result.json"
mv "${work}/aggregate.with-result.json" "${work}/aggregate.json"

artifact_arguments=(
  --scenario "${work}/scenario.yaml"
  --runtime-manifest "primary=${work}/runtime.json"
  --acceptance-run "${work}/run.json"
  --result "primary=${work}/result.json"
  --aggregate "${work}/aggregate.json"
  --evidence-index "primary=${work}/evidence-index.json"
  --mcap-summary "control-0=${work}/mcap-summary.json"
  --evidence "other_evidence:diagnostics.json=${work}/diagnostics.json"
  --evidence "raw_mcap:recording-0.mcap=${root}/test/fixtures/playback/golden/golden_0.mcap"
  --evidence "metrics:metrics.otlp.json=${fixtures}/metrics.otlp.json"
  --evidence "traces:traces.otlp.jsonl=${fixtures}/traces.otlp.jsonl"
  --evidence "other_evidence:fastdds-profile.xml=${profile}"
)
scripts/qualification/create-statement \
  "${artifact_arguments[@]}" \
  --output "${work}/statement.json"
bash scripts/ci/foundation/sign-ephemeral-qualification.sh \
  "${work}/statement.json" \
  "${work}/qualification.sigstore.json" \
  "${work}/qualification.pub"
scripts/qualification/verify-bundle \
  --bundle "${work}/qualification.sigstore.json" \
  --key "${work}/qualification.pub" \
  "${artifact_arguments[@]}"

bash scripts/ci/foundation/sign-ephemeral-qualification.sh \
  "${work}/statement.json" \
  "${work}/foreign.sigstore.json" \
  "${work}/foreign.pub"
if scripts/qualification/verify-bundle \
  --bundle "${work}/qualification.sigstore.json" \
  --key "${work}/foreign.pub" \
  "${artifact_arguments[@]}" >/dev/null 2>&1; then
  printf 'qualification bundle accepted a foreign public key\n' >&2
  exit 1
fi

jq '.generated_at = "2026-07-21T10:02:00Z"' \
  "${work}/aggregate.json" >"${work}/aggregate.tampered.json"
mv "${work}/aggregate.tampered.json" "${work}/aggregate.json"
if scripts/qualification/verify-bundle \
  --bundle "${work}/qualification.sigstore.json" \
  --key "${work}/qualification.pub" \
  "${artifact_arguments[@]}" >/dev/null 2>&1; then
  printf 'qualification bundle accepted a foreign aggregate digest\n' >&2
  exit 1
fi
