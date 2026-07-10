#!/usr/bin/env bash
# Run one or more `make` smoke/test targets under a throwaway RUN_ID, and
# guarantee `runs/<run_id>/` is removed afterwards -- on success, failure,
# or Ctrl+C. Frees a developer from having to pick a RUN_ID, remember to
# clean it up, or worry about leaking a `runs/.locks` entry if they cancel
# a run midway.
#
# Usage: ./run_local_test.sh <make-target> [more make-targets...]
# Example: ./run_local_test.sh compose-smoke integration-smoke
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <make-target> [more make-targets...]" >&2
  exit 2
fi

run_id="dev-$(whoami)-$(date +%s)"

cleanup() {
  rm -rf "runs/${run_id}"
  make clean-locks
}
trap cleanup EXIT

echo "run_local_test: RUN_ID=${run_id}"
make RUN_ID="${run_id}" "$@"
