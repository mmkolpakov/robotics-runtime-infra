#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"

foundation_require_env \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN \
  ACTIONS_ID_TOKEN_REQUEST_URL \
  GITHUB_REF \
  GITHUB_REPOSITORY \
  GITHUB_WORKFLOW_REF
command -v cosign >/dev/null 2>&1 || {
  printf 'cosign is required for keyless qualification\n' >&2
  exit 69
}

policy="${root}/trust/qualification-policy.json"
trusted_root="${root}/trust/qualification.trusted-root.json"
expected_identity="$(
  jq -er '
    .certificate_identities
    | if length == 1 then .[0]
      else error("exactly one certificate identity is required")
      end
  ' "${policy}"
)"
actual_identity="https://github.com/${GITHUB_WORKFLOW_REF}"
[[ "${GITHUB_REPOSITORY}" == mmkolpakov/robotics-runtime-infra ]] || {
  printf 'keyless qualification is restricted to the canonical repository\n' >&2
  exit 65
}
[[ "${GITHUB_REF}" == refs/heads/main ]] || {
  printf 'keyless qualification is restricted to refs/heads/main\n' >&2
  exit 65
}
[[ "${actual_identity}" == "${expected_identity}" ]] || {
  printf 'workflow identity does not match the qualification policy\n' >&2
  exit 65
}
[[ "$(sha256sum "${trusted_root}" | cut -d' ' -f1)" == \
  "$(jq -er '.trusted_root_sha256' "${policy}")" ]] || {
  printf 'trusted root digest does not match the qualification policy\n' >&2
  exit 65
}

contracts_dir="${root}/dependencies/robotics-runtime-contracts"
uv sync --project "${contracts_dir}" --locked --all-groups
export ROBOTICS_CONTRACTS_CLI="${contracts_dir}/.venv/bin/robotics-contracts"

mapfile -t mcap_summaries < <(
  find artifacts -maxdepth 1 -type f -name '*.mcap-summary.json' -print |
    LC_ALL=C sort
)
mapfile -t mcap_files < <(
  find artifacts/raw-mcap -maxdepth 1 -type f -name '*.mcap' -print |
    LC_ALL=C sort
)
test "${#mcap_summaries[@]}" -ge 1
test "${#mcap_files[@]}" -eq "${#mcap_summaries[@]}"

qualification_inputs=(
  --scenario artifacts/scenario.yaml
  --runtime-manifest primary=artifacts/runtime-manifest.json
  --acceptance-run artifacts/acceptance-run.json
  --result primary=artifacts/acceptance-results/acceptance-result.json
  --aggregate artifacts/acceptance-results/acceptance-aggregate.json
  --evidence-index primary=artifacts/evidence-index.json
  --evidence metrics:metrics.otlp.json=artifacts/metrics.otlp.json
  --evidence junit:junit.xml=artifacts/acceptance-results/junit.xml
  --evidence other_evidence:fastdds-profile.xml=artifacts/fastdds-profile.xml
  --evidence other_evidence:host-topology.json=artifacts/host-topology.json
  --evidence other_evidence:runtime-resources.json=artifacts/runtime-resources.json
)
for index in "${!mcap_summaries[@]}"; do
  qualification_inputs+=(
    --mcap-summary "primary-${index}=${mcap_summaries[$index]}"
    --evidence "raw_mcap:primary-${index}.mcap=${mcap_files[$index]}"
  )
done

bundle="artifacts/qualification.keyless.sigstore.json"
cosign attest-blob --yes \
  --use-signing-config=true \
  --trusted-root "${trusted_root}" \
  --statement artifacts/qualification-statement.json \
  --bundle "${bundle}"
scripts/qualification/verify-bundle \
  --bundle "${bundle}" \
  --trusted-root "${trusted_root}" \
  --policy "${policy}" \
  "${qualification_inputs[@]}"

cp "${policy}" artifacts/qualification-policy.json
cp "${trusted_root}" artifacts/qualification.trusted-root.json
