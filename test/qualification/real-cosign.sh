#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${root}"

if [[ "${1:-}" == --offline-consumer ]]; then
  [[ $# == 2 && -n "$2" ]] || exit 64
  image="$2"
  : "${ROBOTICS_CONTRACTS_CLI:?ROBOTICS_CONTRACTS_CLI is required}"
  command -v docker >/dev/null
  command -v cosign >/dev/null
  work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/qualification-offline.XXXXXXXX")"
  trap 'rm -rf -- "$work"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir "$work/inputs" "$work/key" "$work/tools" "$work/wheels"
  cp -a "$root/dependencies/robotics-runtime/packages/contracts/tests/fixtures/qualification/inference/." "$work/inputs/"
  fixture="$work/inputs"
  # This is an opaque signed subject; it exercises integer preservation without
  # changing or relabelling any document in the existing receipt chain.
  printf '{"timestamp_ns":9007199254740993}\n' >"$fixture/large-clock.json"
  arguments=()
  while IFS=$'\t' read -r kind subject file; do
    arguments+=(--artifact "$kind:$subject=$fixture/$file")
  done < <(jq -r '.[] | [.kind, .subject_name, .file] | @tsv' "$fixture/artifacts.json")
  arguments+=(--artifact "other_evidence:evidence/large-clock.json=$fixture/large-clock.json")
  scripts/qualification/create-statement "${arguments[@]}" --output "$work/statement.json"
  bash scripts/ci/foundation/sign-ephemeral-qualification.sh \
    "$work/statement.json" "$work/signature.json" "$work/key/expected.pub"
  (
    cd "$work"
    "$root/scripts/qualification/package-artifacts" "${arguments[@]}" --output "$work/portable"
  )
  cp "$work/signature.json" "$work/portable/qualification.sigstore.json"
  cp "$work/statement.json" "$work/portable/qualification-statement.json"
  (
    cd "$work/portable"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  ) >"$work/original.sha256"
  python3 - "$work/wheels" <<'PY'
import hashlib, json, pathlib, urllib.request
import sys
metadata = json.load(urllib.request.urlopen('https://pypi.org/pypi/robotics-runtime-contracts/0.21.1/json', timeout=30))
files = [item for item in metadata['urls'] if item['filename'] == 'robotics_runtime_contracts-0.21.1-py3-none-any.whl']
expected = '34a476046ce3326384780224b4e40cad72f41ce756f627d63a6503e01349e015'
assert len(files) == 1 and files[0]['digests']['sha256'] == expected
raw = urllib.request.urlopen(files[0]['url'], timeout=30).read()
assert hashlib.sha256(raw).hexdigest() == expected
(pathlib.Path(sys.argv[1]) / files[0]['filename']).write_bytes(raw)
PY
  # The image supplies the locked dependency cohort; install the exact PyPI
  # wheel in a separate venv without fetching or rebuilding dependencies.
  docker run --rm --network none --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$work/tools,target=/tools" \
    --mount "type=bind,source=$work/wheels,target=/wheels,readonly" \
    --entrypoint /bin/bash "$image" -Eeuo pipefail -c '
      cp -a /opt/contracts /tools/venv
      uv pip install --python /tools/venv/bin/python --reinstall --no-deps --no-index /wheels/robotics_runtime_contracts-0.21.1-py3-none-any.whl
      uv pip check --python /tools/venv/bin/python
      test "$(head -n 1 /tools/venv/bin/robotics-contracts)" = "#!/tools/venv/bin/python"
      /tools/venv/bin/robotics-contracts --help >/dev/null
      /tools/venv/bin/python -I -c "import pathlib,sys; import robotics_runtime_contracts as c; from importlib.metadata import version; assert version(\"robotics-runtime-contracts\")==\"0.21.1\"; assert pathlib.Path(c.__file__).resolve().is_relative_to(pathlib.Path(sys.prefix).resolve())"
    '
  verify_offline() {
    local package="$1" target="$2" key="$3"
    docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
      --tmpfs /tmp:rw,nosuid,nodev --tmpfs /opt/contracts:ro --env HOME=/tmp \
      --env ROBOTICS_CONTRACTS_CLI=/tools/venv/bin/robotics-contracts \
      --mount "type=bind,source=$work/tools,target=/tools,readonly" \
      --mount "type=bind,source=$package,target=$target,readonly" \
      --mount "type=bind,source=$key,target=/trust/expected.pub,readonly" \
      --workdir "$target" --entrypoint /bin/bash "$image" -Eeuo pipefail -c '
        test "$(head -n 1 /tools/venv/bin/robotics-contracts)" = "#!/tools/venv/bin/python"
        /tools/venv/bin/python -I -c "import pathlib,sys; import robotics_runtime_contracts as c; assert pathlib.Path(c.__file__).resolve().is_relative_to(pathlib.Path(sys.prefix).resolve())"
        /tools/venv/bin/robotics-contracts --help >/dev/null
        mapfile -t inputs < qualification-arguments.txt
        /opt/robotics/finalizer/scripts/qualification/verify-bundle "${inputs[@]}" \
          --bundle qualification.sigstore.json --key /trust/expected.pub
      '
  }
  cp -a "$work/portable" "$work/first"
  rm -rf -- "$work/portable" "$work/inputs"
  (cd "$work/first" && sha256sum --check "$work/original.sha256")
  verify_offline "$work/first" /archive-one "$work/key/expected.pub"
  cp -a "$work/first" "$work/second"
  rm -rf -- "$work/first"
  (cd "$work/second" && sha256sum --check "$work/original.sha256")
  verify_offline "$work/second" /elsewhere/retained "$work/key/expected.pub"
  cp -a "$work/second" "$work/rejected"
  printf '\n' >>"$work/rejected/subjects/evidence/large-clock.json"
  if verify_offline "$work/rejected" /rejected "$work/key/expected.pub" >"$work/rejection.log" 2>&1; then
    printf 'offline verifier accepted altered signed bytes\n' >&2
    exit 1
  fi
  rm -- "$work/rejected/subjects/evidence/large-clock.json"
  if verify_offline "$work/rejected" /rejected "$work/key/expected.pub" >"$work/rejection.log" 2>&1; then
    printf 'offline verifier accepted a missing subject\n' >&2
    exit 1
  fi
  ln -s /etc/passwd "$work/rejected/subjects/evidence/large-clock.json"
  if verify_offline "$work/rejected" /rejected "$work/key/expected.pub" >"$work/rejection.log" 2>&1; then
    printf 'offline verifier accepted a subject symlink\n' >&2
    exit 1
  fi
  bash scripts/ci/foundation/sign-ephemeral-qualification.sh \
    "$work/statement.json" "$work/foreign-signature.json" "$work/key/foreign.pub"
  if verify_offline "$work/second" /elsewhere/retained "$work/key/foreign.pub" >"$work/rejection.log" 2>&1; then
    printf 'offline verifier accepted a foreign key\n' >&2
    exit 1
  fi
  # Build an original/assessment pair with the foundation's existing test
  # factory. Only the resulting immutable files enter the consumer container.
  mkdir "$work/v2-source"
  PYTHONPATH="$root/dependencies/robotics-runtime/packages/harness" \
    "$(dirname "$ROBOTICS_CONTRACTS_CLI")/python" - "$work/v2-source" "$work/v2-specs.json" <<'PY'
import json, pathlib, sys
from tests.test_archive_qualification import _archive_pair
root = pathlib.Path(sys.argv[1])
specifications = _archive_pair(root)
pathlib.Path(sys.argv[2]).write_text(json.dumps(specifications))
PY
  jq -e '.schema_version == "acceptance-scenario.v2"' "$work/v2-source/scenario.json" >/dev/null
  jq -e '.schema_version == "runtime-manifest.v2"' "$work/v2-source/runtime-primary.json" >/dev/null
  jq -se 'all(.[]; .schema_version == "acceptance-result.v2")' \
    "$work/v2-source/result-primary.json" "$work/v2-source/new-result-primary.json" >/dev/null
  mapfile -t v2_specs < <(jq -r '.[]' "$work/v2-specs.json")
  v2_arguments=()
  for specification in "${v2_specs[@]}"; do v2_arguments+=(--artifact "$specification"); done
  printf '{"timestamp_ns":9007199254740993}\n' >"$work/v2-source/large-clock.json"
  v2_arguments+=(--artifact "other_evidence:evidence/large-clock.json=$work/v2-source/large-clock.json")
  v2_profile=(--schema-version qualification-bundle.v2 --comparison-rule exact_assertion_outcome)
  "$root/scripts/qualification/create-statement" "${v2_profile[@]}" "${v2_arguments[@]}" \
    --output "$work/v2-statement.json"
  jq -e '
    .predicate.schema_version == "qualification-bundle.v2" and
    .predicate.original_execution.acceptance_aggregate == "original-aggregate.json" and
    .predicate.acceptance_aggregate == "acceptance-aggregate.json" and
    .predicate.comparison.rule == "exact_assertion_outcome" and
    .predicate.comparison.per_domain[0].status == "not_comparable"
  ' "$work/v2-statement.json" >/dev/null
  bash "$root/scripts/ci/foundation/sign-ephemeral-qualification.sh" \
    "$work/v2-statement.json" "$work/v2-signature.json" "$work/key/v2.pub"
  (
    cd "$work"
    "$root/scripts/qualification/package-artifacts" "${v2_profile[@]}" "${v2_arguments[@]}" \
      --output "$work/v2-portable"
  )
  cp "$work/v2-signature.json" "$work/v2-portable/qualification.sigstore.json"
  cp "$work/v2-statement.json" "$work/v2-portable/qualification-statement.json"
  (cd "$work/v2-portable" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) \
    >"$work/v2-original.sha256"
  cp -a "$work/v2-portable" "$work/v2-first"
  rm -rf -- "$work/v2-portable" "$work/v2-source"
  (cd "$work/v2-first" && sha256sum --check "$work/v2-original.sha256")
  verify_offline "$work/v2-first" /archive-one "$work/key/v2.pub"
  cp -a "$work/v2-first" "$work/v2-second"
  rm -rf -- "$work/v2-first"
  (cd "$work/v2-second" && sha256sum --check "$work/v2-original.sha256")
  verify_offline "$work/v2-second" /elsewhere/retained "$work/key/v2.pub"
  cp -a "$work/v2-second" "$work/v2-swapped"
  python3 - "$work/v2-swapped/qualification-arguments.txt" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
original = "acceptance_aggregate:original-aggregate.json=subjects/original-aggregate.json"
assessment = "acceptance_aggregate:acceptance-aggregate.json=subjects/acceptance-aggregate.json"
assert lines.count(original) == lines.count(assessment) == 1
lines[lines.index(original)] = original.replace("=subjects/original-aggregate.json", "=subjects/acceptance-aggregate.json")
lines[lines.index(assessment)] = assessment.replace("=subjects/acceptance-aggregate.json", "=subjects/original-aggregate.json")
path.write_text("\n".join(lines) + "\n")
PY
  (cd "$work/v2-swapped" && sed '/  \.\/qualification-arguments\.txt$/d' "$work/v2-original.sha256" | sha256sum --check)
  swap_status=0
  verify_offline "$work/v2-swapped" /rejected "$work/key/v2.pub" >"$work/swap-rejection.log" 2>&1 || swap_status=$?
  [[ "$swap_status" == 65 ]] && grep -Fq 'qualification.statement_mismatch' "$work/swap-rejection.log" || {
    printf 'offline v2 verifier did not reject swapped aggregate bindings as a statement mismatch\n' >&2
    cat "$work/swap-rejection.log" >&2
    exit 1
  }
  (cd "$work/v2-second" && sha256sum --check "$work/v2-original.sha256")
  (cd "$work/v2-swapped" && sed '/  \.\/qualification-arguments\.txt$/d' "$work/v2-original.sha256" | sha256sum --check)
  cp -a "$work/v2-second" "$work/v2-rejected"
  printf '\n' >>"$work/v2-rejected/subjects/original-results/primary.json"
  if verify_offline "$work/v2-rejected" /rejected "$work/key/v2.pub" >"$work/rejection.log" 2>&1; then
    printf 'offline v2 verifier accepted altered original-result bytes\n' >&2
    exit 1
  fi
  printf 'published contracts offline v2 archive relocation checks passed\n'

  printf 'published contracts offline relocation checks passed\n'
  exit 0
fi
[[ $# == 0 ]] || exit 64

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
