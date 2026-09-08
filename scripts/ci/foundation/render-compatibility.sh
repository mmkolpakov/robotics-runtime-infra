#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
output="${1:-${root}/docs/foundation-compatibility.md}"
mode="${2:-write}"
case "${output}" in
  docs/foundation-compatibility.md | "${root}/docs/foundation-compatibility.md") ;;
  *) printf 'foundation compatibility is generated at its canonical path\n' >&2; exit 64 ;;
esac
case "${mode}" in
  --check) python3 "${root}/scripts/ci/foundation/sync-workspace-pins.py" --check ;;
  write) python3 "${root}/scripts/ci/foundation/sync-workspace-pins.py" ;;
  *) printf 'usage: %s [OUTPUT] [write|--check]\n' "$0" >&2; exit 64 ;;
esac
