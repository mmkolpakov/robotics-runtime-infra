#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
}

# Print observed_rate_hz for completion times given in nanoseconds.
observed_rate() {
  PYTHONPATH=probes python3 -c '
import sys

from robotics_inference_conformance import observed_rate_hz

print(observed_rate_hz([int(value) for value in sys.argv[1:]]))
' "$@"
}

@test "sensor inference rate spans completed inferences only" {
  local -a completed=()
  local frame

  # Thirty inferences at 15 Hz, starting 20 s after the probe was created.
  for frame in $(seq 0 29); do
    completed+=("$((20000000000 + frame * 1000000000 / 15))")
  done

  run observed_rate "${completed[@]}"
  [ "${status}" -eq 0 ]
  python3 -c 'import sys; assert abs(float(sys.argv[1]) - 15.0) < 1e-6' "${output}"
}

@test "sensor inference rate is undefined without an inference interval" {
  run observed_rate
  [ "${status}" -eq 0 ]
  [ "${output}" = None ]

  run observed_rate 5000000000
  [ "${status}" -eq 0 ]
  [ "${output}" = None ]

  run observed_rate 5000000000 5000000000
  [ "${status}" -eq 0 ]
  [ "${output}" = None ]
}
