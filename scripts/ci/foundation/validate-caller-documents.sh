#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

[[ $# -eq 1 ]] || {
  printf 'usage: validate-caller-documents.sh CONSUMER_ROOT\n' >&2
  exit 64
}
: "${DOCUMENTS:?DOCUMENTS must contain newline-delimited SCHEMA=PATH entries}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
contracts_cli="${ROBOTICS_CONTRACTS_CLI:-${root}/dependencies/robotics-runtime/.venv/bin/robotics-contracts}"
consumer_root="$(realpath -e "$1")"
[[ -d "${consumer_root}" ]] || exit 66
validated=0
while IFS= read -r entry; do
  entry="${entry%$'\r'}"
  [[ -n "${entry}" ]] || continue
  schema="${entry%%=*}"
  document="${entry#*=}"
  [[ "${entry}" == *=* && "${schema}" =~ ^[a-z][a-z0-9-]*\.v[1-9][0-9]*$ &&
    -n "${document}" && "${document}" != /* ]] || {
    printf 'expected SCHEMA=PATH with a versioned role and a relative document path: %s\n' "${entry}" >&2
    exit 64
  }
  candidate="$(realpath -e "${consumer_root}/${document}")"
  case "${candidate}" in
    "${consumer_root}"/*) ;;
    *)
      printf 'document escapes caller repository: %s\n' "${document}" >&2
      exit 64
      ;;
  esac
  [[ -f "${candidate}" ]] || {
    printf 'document is not a regular file: %s\n' "${document}" >&2
    exit 66
  }
  "${contracts_cli}" validate --schema "${schema}" "${candidate}"
  validated=$((validated + 1))
done <<<"${DOCUMENTS}"
[[ "${validated}" -gt 0 ]] || {
  printf 'no caller documents were specified\n' >&2
  exit 64
}
