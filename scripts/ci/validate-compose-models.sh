#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo

manifest="${1:-config/ci/pipeline.json}"

jq -e '
  .compose_models | type == "array" and length > 0 and
  all(.[];
    (.name | type == "string" and length > 0) and
    (.files | type == "array" and length > 0) and
    all(.files[]; type == "string" and endswith(".yaml"))
  ) and
  ([.[].name] | length == (unique | length))
' "${manifest}" >/dev/null

ci_set_compose_fixture_env

while IFS= read -r model; do
  name="$(jq -r '.name' <<<"${model}")"
  mapfile -t files < <(jq -r '.files[]' <<<"${model}")
  compose_files=()
  for file in "${files[@]}"; do
    test -f "${file}"
    compose_files+=(-f "${file}")
  done
  printf 'Validating Compose model: %s\n' "${name}"
  docker compose "${compose_files[@]}" --profile '*' config --quiet
done < <(jq -c '.compose_models[]' "${manifest}")
