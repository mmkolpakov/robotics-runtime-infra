#!/usr/bin/env bash
# Compares each apt package pinned in infra/stack/simulation-stack.json
# against the version apt would install today, run inside the same base
# image the simulation Dockerfile builds from (the `docker-update-check`
# Makefile target runs this in a throwaway `osrf/ros:jazzy-simulation`
# container).
#
# Usage: check_packages.sh <package-refs.tsv>
# Each row of the TSV is: key<TAB>package<TAB>expected_version, as produced
# by the docker-update-check Makefile target from
# infra/stack/simulation-stack.json.
set -euo pipefail

package_refs="${1:?usage: check_packages.sh <package-refs.tsv>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apt-get update >/dev/null

status=0
while IFS=$'\t' read -r key package expected; do
  apt-cache policy "${package}" > /tmp/policy.txt
  candidate="$(python3 "${script_dir}/check_apt_versions.py" --policy-file /tmp/policy.txt)" || candidate=""
  if [[ -z "${candidate}" || "${candidate}" == "(none)" ]]; then
    echo "missing ${package}"
    status=1
  elif [[ "${candidate}" != "${expected}" ]]; then
    echo "changed ${key}: ${package} expected ${expected}, current ${candidate}"
    status=1
  else
    echo "${key}: ${package} ${candidate}"
  fi
done < "${package_refs}"

exit "${status}"
