#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${root}"

command -v cosign >/dev/null 2>&1
: "${ROBOTICS_CONTRACTS_CLI:?ROBOTICS_CONTRACTS_CLI is required}"

work="$(mktemp -d)"
cleanup() {
  rm -f -- "$work/aggregate.json" "$work/statement.json" "$work/formatted.json" \
    "$work/qualification.sigstore.json" "$work/qualification.pub" \
    "$work/foreign.sigstore.json" "$work/foreign.pub" "$work/rejection.log"
  rmdir -- "$work"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Test the adapter and real cryptographic boundary against the pinned v1
# reference inventory. ROS/provider observations remain labelled fixtures.
fixtures="$root/dependencies/robotics-runtime/packages/contracts/tests/fixtures/qualification/transport"
cp "$fixtures/aggregate.json" "$work/aggregate.json"
artifact_arguments=()
while IFS=$'\t' read -r kind subject file; do
  path="$fixtures/$file"
  if [[ "$kind" == acceptance_aggregate ]]; then
    path="$work/aggregate.json"
  fi
  artifact_arguments+=(--artifact "$kind:$subject=$path")
done < <(jq -r '.[] | [.kind, .subject_name, .file] | @tsv' "$fixtures/artifacts.json")
scripts/qualification/create-statement \
  "${artifact_arguments[@]}" \
  --output "${work}/statement.json"
# A valid signed statement need not retain the producer's whitespace/key order.
jq . "${work}/statement.json" >"${work}/formatted.json"
bash scripts/ci/foundation/sign-ephemeral-qualification.sh \
  "${work}/formatted.json" \
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
  "${artifact_arguments[@]}" >"$work/rejection.log" 2>&1; then
  printf 'qualification bundle accepted a foreign public key\n' >&2
  exit 1
fi
grep -F 'Sigstore verification failed for the supplied public key' "$work/rejection.log"

# Same JSON value, different original bytes: links remain valid, the signature's
# aggregate digest must reject the changed file.
printf '\n' >>"${work}/aggregate.json"
if scripts/qualification/verify-bundle \
  --bundle "${work}/qualification.sigstore.json" \
  --key "${work}/qualification.pub" \
  "${artifact_arguments[@]}" >"$work/rejection.log" 2>&1; then
  printf 'qualification bundle accepted a foreign aggregate digest\n' >&2
  exit 1
fi
grep -F 'Sigstore verification failed for the supplied public key' "$work/rejection.log"
printf 'real Cosign v1 qualification checks passed\n'
