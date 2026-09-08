#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  FIXTURES="${ROOT}/test/ci/physical-attach"
  cp "${FIXTURES}/time-evidence.jsonl" "${BATS_TEST_TMPDIR}/evidence.json"
}

verify() {
  local hash
  hash="$(sha256sum "${BATS_TEST_TMPDIR}/evidence.json" | awk '{print $1}')"
  jq -b --arg hash "${hash}" \
    --arg start "${WINDOW_START:-1784999999000000000}" \
    --arg end "${WINDOW_END:-1785000001000000000}" \
    '.evidence_sha256 = $hash | .started_at_unix_nano = $start |
     .finished_at_unix_nano = $end' "${FIXTURES}/time-evidence-window.json" \
    >"${BATS_TEST_TMPDIR}/window.json"
  jq -s -e --arg evidence_sha256 "${hash}" \
    --arg run_id test-run --arg source_revision local \
    --arg workflow_run_id local --arg workflow_run_attempt 1 \
    --argjson future_tolerance_ns 0 --argjson max_age_ns 300000000000 \
    --argjson max_window_ns 900000000000 \
    --argjson now_ns "${NOW_NS:-1785000002000000000}" \
    --slurpfile window "${BATS_TEST_TMPDIR}/window.json" \
    -f "${FIXTURES}/verify-time-evidence.jq" "${BATS_TEST_TMPDIR}/evidence.json"
}

mutate() {
  jq -b "$1" "${FIXTURES}/time-evidence.jsonl" >"${BATS_TEST_TMPDIR}/evidence.json"
}

@test "source timestamp and reported age agree for a fresh sample" {
  run verify
  [ "${status}" -eq 0 ]
}

@test "old records cannot be refreshed with new collector timestamps, hash and window" {
  mutate 'walk(if type == "object" and has("timeUnixNano")
    then .timeUnixNano = "1785000060000000000" else . end)'
  export WINDOW_START=1785000059000000000 WINDOW_END=1785000061000000000
  export NOW_NS=1785000062000000000
  run verify
  [ "${status}" -eq 1 ]
}

@test "old source timestamp is rejected even if the reported age says fresh" {
  mutate 'walk(if type == "object" and .key? == "robotics.clock.sample_unix_ms"
    then .value.doubleValue -= 60000 else . end)'
  run verify
  [ "${status}" -eq 1 ]
}

@test "future source and negative message age are rejected" {
  mutate 'walk(if type == "object" and .key? == "robotics.clock.sample_unix_ms"
    then .value.doubleValue += 100 else . end)'
  run verify
  [ "${status}" -eq 1 ]
  mutate '.resourceMetrics[0].scopeMetrics[0].metrics[2].gauge.dataPoints[0].asDouble = -1'
  run verify
  [ "${status}" -eq 1 ]
}

@test "missing or malformed source timestamp is rejected" {
  mutate 'walk(if type == "object" and .key? == "robotics.clock.sample_unix_ms"
    then .key = "unknown" else . end)'
  run verify
  [ "${status}" -eq 1 ]
  mutate 'walk(if type == "object" and .key? == "robotics.clock.sample_unix_ms"
    then .value = {stringValue: "1784999999990"} else . end)'
  run verify
  [ "${status}" -ne 0 ]
}

@test "inconsistent source timestamps across the four metrics are rejected" {
  mutate '.resourceMetrics[0].scopeMetrics[0].metrics[0].gauge.dataPoints[0].attributes =
    [{key: "robotics.clock.sample_unix_ms", value: {doubleValue: 1784999999995}}]'
  run verify
  [ "${status}" -eq 1 ]
}

@test "message age cannot disagree with its source timestamp" {
  mutate '.resourceMetrics[0].scopeMetrics[0].metrics[2].gauge.dataPoints[0].asDouble = 0'
  run verify
  [ "${status}" -eq 1 ]
}

@test "host time integration waits for Collector readiness before sampling" {
  run bash -ceu '
    export RUNNER_TEMP="$2"
    source "$1/scripts/ci/integration/host-time/lib.sh"
    printf 0 >"$2/calls"
    sleep() { :; }
    compose() {
      test "$*" = "logs --no-color time-evidence-chrony" || return 2
      count=$(cat "${RUNNER_TEMP}/calls")
      count=$((count + 1))
      printf %s "${count}" >"${RUNNER_TEMP}/calls"
      if test "${count}" -eq 2; then
        printf "Everything is ready. Begin running and processing data.\n"
      else
        printf "Starting receivers\n"
      fi
    }
    host_time_wait_for_collector time-evidence-chrony compose
    test "$(cat "$2/calls")" = 2
  ' _ "${ROOT}" "${BATS_TEST_TMPDIR}"
  [ "${status}" -eq 0 ]
}

@test "host time integration rejects partial or empty exporter output" {
  run bash -ceu '
    export RUNNER_TEMP="$2"
    source "$1/scripts/ci/integration/host-time/lib.sh"
    printf "{\n" >"$2/partial.json"
    printf "{}\n" >"$2/empty.json"
    ! host_time_has_samples "$2/partial.json"
    ! host_time_has_samples "$2/empty.json"
    host_time_has_samples "$1/test/ci/physical-attach/time-evidence.jsonl"
  ' _ "${ROOT}" "${BATS_TEST_TMPDIR}"
  [ "${status}" -eq 0 ]
}
