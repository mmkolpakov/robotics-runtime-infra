#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
output="${1:-${root}/docs/foundation-compatibility.md}"
mode="${2:-write}"

render() {
  local name path revision url version

  printf '%s\n\n' '# Foundation Compatibility Lock'
  # Literal Markdown backticks are not shell substitutions.
  # shellcheck disable=SC2016
  printf '%s\n\n' \
    'Generated from the repositories imported through `foundation.repos`.'
  printf '%s\n' '| Component | Version | Commit | Source |'
  printf '%s\n' '| --- | --- | --- | --- |'
  for name in robotics-runtime-contracts robotics-acceptance-harness; do
    path="${root}/dependencies/${name}"
    test -d "${path}/.git"
    revision="$(git -C "${path}" rev-parse HEAD)"
    url="$(git -C "${path}" remote get-url origin)"
    version="$(uv --project "${path}" version --short)"
    # Literal Markdown backticks are not shell substitutions.
    # shellcheck disable=SC2016
    printf '| `%s` | `%s` | `%s` | <%s> |\n' \
      "${name}" "${version}" "${revision}" "${url}"
  done
  printf '\n%s\n' \
    'CI imports these exact commits and verifies the versions embedded in runtime images.'
}

if [[ "${mode}" == --check ]]; then
  temporary="$(mktemp)"
  trap 'rm -f "${temporary}"' EXIT HUP INT TERM
  render >"${temporary}"
  diff --unified "${output}" "${temporary}"
elif [[ "${mode}" == write ]]; then
  render >"${output}"
else
  printf 'usage: %s [OUTPUT] [write|--check]\n' "$0" >&2
  exit 64
fi
