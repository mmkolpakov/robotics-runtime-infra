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
  rm -rf -- "$work/inputs" "$work/portable" "$work/relocated" "$work/parent" "$work/parent-tooling" "$work/parent-tools"
  rm -f -- "$work/parent-verify.sh" "$work/parent-unbound.sh"
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


# Reproduce child-local binding loss at the actual replay parent's verification
# call site, using the same public CLI and real signed portable package.
mkdir -p "$work/parent" "$work/parent-tooling/scripts" \
  "$work/parent-tooling/dependencies/robotics-runtime/.venv/bin" "$work/parent-tools"
cp -a "$work/relocated" "$work/parent/qualification"
cp "$work/formatted.json" "$work/parent/qualification/qualification-statement.json"
cp "$work/qualification.sigstore.json" "$work/qualification.pub" "$work/parent/qualification/"
ln -s "$root/scripts/qualification" "$work/parent-tooling/scripts/qualification"
ln -s "$(realpath -e "$ROBOTICS_CONTRACTS_CLI")" "$work/parent-tooling/dependencies/robotics-runtime/.venv/bin/robotics-contracts"
ln -s "$(command -v cosign)" "$work/parent-tools/cosign"
ln -s "$(command -v jq)" "$work/parent-tools/jq"
awk '
  /^  source_package=/ {capture=1}
  /^  source_schema_arguments=/ {if(capture) exit}
  capture {print}
' "$root/scripts/ci/foundation/run-acceptance-isolation.sh" >"$work/parent-verify.sh"
[[ -s "$work/parent-verify.sh" ]]
(
  contracts_cli="$ROBOTICS_CONTRACTS_CLI"
  export PATH="$work/parent-tools:/usr/bin:/bin"
  (
    export ROBOTICS_CONTRACTS_CLI="$contracts_cli"
    cd "$work/parent/qualification"
    mapfile -t child_inputs <qualification-arguments.txt
    "$root/scripts/qualification/verify-bundle" "${child_inputs[@]}" \
      --bundle qualification.sigstore.json --key qualification.pub
  )
  unset ROBOTICS_CONTRACTS_CLI
  if command -v robotics-contracts >/dev/null 2>&1; then
    printf 'parent fixture unexpectedly exposes an ambient contracts CLI\n' >&2
    exit 1
  fi
  root="$work/parent-tooling"
  artifact_a="$work/parent"
  # Removing only the new binding recreates the original real refusal.
  sed '/^    ROBOTICS_CONTRACTS_CLI=/d' "$work/parent-verify.sh" >"$work/parent-unbound.sh"
  original_status=0
  bash -Eeuo pipefail -c 'root=$1; artifact_a=$2; source "$3"' \
    parent "$root" "$artifact_a" "$work/parent-unbound.sh" >"$work/rejection.log" 2>&1 || original_status=$?
  [[ "$original_status" == 65 ]]
  grep -F 'robotics-contracts CLI is unavailable' "$work/rejection.log"
  # The current production block verifies custody, then binds raw payload bytes.
  # shellcheck source=/dev/null
  source "$work/parent-verify.sh"
  # shellcheck disable=SC2154
  [[ "$source_statement_sha" == "$(sha256sum "$work/formatted.json" | cut -d' ' -f1)" ]]
)
printf 'actual parent binding and authenticated portable source checks passed\n'

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
