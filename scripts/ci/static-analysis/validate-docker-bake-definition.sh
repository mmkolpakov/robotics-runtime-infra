#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo
ci_set_compose_fixture_env

manifest="${1:-config/ci/pipeline.json}"
test -f "${manifest}"

bake_target_lines="$(
  jq -er '
    .bake_targets as $targets |
    if ($targets | type) != "array" then
      error("bake_targets must be an array")
    elif ($targets | length) == 0 then
      error("bake_targets must not be empty")
    elif (all($targets[]; type == "string" and length > 0) | not) then
      error("bake_targets must contain non-empty strings")
    elif ($targets | length) != ($targets | unique | length) then
      error("bake_targets must not contain duplicates")
    else
      $targets[]
    end
  ' "${manifest}"
)"
mapfile -t bake_targets <<<"${bake_target_lines}"
test "${#bake_targets[@]}" -gt 0

for target in "${bake_targets[@]}"; do
  printf 'Validating Bake target: %s\n' "${target}"
done

target_catalog="$(
  docker buildx bake --list=type=targets,format=json
)"
jq -e '
  type == "array" and length > 0 and
  all(.[]; .name | type == "string" and length > 0) and
  ([.[].name] | length == (unique | length))
' <<<"${target_catalog}" >/dev/null

group_lines="$(jq -r '.[] | select(.group == true) | .name' <<<"${target_catalog}")"
test -n "${group_lines}"
while IFS= read -r group; do
  if ! jq -e --arg group "${group}" \
    '.bake_targets | index($group) != null' "${manifest}" >/dev/null; then
    printf 'Bake group is absent from declarative coverage: %s\n' \
      "${group}" >&2
    exit 1
  fi
done <<<"${group_lines}"

rendered_bake="$(docker buildx bake --print "${bake_targets[@]}")"
catalog_target_lines="$(
  jq -r '.[] | select(.group != true) | .name' <<<"${target_catalog}"
)"
test -n "${catalog_target_lines}"
while IFS= read -r target; do
  if ! jq -e --arg target "${target}" \
    '.target | has($target)' <<<"${rendered_bake}" >/dev/null; then
    printf 'Bake target is absent from rendered coverage: %s\n' \
      "${target}" >&2
    exit 1
  fi
done <<<"${catalog_target_lines}"
