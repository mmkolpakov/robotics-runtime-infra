#!/usr/bin/env bash
set -Eeuo pipefail

# Run a supply-chain build or scan command with live output and classify
# upstream snapshot-mirror 5xx failures as EX_TEMPFAIL (75) for diagnostics.
# A failing command always fails this wrapper; 75 is a failure classification,
# never a success. The gate stays fail-closed while the mirror is unavailable.

test "$#" -ge 1 || {
  printf 'usage: run-guarded.sh COMMAND [ARG...]\n' >&2
  exit 64
}

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT HUP INT TERM

set +e
"$@" 2>&1 | tee "${log}"
status="${PIPESTATUS[0]}"
set -e

if test "${status}" -eq 0; then
  exit 0
fi

# apt prints the mirror URL and the 5xx status on the same line or on adjacent
# lines (Err: block). Require both within two lines so an unrelated 5xx in a
# long build log is not mislabelled as an upstream outage.
if awk '
  /snapshot\.ubuntu\.com|snapshots\.ros\.org/ { mirror = NR }
  /(^|[^0-9])50[0-9]([^0-9]|$)|Service Unavailable|Bad Gateway|Internal Server Error/ {
    if (mirror > 0 && NR - mirror <= 2) { found = 1 }
  }
  END { exit found ? 0 : 1 }
' "${log}"; then
  printf 'upstream unavailable: the Ubuntu/ROS snapshot mirror returned 5xx; failing closed with EX_TEMPFAIL (75)\n' >&2
  if test -n "${GITHUB_STEP_SUMMARY:-}"; then
    {
      printf '### Supply chain: upstream unavailable\n\n'
      printf 'The snapshot mirror returned 5xx during this step. The gate fails closed with exit code 75 (EX_TEMPFAIL); rerun once the mirror recovers.\n'
    } >>"${GITHUB_STEP_SUMMARY}"
  fi
  exit 75
fi

exit "${status}"
