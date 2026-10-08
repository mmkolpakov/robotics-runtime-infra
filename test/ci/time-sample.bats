#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SAMPLER="${ROOT}/scripts/time/sample.sh"
  mkdir -p "${BATS_TEST_TMPDIR}/samples" "${BATS_TEST_TMPDIR}/bin"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export SAMPLE_FIXTURE="${BATS_TEST_TMPDIR}/tracking.csv"
  export SAMPLE_ARGS="${BATS_TEST_TMPDIR}/sample-args"
  printf '%s\n' 'CB00710F,203.0.113.15,3,1785000000.125,0.0005,0.0001,0.0002,2.0,0.0,0.1,0.01,0.001,1.0,Normal' >"${SAMPLE_FIXTURE}"
  cat >"${BATS_TEST_TMPDIR}/bin/chronyc" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"${SAMPLE_ARGS}"
cat "${SAMPLE_FIXTURE}"
EOF
  cat >"${BATS_TEST_TMPDIR}/bin/pmc" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"${SAMPLE_ARGS}"
cat "${SAMPLE_FIXTURE}"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/"*
}

@test "Chrony age source is the reference timestamp, not the time of re-reading tracking" {
  run bash "${SAMPLER}" chrony "${BATS_TEST_TMPDIR}/samples"
  [ "${status}" -eq 0 ]
  jq -e '.source_unix_ms == 1785000000125 and .offset_ms == 0.5 and
    .drift_ppm == 2 and .monotonic == 1 and
    .observed_unix_ms > .source_unix_ms' "${BATS_TEST_TMPDIR}/samples/chrony.log"
  grep -Fx -- tracking "${SAMPLE_ARGS}"
  grep -Fx -- /run/robotics-time/chronyd.sock "${SAMPLE_ARGS}"
  run bash "${SAMPLER}" chrony "${BATS_TEST_TMPDIR}/samples"
  [ "${status}" -eq 0 ]
  jq -e '.source_unix_ms == 1785000000125' "${BATS_TEST_TMPDIR}/samples/chrony.log"
}

@test "PTP ingress time is converted with the reported UTC offset and both GETs are used" {
  export SAMPLE_FIXTURE="${ROOT}/test/time/pmc.fixture"
  run bash "${SAMPLER}" ptp "${BATS_TEST_TMPDIR}/samples"
  [ "${status}" -eq 0 ]
  jq -e '.source_unix_ms == 1784023163000 and .offset_ms == 0.25 and
    .drift_ppm == 1.5 and .monotonic == 1' "${BATS_TEST_TMPDIR}/samples/pmc.log"
  grep -Fx -- 'GET TIME_STATUS_NP' "${SAMPLE_ARGS}"
  grep -Fx -- 'GET TIME_PROPERTIES_DATA_SET' "${SAMPLE_ARGS}"
  grep -Fx -- /run/robotics-time/ptp4lro "${SAMPLE_ARGS}"
  grep -Fx -- -i "${SAMPLE_ARGS}"
  grep -F -- "${BATS_TEST_TMPDIR}/samples/.pmc.log." "${SAMPLE_ARGS}"
}

@test "unknown PTP timescale or repeated fields cannot replace the last valid sample" {
  cat "${ROOT}/test/time/pmc.fixture" >"${SAMPLE_FIXTURE}"
  bash "${SAMPLER}" ptp "${BATS_TEST_TMPDIR}/samples"
  cp "${BATS_TEST_TMPDIR}/samples/pmc.log" "${BATS_TEST_TMPDIR}/valid.json"
  sed 's/currentUtcOffsetValid     1/currentUtcOffsetValid     0/' \
    "${ROOT}/test/time/pmc.fixture" >"${SAMPLE_FIXTURE}"
  run bash "${SAMPLER}" ptp "${BATS_TEST_TMPDIR}/samples"
  [ "${status}" -ne 0 ]
  cmp "${BATS_TEST_TMPDIR}/samples/pmc.log" "${BATS_TEST_TMPDIR}/valid.json"
  cat "${ROOT}/test/time/pmc.fixture" >"${SAMPLE_FIXTURE}"
  printf 'ingress_time 1784023200000000000\n' >>"${SAMPLE_FIXTURE}"
  run bash "${SAMPLER}" ptp "${BATS_TEST_TMPDIR}/samples"
  [ "${status}" -ne 0 ]
  cmp "${BATS_TEST_TMPDIR}/samples/pmc.log" "${BATS_TEST_TMPDIR}/valid.json"
}

@test "rotation retains only two complete PMC samples after repeated collection" {
  export SAMPLE_FIXTURE="${ROOT}/test/time/pmc.fixture"
  for _ in {1..8}; do
    bash "${SAMPLER}" ptp "${BATS_TEST_TMPDIR}/samples"
  done
  files=("${BATS_TEST_TMPDIR}/samples/"*)
  [ "${#files[@]}" -eq 2 ]
  [ -f "${BATS_TEST_TMPDIR}/samples/pmc.log.1" ]
  for file in "${files[@]}"; do
    jq -e -s 'length == 1 and .[0].source_unix_ms == 1784023163000' "${file}"
  done
  [ "$(du -b "${files[@]}" | awk '{s += $1} END {print s}')" -lt 2048 ]
}

@test "unsynchronized Chrony and PTP samples retain a failing synchronization flag" {
  sed 's/,Normal$/,Not synchronised/' "${SAMPLE_FIXTURE}" >"${BATS_TEST_TMPDIR}/unsync.csv"
  bash "${SAMPLER}" chrony "${BATS_TEST_TMPDIR}/samples" --stdin <"${BATS_TEST_TMPDIR}/unsync.csv"
  jq -e '.monotonic == 0' "${BATS_TEST_TMPDIR}/samples/chrony.log"
  bash "${SAMPLER}" ptp "${BATS_TEST_TMPDIR}/samples" --stdin <"${ROOT}/test/time/pmc-unsynchronized.fixture"
  jq -e '.monotonic == 0' "${BATS_TEST_TMPDIR}/samples/pmc.log"
}
