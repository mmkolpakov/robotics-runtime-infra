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
  rm -rf -- "$work/inputs" "$work/portable" "$work/relocated"
  rmdir -- "$work"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Test the adapter and real cryptographic boundary against the infra v1
# regression inventory. ROS/provider observations remain labelled fixtures.
mkdir "$work/inputs"
cp "$root/test/qualification/fixtures/"* "$work/inputs/"
fixtures="$work/inputs"
cp "$fixtures/acceptance-aggregate-transport.json" "$work/aggregate.json"
artifact_arguments=()
while IFS=$'\t' read -r kind subject file; do
  path="$fixtures/$file"
  if [[ "$kind" == acceptance_aggregate ]]; then
    path="$work/aggregate.json"
  fi
  artifact_arguments+=(--artifact "$kind:$subject=$path")
done < <(jq -r '.artifacts[] | [.kind, .subject_name, .file] | @tsv' "$fixtures/transport-artifacts.json")
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

(
  cd "$work"
  "$root/scripts/qualification/package-artifacts" \
    "${artifact_arguments[@]}" --output "$work/portable"
  mv portable relocated
  cd relocated
  mapfile -t portable_arguments <qualification-arguments.txt
  "$root/scripts/qualification/verify-bundle" \
    "${portable_arguments[@]}" \
    --bundle "$work/qualification.sigstore.json" --key "$work/qualification.pub"
)

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
printf 'real Cosign v1 qualification and portable copy checks passed\n'
