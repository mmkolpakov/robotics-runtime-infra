#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

bake=(docker buildx bake --file docker-bake.hcl)

mapfile -t bake_targets < <(
  "${bake[@]}" --list=type=targets,format=json |
    jq -er '.[] | select(.group != true) | .name'
)
((${#bake_targets[@]} > 0))

bake_plan="$("${bake[@]}" --print "${bake_targets[@]}")"
release_plan="$("${bake[@]}" --print release)"
cpu_plan="$("${bake[@]}" --print cpu)"
ci_only_plan="$("${bake[@]}" --print ci-only)"
jq -e '
  (.target | has("permit-preflight")) and
  (.target | has("permit-preflight-ci") | not)
' <<<"${release_plan}" >/dev/null
jq -e '
  (.target | has("permit-preflight")) and
  (.target | has("permit-preflight-ci") | not)
' <<<"${cpu_plan}" >/dev/null
jq -e '
  (.target | keys) == ["permit-preflight-ci"]
' <<<"${ci_only_plan}" >/dev/null
selected_targets="$(
  printf '%s\n' "${bake_targets[@]}" |
    jq -Rsc 'split("\n") | map(select(length > 0))'
)"
mapfile -t checkable_targets < <(
  jq -er --argjson selected "${selected_targets}" '
    .target
    | to_entries[]
    | select(.key as $name | $selected | index($name))
    | select(
        [
          (.value.contexts // {} | to_entries[].value)
          | select(type == "string" and startswith("target:"))
        ]
        | length == 0
      )
    | .key
  ' <<<"${bake_plan}"
)
((${#checkable_targets[@]} > 0))
for target in "${checkable_targets[@]}"; do
  "${bake[@]}" --check "${target}"
done
