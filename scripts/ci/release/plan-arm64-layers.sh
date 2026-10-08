#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

# Plan a native ARM64 build of every multi-platform release target. Each target
# exports its layers to its own cache scope, which the candidate job imports.
# The build arguments must match the candidate build; a mismatch only costs
# emulated build time there.
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
[[ "${GITHUB_REF_NAME}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]

targets="$(
  docker buildx bake --file docker-bake.hcl --print release |
    jq -er '
      [.target | to_entries[] |
        select(.value.platforms // [] | index("linux/arm64")) | .key] |
      if length > 0 then .[] else error("no ARM64 release target") end
    '
)"

settings=()
while IFS= read -r target; do
  [[ "${target}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
  settings+=(
    "${target}.platform=linux/arm64"
    "${target}.output=type=cacheonly"
    "${target}.cache-to=type=gha,mode=max,scope=release-${target}-arm64"
  )
done <<<"${targets}"

{
  printf 'version=%s\n' "${GITHUB_REF_NAME#v}"
  printf 'targets<<ARM64_PLAN_END\n%s\nARM64_PLAN_END\n' "${targets}"
  printf 'set<<ARM64_PLAN_END\n'
  printf '%s\n' "${settings[@]}"
  printf 'ARM64_PLAN_END\n'
} >>"${GITHUB_OUTPUT}"
