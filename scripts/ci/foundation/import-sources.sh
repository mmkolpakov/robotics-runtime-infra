#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"

mode="${1:---check}"
case "${mode}" in
  --check | --refresh-pins) ;;
  *) printf 'usage: %s [--check|--refresh-pins]\n' "$0" >&2; exit 64 ;;
esac
mkdir -p artifacts dependencies
workspace=dependencies/robotics-runtime
if [[ -e "${workspace}/.git" ]]; then
  git -C "${workspace}" diff --quiet HEAD -- || {
    printf 'imported workspace has local changes; preserve them before importing\n' >&2
    exit 65
  }
fi
uvx --from vcs2l==1.1.7 vcs validate --input foundation.repos
if [[ ! -e "${workspace}/.git" ]]; then
  uvx --from vcs2l==1.1.7 vcs import --input foundation.repos dependencies
fi
revision="$(python3 scripts/ci/foundation/sync-workspace-pins.py --revision)"
# vcs export --exact identifies the remote through its tracking refs. Fetching
# only a SHA updates FETCH_HEAD, leaving those refs stale on an existing clone.
git -C "${workspace}" fetch --no-tags origin
if [[ "$(git -C "${workspace}" rev-parse HEAD)" != "${revision}" ]]; then
  git -C "${workspace}" fetch --no-tags origin "${revision}"
  git -C "${workspace}" switch --detach "${revision}"
fi
uvx --from vcs2l==1.1.7 vcs export --exact --lint "${workspace}" \
  > artifacts/foundation.resolved.repos

if [[ "${mode}" == --refresh-pins ]]; then
  python3 scripts/ci/foundation/sync-workspace-pins.py
else
  python3 scripts/ci/foundation/sync-workspace-pins.py --check
fi
