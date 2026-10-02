#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/ci/foundation/lib.sh
source "${script_dir}/lib.sh"

root="$(foundation_repository_root)"
cd "${root}"
readonly foundation_project="${root}/dependencies/robotics-runtime"

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
[[ "${GITHUB_REPOSITORY}" == "$(jq -er '.infra.repository' "${root}/config/trust/identities.json")" ]] || {
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

uv sync --project "${foundation_project}" --locked --all-packages --no-default-groups --no-editable
uv pip check --python "${foundation_project}/.venv/bin/python"
export ROBOTICS_CONTRACTS_CLI="${foundation_project}/.venv/bin/robotics-contracts"

qualification_package="${root}/artifacts/qualification"
test -s "${qualification_package}/qualification-arguments.txt"
test -s "${qualification_package}/qualification-statement.json"
cd "${qualification_package}"
mapfile -t qualification_inputs <qualification-arguments.txt

bundle="qualification.keyless.sigstore.json"
cosign attest-blob --yes \
  --use-signing-config=true \
  --trusted-root "${trusted_root}" \
  --statement qualification-statement.json \
  --bundle "${bundle}"
"${root}/scripts/qualification/verify-bundle" \
  "${qualification_inputs[@]}" \
  --bundle "${bundle}" \
  --trusted-root "${trusted_root}" \
  --policy "${policy}"

# These copies record the signing configuration; verifiers pin their own trust inputs.
cp "${policy}" qualification-policy.json
cp "${trusted_root}" qualification.trusted-root.json
