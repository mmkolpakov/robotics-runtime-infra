#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  LIBRARY="${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh"
  ACCEPTANCE_SCRIPT="${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
  FIXTURE="${BATS_TEST_TMPDIR}/runtime"
  FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
  FAKE_DOCKER_STATE="${BATS_TEST_TMPDIR}/docker-state"
  PROJECT=foundation-cleanup-1
  REAL_JQ="$(command -v jq)"
  mkdir -p "${FIXTURE}/scripts/ci/foundation" "${FAKE_BIN}" \
    "${FAKE_DOCKER_STATE}"/{container,network,volume}
  cp "${LIBRARY}" "${REPOSITORY_ROOT}/scripts/ci/foundation/run-runtime.sh" \
    "${REPOSITORY_ROOT}/scripts/ci/foundation/run-edge-attach.sh" \
    "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance-isolation.sh" \
    "${FIXTURE}/scripts/ci/foundation/"
  # shellcheck source=scripts/ci/foundation/lib.sh
  source "${LIBRARY}"
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$1" == compose ]]; then
  shift
  project=''
  while (($#)); do
    case "$1" in
      -p) project="$2"; shift 2 ;;
      --profile) shift 2 ;;
      logs | down | up | exec | run | ps) operation="$1"; shift; break ;;
      *) exit 64 ;;
    esac
  done
  [[ -n "${project}" ]] || exit 64
  case "${operation}" in
    logs) printf 'fixture Compose logs\n' ;;
    ps)
      case "$*" in
        '--all --quiet runtime-metrics') printf '%s\n' "${FAKE_METRICS_CONTAINER:-}" ;;
        '--all --quiet runtime-probe-publisher') printf '%s\n' "${FAKE_PUBLISHER_CONTAINER:-}" ;;
        '--all --quiet playback') printf '%s\n' "${FAKE_PLAYBACK_CONTAINER:-}" ;;
        *) exit 64 ;;
      esac
      ;;
    up) exit "${FAKE_UP_STATUS:-0}" ;;
    exec) exit 0 ;;
    run) exit "${FAKE_RUN_STATUS:-0}" ;;
    down)
      [[ "$*" == '--volumes --remove-orphans' ]] || exit 64
      test "${FAKE_DOWN_STATUS:-0}" -eq 0 || exit "${FAKE_DOWN_STATUS}"
      if [[ "${FAKE_REMOVE_RUN_INPUTS:-false}" == true ]]; then
        rm -- "${FAKE_ACCEPTANCE_RUN_DIR}/runtime-manifest.json" \
          "${FAKE_ACCEPTANCE_RUN_DIR}/acceptance-run.json" \
          "${FAKE_ACCEPTANCE_RUN_DIR}/dataset-manifest.json"
      fi
      if [[ "${FAKE_REMOVE_ACTOR_INPUTS:-false}" == true ]]; then
        rm -f -- "${FAKE_DOCKER_STATE}/actor-inventory/"*
      fi
      for kind in container network volume; do
        [[ "${kind}" != "${FAKE_RETAIN_KIND:-}" ]] || continue
        for resource in "${FAKE_DOCKER_STATE}/${kind}/"*; do
          [[ -f "${resource}" ]] || continue
          read -r label <"${resource}"
          if [[ "${label}" == "${project}" ]]; then
            rm -- "${resource}"
          fi
        done
      done
      ;;
  esac
elif [[ "$1" == container || "$1" == network || "$1" == volume ]]; then
  kind="$1"
  shift
  [[ "$1" == ls ]] || exit 64
  shift
  project=''
  while (($#)); do
    case "$1" in
      --quiet | --all) shift ;;
      --filter)
        [[ "$2" == label=com.docker.compose.project=* ]] || exit 64
        project="${2#label=com.docker.compose.project=}"
        shift 2
        ;;
      *) exit 64 ;;
    esac
  done
  [[ -n "${project}" ]] || exit 64
  [[ "${kind}" != "${FAKE_QUERY_FAIL:-}" ]] || exit 71
  for resource in "${FAKE_DOCKER_STATE}/${kind}/"*; do
    [[ -f "${resource}" ]] || continue
    read -r label <"${resource}"
    if [[ "${label}" == "${project}" ]]; then
      printf '%s\n' "${resource##*/}"
    fi
  done
elif [[ "$1" == inspect || "$1" == stats || "$1" == exec ]]; then
  printf '%s\n' "$*" >>"${FAKE_DOCKER_STATE}/metrics-requests"
  case "$1" in
    inspect)
      [[ $# == 2 ]] || exit 64
      if [[ "$2" == "${FAKE_METRICS_CONTAINER:-}" ]]; then
        cat "${FAKE_DOCKER_STATE}/metrics-inspect.json"
      elif [[ "$2" == "${FAKE_PUBLISHER_CONTAINER:-}" ]]; then
        cat "${FAKE_DOCKER_STATE}/publisher-inspect.json"
      elif [[ "$2" == "${FAKE_PLAYBACK_CONTAINER:-}" ]]; then
        cat "${FAKE_DOCKER_STATE}/playback-inspect.json"
      else
        exit 64
      fi
      ;;
    stats)
      [[ "$*" == "stats --no-stream --format {{json .}} ${FAKE_METRICS_CONTAINER}" ]] || exit 64
      printf '{"CPUPerc":"2.50%%","MemUsage":"18MiB / 1GiB"}\n'
      ;;
    exec)
      [[ "$2" == "${FAKE_METRICS_CONTAINER}" && "$3" == cat && $# == 4 ]] || exit 64
      case "$4" in
        /sys/fs/cgroup/cpu.stat) printf 'usage_usec 1234\nnr_throttled 7\nthrottled_usec 300\n' ;;
        /sys/fs/cgroup/cpu.max) printf '50000 100000\n' ;;
        *) exit 64 ;;
      esac
      ;;
  esac
elif [[ "$1" == wait ]]; then
  printf '%s\n' "${FAKE_OBSERVER_STATUS:-0}"
elif [[ "$1" == logs ]]; then
  printf 'fixture observer logs\n'
elif [[ "$1" == cp ]]; then
  if [[ "$2" == *:/usr/share/robotics-runtime/deb-packages.tsv && $# == 3 ]]; then
    printf '%s\n' "$*" >>"${FAKE_DOCKER_STATE}/metrics-requests"
    if [[ "${FAKE_INVENTORY_CP_STATUS:-0}" != 0 ]]; then
      printf 'partial inventory\n' >"$3"
      exit "${FAKE_INVENTORY_CP_STATUS}"
    fi
    container="${2%%:*}"
    case "${FAKE_INVENTORY_PAYLOAD:-regular}" in
      empty) : >"$3" ;;
      directory) mkdir "$3"; printf 'unexpected payload\n' >"$3/child" ;;
      symlink) ln -s "${FAKE_DOCKER_STATE}/actor-inventory/${container}.tsv" "$3" ;;
      regular) cp -- "${FAKE_DOCKER_STATE}/actor-inventory/${container}.tsv" "$3" ;;
      *) exit 64 ;;
    esac
  else
    exit "${FAKE_CP_STATUS:-0}"
  fi
elif [[ "$1" == rm ]]; then
  exit 0
else
  exit 64
fi
EOF
  chmod +x "${FAKE_BIN}/docker"
}

mark_resource() {
  printf '%s\n' "$3" >"${FAKE_DOCKER_STATE}/$1/$2"
}

run_runtime() {
  run env "PATH=${FAKE_BIN}:${PATH}" \
    "FAKE_DOCKER_STATE=${FAKE_DOCKER_STATE}" \
    ROBOTICS_FOUNDATION_RUN_ID=cleanup GITHUB_RUN_ATTEMPT=1 \
    "ROBOTICS_FOUNDATION_ARTIFACT_DIR=${BATS_TEST_TMPDIR}/artifacts" \
    "$@" bash "${FIXTURE}/scripts/ci/foundation/run-runtime.sh"
}

run_acceptance_publication() {
  local lifecycle="${BATS_TEST_TMPDIR}/acceptance-publication.sh"
  mkdir -p "${FIXTURE}/run/results" "${FIXTURE}/artifacts"
  printf '{}\n' >"${FIXTURE}/run/results/acceptance-result.json"
  printf '{}\n' >"${FIXTURE}/run/scenario.yaml"
  mkdir -p "${FIXTURE}/run/bags/recording"
  cp "${REPOSITORY_ROOT}/test/fixtures/playback/golden/metadata.yaml" \
    "${REPOSITORY_ROOT}/test/fixtures/playback/golden/golden_0.mcap" \
    "${FIXTURE}/run/bags/recording/"
  cat >"${FAKE_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
operation="$1"
shift
if [[ "${FAKE_PUBLISH_FAIL:-}" == "${operation}" ]]; then
  printf 'fixture publication %s failed\n' "${operation}" >&2
  exit 29
fi
case "${operation}" in
  cp) cp "$@" ;;
  chown) exit 0 ;;
  *) exit 64 ;;
esac
EOF
  cat >"${FAKE_BIN}/jq" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${FAKE_INVENTORY_TOOL_FAIL:-}" == jq && "$1" == --arg && "$2" == digest ]]; then
  printf 'fixture inventory jq failed\n' >&2
  exit 62
fi
if [[ "$1" != . || $# != 2 ]]; then
  exec "${FAKE_REAL_JQ}" "$@"
fi
if [[ "${FAKE_PUBLISH_FAIL:-}" == jq ]]; then
  printf 'fixture publication jq failed\n' >&2
  exit 37
fi
cat "$2"
EOF
  chmod +x "${FAKE_BIN}/sudo" "${FAKE_BIN}/jq"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nsource %q\n' "${LIBRARY}"
    cat <<'EOF'
project="${FAKE_ACCEPTANCE_PROJECT}"
artifact_dir="${FAKE_ACCEPTANCE_ARTIFACT_DIR}"
run_dir="${FAKE_ACCEPTANCE_RUN_DIR}"
compose=(docker compose -p "${project}")
profiles=()
attached_compose=()
observer=fixture-observer
ROBOTICS_SIMULATION_LOCAL_IMAGE_ID="sha256:$(printf '1%.0s' {1..64})"
ROBOTICS_RUN_ID=fixture-run
ROBOTICS_DOMAIN_ID=primary
ROS_DOMAIN_ID=51
GZ_PARTITION=fixture-partition
EOF
    # Execute the real publication functions and EXIT trap, without ROS setup.
    sed -n '/^publish_acceptance_results() {/,/^trap cleanup EXIT/p' \
      "${ACCEPTANCE_SCRIPT}"
    cat <<'EOF'
if [[ "${FAKE_READONLY_ARTIFACT_DIR:-false}" == true ]]; then
  chmod 0555 "${artifact_dir}"
  if mkdir "${artifact_dir}/write-probe" 2>/dev/null; then
    printf 'fixture artifact directory is writable; IO regression is invalid\n' >&2
    exit 98
  fi
  capture_runtime_metrics_diagnostics before_metrics_stop
  chmod 0755 "${artifact_dir}"
fi
if [[ "${FAKE_READONLY_RUN_DIR:-false}" == true ]]; then
  chmod 0555 "${run_dir}"
  if mkdir "${run_dir}/write-probe" 2>/dev/null; then
    printf 'fixture run directory is writable; permission regression is invalid\n' >&2
    exit 98
  fi
fi
if [[ "${FAKE_METRICS_BEFORE_STOP:-false}" == true ]] &&
  declare -F capture_runtime_metrics_diagnostics >/dev/null; then
  capture_runtime_metrics_diagnostics before_metrics_stop
fi
if [[ "${FAKE_PRE_OBSERVER_STATUS:-0}" != 0 ]]; then
  exit "${FAKE_PRE_OBSERVER_STATUS}"
fi
EOF
    # Keep the real wait/publication/status sequence through its observer exit.
    awk '
      /^observer_status="\$\(docker wait / { emit = 1 }
      emit && /^"\$\{compose\[@\]\}" --profile acceptance run --rm --no-deps/ { exit }
      emit { print }
    ' "${ACCEPTANCE_SCRIPT}"
    # Detect continuation beyond the real failed-observer exit boundary.
    cat <<'EOF'
touch "${artifact_dir}/next-acceptance-stage"
EOF
  } >"${lifecycle}"

  run env "PATH=${FAKE_BIN}:${PATH}" \
    "FAKE_DOCKER_STATE=${FAKE_DOCKER_STATE}" \
    "FAKE_REAL_JQ=${REAL_JQ}" \
    "FAKE_ACCEPTANCE_PROJECT=${PROJECT}" \
    "FAKE_ACCEPTANCE_ARTIFACT_DIR=${FIXTURE}/artifacts" \
    "FAKE_ACCEPTANCE_RUN_DIR=${FIXTURE}/run" \
    FAKE_OBSERVER_STATUS=17 FAKE_DOWN_STATUS=73 \
    "$@" bash "${lifecycle}"
  chmod u+w "${FIXTURE}/run" "${FIXTURE}/artifacts"
}

assert_retained_capture() {
  local recording="${FIXTURE}/artifacts/acceptance-evidence/bags/recording"
  cmp "${FIXTURE}/run/bags/recording/metadata.yaml" "${recording}/metadata.yaml"
  cmp "${FIXTURE}/run/bags/recording/golden_0.mcap" "${recording}/golden_0.mcap"
  [ ! -e "${FIXTURE}/artifacts/next-acceptance-stage" ]
  [ ! -e "${FIXTURE}/artifacts/qualification" ]
  [ ! -e "${FIXTURE}/artifacts/qualification.sigstore.json" ]
}

@test "runtime cleanup removes its project resources and preserves foreign projects" {
  mark_resource container owned-container "${PROJECT}"
  mark_resource network owned-network "${PROJECT}"
  mark_resource volume owned-volume "${PROJECT}"
  mark_resource volume foreign-volume another-project
  mark_resource volume similar-project-volume "${PROJECT}-other"
  mark_resource network foreign-network another-project

  run_runtime

  [ "${status}" -eq 0 ]
  [ ! -e "${FAKE_DOCKER_STATE}/container/owned-container" ]
  [ ! -e "${FAKE_DOCKER_STATE}/network/owned-network" ]
  [ ! -e "${FAKE_DOCKER_STATE}/volume/owned-volume" ]
  [ -e "${FAKE_DOCKER_STATE}/volume/foreign-volume" ]
  [ -e "${FAKE_DOCKER_STATE}/volume/similar-project-volume" ]
  [ -e "${FAKE_DOCKER_STATE}/network/foreign-network" ]
}

@test "a leftover consumer volume fails an otherwise successful runtime run" {
  mark_resource volume consumer-data "${PROJECT}"

  run_runtime FAKE_RETAIN_KIND=volume

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"volume resources remain for project ${PROJECT}: consumer-data"* ]]
}

@test "Compose down failure remains a failure even when inventory is empty" {
  run_runtime FAKE_DOWN_STATUS=73

  [ "${status}" -eq 73 ]
  [[ "${output}" == *"Compose down failed (73)"* ]]
}

@test "runtime test failure survives cleanup failure and its volume diagnostic" {
  mark_resource volume consumer-data "${PROJECT}"

  run_runtime FAKE_RUN_STATUS=17 FAKE_DOWN_STATUS=73

  [ "${status}" -eq 17 ]
  [[ "${output}" == *"Compose down failed (73)"* ]]
  [[ "${output}" == *"volume resources remain for project ${PROJECT}"* ]]
}

@test "runtime test failure survives result capture failure and cleanup failure" {
  run_runtime FAKE_RUN_STATUS=17 FAKE_CP_STATUS=29 FAKE_DOWN_STATUS=73

  [ "${status}" -eq 17 ]
  [[ "${output}" == *"Compose down failed (73)"* ]]
}

@test "startup failure survives its EXIT cleanup failure" {
  run_runtime FAKE_UP_STATUS=23 FAKE_DOWN_STATUS=73

  [ "${status}" -eq 23 ]
  [[ "${output}" == *"Compose down failed (73)"* ]]
}

@test "unavailable volume inventory is not reported as a clean project" {
  run_runtime FAKE_QUERY_FAIL=volume

  [ "${status}" -eq 70 ]
  [[ "${output}" == *"volume inventory failed for project ${PROJECT}"* ]]
}

@test "cleanup retains the down failure when resources also remain" {
  mark_resource volume consumer-data "${PROJECT}"

  run_runtime FAKE_DOWN_STATUS=73

  [ "${status}" -eq 73 ]
  [[ "${output}" == *"Compose down failed (73)"* ]]
  [[ "${output}" == *"volume resources remain for project ${PROJECT}"* ]]
}

@test "edge attach preserves the child failure while reporting both project inventories" {
  cat >"${FIXTURE}/scripts/ci/foundation/run-acceptance.sh" <<'EOF'
#!/usr/bin/env bash
exit 19
EOF
  local project=foundation-e2e-cleanup-edge-attach-1
  mark_resource volume runtime-data "${project}"
  mark_resource volume observer-data "${project}-attach"

  run env "PATH=${FAKE_BIN}:${PATH}" \
    "FAKE_DOCKER_STATE=${FAKE_DOCKER_STATE}" \
    ROBOTICS_FOUNDATION_RUN_ID=cleanup GITHUB_RUN_ATTEMPT=1 \
    bash "${FIXTURE}/scripts/ci/foundation/run-edge-attach.sh"

  [ "${status}" -eq 19 ]
  [[ "${output}" == *"volume resources remain for project ${project}: runtime-data"* ]]
  [[ "${output}" == *"volume resources remain for project ${project}-attach: observer-data"* ]]
}

@test "parallel acceptance reports both child failures despite leftover project volumes" {
  cat >"${FIXTURE}/scripts/ci/foundation/run-acceptance.sh" <<'EOF'
#!/usr/bin/env bash
case "${ROBOTICS_FOUNDATION_RUN_ID}" in
  *-acceptance-a) exit 13 ;;
  *-acceptance-b) exit 17 ;;
  *) exit 64 ;;
esac
EOF
  mark_resource volume a-data foundation-e2e-cleanup-acceptance-a-1
  mark_resource volume b-data foundation-e2e-cleanup-acceptance-b-1

  run env "PATH=${FAKE_BIN}:${PATH}" \
    "FAKE_DOCKER_STATE=${FAKE_DOCKER_STATE}" \
    ROBOTICS_FOUNDATION_RUN_ID=cleanup GITHUB_RUN_ATTEMPT=1 \
    bash "${FIXTURE}/scripts/ci/foundation/run-acceptance-isolation.sh"

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"parallel acceptance failed: a=13 b=17"* ]]
  [[ "${output}" == *"volume resources remain for project foundation-e2e-cleanup-acceptance-a-1: a-data"* ]]
  [[ "${output}" == *"volume resources remain for project foundation-e2e-cleanup-acceptance-b-1: b-data"* ]]
}

@test "acceptance observer failure survives result copy failure and cleanup failure" {
  local observer_status
  for observer_status in 1 17 255; do
    run_acceptance_publication "FAKE_OBSERVER_STATUS=${observer_status}" FAKE_PUBLISH_FAIL=cp

    [ "${status}" -eq "${observer_status}" ]
    [[ "${output}" == *"fixture publication cp failed"* ]]
    [[ "${output}" == *"Compose down failed (73)"* ]]
  done
}

@test "acceptance observer failure survives result ownership failure and cleanup failure" {
  run_acceptance_publication FAKE_PUBLISH_FAIL=chown

  [ "${status}" -eq 17 ]
  [[ "${output}" == *"fixture publication chown failed"* ]]
  [[ "${output}" == *"Compose down failed (73)"* ]]
}

@test "acceptance observer failure survives result jq failure and cleanup failure" {
  run_acceptance_publication FAKE_PUBLISH_FAIL=jq

  [ "${status}" -eq 17 ]
  [[ "${output}" == *"fixture publication jq failed"* ]]
  [[ "${output}" == *"Compose down failed (73)"* ]]
  assert_retained_capture
}

@test "failed observer retains unchanged current-run inputs before producer cleanup" {
  local name expected retained
  expected="${BATS_TEST_TMPDIR}/expected-inputs"
  retained="${FIXTURE}/artifacts/acceptance-evidence"
  mkdir -p "${FIXTURE}/run" "${expected}"
  for name in runtime-manifest.json acceptance-run.json dataset-manifest.json; do
    printf '{ "input": "%s", "run": "current" }\n\n' "${name}" \
      >"${FIXTURE}/run/${name}"
    cp -a "${FIXTURE}/run/${name}" "${expected}/${name}"
  done

  run_acceptance_publication FAKE_DOWN_STATUS=0 FAKE_REMOVE_RUN_INPUTS=true

  [ "${status}" -eq 17 ]
  for name in runtime-manifest.json acceptance-run.json dataset-manifest.json; do
    [ ! -e "${FIXTURE}/run/${name}" ]
    cmp "${expected}/${name}" "${retained}/${name}"
  done
  assert_retained_capture
}

@test "startup failure does not synthesize missing inputs from a foreign run" {
  local name foreign
  foreign="${FIXTURE}/foreign-run"
  mkdir -p "${foreign}"
  for name in runtime-manifest.json acceptance-run.json dataset-manifest.json; do
    printf '{ "input": "%s", "run": "foreign" }\n' "${name}" \
      >"${foreign}/${name}"
  done

  run_acceptance_publication FAKE_PRE_OBSERVER_STATUS=23 FAKE_DOWN_STATUS=0

  [ "${status}" -eq 23 ]
  for name in runtime-manifest.json acceptance-run.json dataset-manifest.json; do
    [ -s "${foreign}/${name}" ]
    [ ! -e "${FIXTURE}/run/${name}" ]
    [ ! -e "${FIXTURE}/artifacts/acceptance-evidence/${name}" ]
  done
  assert_retained_capture
}

@test "a passed observer does not hide a publication failure" {
  run_acceptance_publication FAKE_OBSERVER_STATUS=0 FAKE_PUBLISH_FAIL=cp

  [ "${status}" -eq 29 ]
  [[ "${output}" == *"fixture publication cp failed"* ]]
}

@test "an invalid observer status cannot replace a publication failure" {
  local observer_status
  for observer_status in invalid-status 0009 256 999999999999999999999999999; do
    run_acceptance_publication \
      "FAKE_OBSERVER_STATUS=${observer_status}" FAKE_PUBLISH_FAIL=cp

    [ "${status}" -eq 29 ]
    [[ "${output}" == *"fixture publication cp failed"* ]]
    [[ "${output}" == *"Compose down failed (73)"* ]]
  done
}

@test "acceptance startup failure survives cleanup before observer status exists" {
  run_acceptance_publication FAKE_PRE_OBSERVER_STATUS=23

  [ "${status}" -eq 23 ]
  [[ "${output}" == *"Compose down failed (73)"* ]]
  assert_retained_capture
}

run_playback_measurement_boundary() {
  local lifecycle="${BATS_TEST_TMPDIR}/playback-window.sh"
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == inspect && "$2" == --format && "$4" == fixture-playback ]]; then
  printf '%s\n' "${FAKE_PLAYBACK_RUNNING}"
elif [[ "$1" == compose ]]; then
  printf '%s\n' "$*" >>"${FAKE_WINDOW_CALLS}"
else
  exit 64
fi
EOF
  chmod +x "${FAKE_BIN}/docker"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    printf 'data_source=recording_playback\nsimulation_container=fixture-playback\n'
    printf 'measurement_complete=%q\n' "${BATS_TEST_TMPDIR}/measurement-complete"
    printf 'compose=(docker compose)\n'
    printf 'run_dir=%q\nartifact_dir=%q\nproject=%q\n' \
      "${FIXTURE}/run" "${FIXTURE}/artifacts" "${PROJECT}"
    # Match the real runner's empty caller registry before extracting its boundary.
    printf 'source %q\n' "${LIBRARY}"
    printf 'foundation_load_artifact_arguments %q %q\n' "${REPOSITORY_ROOT}" ""
    printf 'foundation_stage_extension_schemas %q\n' "${FIXTURE}/run"
    awk '
      /^capture_runtime_metrics_diagnostics\(\) {/ { emit = 1 }
      emit && /^publish_failure_evidence\(\) {/ { exit }
      emit { print }
    ' "${ACCEPTANCE_SCRIPT}"
    # Run the real window boundary after a passing provider probe. A single
    # received message never substitutes for a completed live observer window.
    awk '
      /^while \[\[ ! -f "\$\{measurement_complete\}" \]\]; do/ { emit = 1 }
      emit && /^sleep 2$/ { exit }
      emit { print }
    ' "${ACCEPTANCE_SCRIPT}"
  } >"${lifecycle}"
  run env "PATH=${FAKE_BIN}:${PATH}" \
    "FAKE_WINDOW_CALLS=${BATS_TEST_TMPDIR}/window-calls" \
    "$@" bash "${lifecycle}"
}

@test "playback EOF after a successful probe cannot pass an incomplete measurement window" {
  run_playback_measurement_boundary FAKE_PLAYBACK_RUNNING=false
  [ "${status}" -eq 70 ]
  [[ "${output}" == *'ended before the live measurement completed'* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/window-calls" ]
}

@test "playback EOF at a recorded completion marker still refuses the completion proof" {
  touch "${BATS_TEST_TMPDIR}/measurement-complete"
  run_playback_measurement_boundary FAKE_PLAYBACK_RUNNING=false
  [ "${status}" -eq 70 ]
  [[ "${output}" == *'ended before the live completion proof'* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/window-calls" ]
}

@test "a completed observer window with a running player reaches normal recording finalization" {
  touch "${BATS_TEST_TMPDIR}/measurement-complete"
  run_playback_measurement_boundary FAKE_PLAYBACK_RUNNING=true
  [ "${status}" -eq 0 ]
  grep -qx 'compose --profile observability stop runtime-metrics' "${BATS_TEST_TMPDIR}/window-calls"
  grep -qx 'compose --profile playback stop playback' "${BATS_TEST_TMPDIR}/window-calls"
}


write_metrics_inspect() {
  local container="$1" project="$2" service="$3" output=metrics-inspect.json
  [[ "${service}" != runtime-probe-publisher ]] || output=publisher-inspect.json
  [[ "${service}" != playback ]] || output=playback-inspect.json
  jq -n --arg container "${container}" --arg project "${project}" \
    --arg service "${service}" --arg image "sha256:$(printf '1%.0s' {1..64})" '[{
      Id: $container,
      Image: $image,
      Config: {
        Labels: {
          "com.docker.compose.project": $project,
          "com.docker.compose.service": $service
        },
        Env: ["TOKEN=must-not-retain", "ROBOTICS_RUN_ID=fixture-run",
          "ROBOTICS_DOMAIN_ID=primary", "ROS_DOMAIN_ID=51", "GZ_PARTITION=fixture-partition"],
        Cmd: ["private-argument"]
      },
      State: {Status: "running", Running: true, ExitCode: 0},
      HostConfig: {
        NanoCpus: 500000000, CpuPeriod: 100000, CpuQuota: 50000,
        CpuShares: 512, CpusetCpus: "0", CpusetMems: "",
        Binds: ["private-mount"]
      }
    }]' >"${FAKE_DOCKER_STATE}/${output}"
}

write_actor_inventory() {
  mkdir -p "${FAKE_DOCKER_STATE}/actor-inventory"
  printf 'ros-jazzy-rclpy\t9.1.0-1noble.20260901\tamd64\n' \
    >"${FAKE_DOCKER_STATE}/actor-inventory/$1.tsv"
}

@test "failed acceptance retains actual owned metrics CPU snapshot before stop" {
  local container snapshot
  container="$(printf 'a%.0s' {1..64})"
  write_metrics_inspect "${container}" "${PROJECT}" runtime-metrics

  run_acceptance_publication \
    "FAKE_METRICS_CONTAINER=${container}" FAKE_METRICS_BEFORE_STOP=true

  [ "${status}" -eq 17 ]
  snapshot="${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics/${container}"
  jq -e '.phase == "before_metrics_stop" and .state.Running == true and
    .cpu_limits.CpuQuota == 50000 and .cpu_limits.CpuPeriod == 100000 and
    .cpu_limits.NanoCpus == 500000000 and .cpu_limits.CpusetCpus == "0" and
    (has("Config") | not)' "${snapshot}/inspect.json"
  cmp "${FIXTURE}/artifacts/runtime-metrics-diagnostics/${container}/cpu.stat" "${snapshot}/cpu.stat"
  grep -Fx 'nr_throttled 7' "${snapshot}/cpu.stat"
  grep -Fx '50000 100000' "${snapshot}/cpu.max"
  jq -e '.CPUPerc == "2.50%"' "${snapshot}/docker-stats.jsonl"
  [ "$(grep -c '^inspect ' "${FAKE_DOCKER_STATE}/metrics-requests")" -eq 1 ]
  run grep -RqE 'must-not-retain|private-argument|private-mount' \
    "${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics"
  [ "${status}" -eq 1 ]
  assert_retained_capture
}

@test "metrics CPU snapshot rejects foreign project and wrong service before stats or exec" {
  local container project service
  container="$(printf 'b%.0s' {1..64})"
  for project in another-project "${PROJECT}"; do
    service=runtime-metrics
    [[ "${project}" != "${PROJECT}" ]] || service=another-service
    write_metrics_inspect "${container}" "${project}" "${service}"
    rm -rf -- "${FIXTURE}/artifacts/runtime-metrics-diagnostics" \
      "${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics"

    run_acceptance_publication "FAKE_METRICS_CONTAINER=${container}"

    [ "${status}" -eq 17 ]
    [ ! -e "${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics/${container}" ]
    run grep -qE '^(stats|exec) ' "${FAKE_DOCKER_STATE}/metrics-requests"
    [ "${status}" -eq 1 ]
    assert_retained_capture
  done
}

@test "successful acceptance retains visible actor inventory without failure evidence" {
  local container
  container="$(printf 'c%.0s' {1..64})"
  write_metrics_inspect "${container}" "${PROJECT}" runtime-metrics
  write_actor_inventory "${container}"

  run_acceptance_publication "FAKE_METRICS_CONTAINER=${container}" \
    FAKE_METRICS_BEFORE_STOP=true FAKE_OBSERVER_STATUS=0 FAKE_DOWN_STATUS=0

  [ "${status}" -eq 0 ]
  local snapshot="${FIXTURE}/artifacts/runtime-metrics-diagnostics/${container}"
  jq -e '.native_inventory.status == "captured" and
    .native_inventory.path == "deb-packages.tsv" and .native_inventory.size_bytes > 0 and
    (.native_inventory.sha256 | test("^[a-f0-9]{64}$"))' "${snapshot}/inspect.json"
  cmp "${FAKE_DOCKER_STATE}/actor-inventory/${container}.tsv" "${snapshot}/deb-packages.tsv"
  [ "$(cat "${snapshot}/inventory-capture.exit")" -eq 0 ]
  [ ! -e "${FIXTURE}/artifacts/acceptance-evidence" ]
}


@test "non-writable producer run directory preserves the original failure and owned diagnostics" {
  local container snapshot
  container="$(printf 'd%.0s' {1..64})"
  write_metrics_inspect "${container}" "${PROJECT}" runtime-metrics

  run_acceptance_publication "FAKE_METRICS_CONTAINER=${container}" \
    FAKE_READONLY_RUN_DIR=true FAKE_METRICS_BEFORE_STOP=true FAKE_PRE_OBSERVER_STATUS=23

  [ "${status}" -eq 23 ]
  snapshot="${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics/${container}"
  jq -e '.phase == "before_metrics_stop" and .state.Running == true and
    .cpu_limits.CpuQuota == 50000' "${snapshot}/inspect.json"
  grep -Fx 'nr_throttled 7' "${snapshot}/cpu.stat"
  [ ! -e "${FIXTURE}/run/runtime-metrics-diagnostics" ]
  assert_retained_capture
}

@test "non-writable producer run directory does not fail a successful qualification" {
  local container
  container="$(printf 'e%.0s' {1..64})"
  write_metrics_inspect "${container}" "${PROJECT}" runtime-metrics

  run_acceptance_publication "FAKE_METRICS_CONTAINER=${container}" \
    FAKE_READONLY_RUN_DIR=true FAKE_METRICS_BEFORE_STOP=true \
    FAKE_OBSERVER_STATUS=0 FAKE_DOWN_STATUS=0

  [ "${status}" -eq 0 ]
  [ -s "${FIXTURE}/artifacts/runtime-metrics-diagnostics/${container}/inspect.json" ]
  [ ! -e "${FIXTURE}/artifacts/acceptance-evidence" ]
  [ ! -e "${FIXTURE}/run/runtime-metrics-diagnostics" ]
}


@test "diagnostic staging IO failure preserves the original status and later available evidence" {
  local container snapshot
  container="$(printf 'f%.0s' {1..64})"
  write_metrics_inspect "${container}" "${PROJECT}" runtime-metrics

  run_acceptance_publication "FAKE_METRICS_CONTAINER=${container}" \
    FAKE_READONLY_ARTIFACT_DIR=true FAKE_PRE_OBSERVER_STATUS=23

  [ "${status}" -eq 23 ]
  [[ "${output}" == *"Permission denied"* ]]
  snapshot="${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics/${container}"
  jq -e '.phase == "before_project_cleanup" and .state.Running == true' \
    "${snapshot}/inspect.json"
  grep -Fx 'nr_throttled 7' "${snapshot}/cpu.stat"
  assert_retained_capture
}

@test "failed acceptance retains each admitted actor inventory before owned cleanup" {
  local metrics publisher snapshot expected container
  metrics="$(printf '1%.0s' {1..64})"
  publisher="$(printf '2%.0s' {1..64})"
  write_metrics_inspect "${metrics}" "${PROJECT}" runtime-metrics
  write_metrics_inspect "${publisher}" "${PROJECT}" runtime-probe-publisher
  write_actor_inventory "${metrics}"
  write_actor_inventory "${publisher}"
  # Equal image IDs do not substitute for independently copied actor bytes.
  printf 'ros-jazzy-ros2topic\t0.32.6-1noble.20260901\tamd64\n' \
    >>"${FAKE_DOCKER_STATE}/actor-inventory/${publisher}.tsv"
  expected="${BATS_TEST_TMPDIR}/expected-inventory"
  cp -a "${FAKE_DOCKER_STATE}/actor-inventory" "${expected}"

  run_acceptance_publication "FAKE_METRICS_CONTAINER=${metrics}" \
    "FAKE_PUBLISHER_CONTAINER=${publisher}" FAKE_METRICS_BEFORE_STOP=true \
    FAKE_REMOVE_ACTOR_INPUTS=true FAKE_DOWN_STATUS=0

  [ "${status}" -eq 17 ]
  for container in "${metrics}" "${publisher}"; do
    snapshot="${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics/${container}"
    [ ! -e "${FAKE_DOCKER_STATE}/actor-inventory/${container}.tsv" ]
    cmp "${expected}/${container}.tsv" "${snapshot}/deb-packages.tsv"
    jq -e --arg container "${container}" \
      --arg digest "$(sha256sum "${expected}/${container}.tsv" | cut -d' ' -f1)" \
      --argjson size "$(stat -c '%s' "${expected}/${container}.tsv")" '
      .container_id == $container and .run_id == "fixture-run" and
      .domain_id == "primary" and .ros_domain_id == "51" and .partition == "fixture-partition" and
      .native_inventory.status == "captured" and .native_inventory.sha256 == $digest and
      .native_inventory.size_bytes == $size
    ' "${snapshot}/inspect.json"
    [ "$(cat "${snapshot}/inventory-capture.exit")" -eq 0 ]
  done
  [ ! -e "${FIXTURE}/artifacts/runtime-metrics-diagnostics/${publisher}/cpu.stat" ]
  [ "$(grep -c '^cp ' "${FAKE_DOCKER_STATE}/metrics-requests")" -eq 2 ]
  run grep -RqE 'must-not-retain|private-argument|private-mount' \
    "${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics"
  [ "${status}" -eq 1 ]
  assert_retained_capture
}

@test "native inventory refuses wrong image and ambiguous or foreign run markers before copying" {
  local container mutation source snapshot
  container="$(printf '3%.0s' {1..64})"
  source="${FAKE_DOCKER_STATE}/metrics-inspect.json"
  for mutation in \
    '.[0].Image = "sha256:foreign-image"' \
    '.[0].Config.Env += ["ROBOTICS_RUN_ID=fixture-run"]' \
    '.[0].Config.Env |= map(if startswith("ROBOTICS_RUN_ID=") then "ROBOTICS_RUN_ID=foreign" else . end)' \
    '.[0].Config.Env |= map(if startswith("ROBOTICS_DOMAIN_ID=") then "ROBOTICS_DOMAIN_ID=foreign" else . end)' \
    '.[0].Config.Env |= map(if startswith("ROS_DOMAIN_ID=") then "ROS_DOMAIN_ID=52" else . end)' \
    '.[0].Config.Env |= map(if startswith("GZ_PARTITION=") then "GZ_PARTITION=foreign" else . end)'; do
    write_metrics_inspect "${container}" "${PROJECT}" runtime-metrics
    write_actor_inventory "${container}"
    jq "${mutation}" "${source}" >"${source}.tmp"
    mv -- "${source}.tmp" "${source}"
    rm -rf -- "${FIXTURE}/artifacts/runtime-metrics-diagnostics" \
      "${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics"
    rm -f -- "${FAKE_DOCKER_STATE}/metrics-requests"

    run_acceptance_publication "FAKE_METRICS_CONTAINER=${container}" FAKE_DOWN_STATUS=0

    [ "${status}" -eq 17 ]
    snapshot="${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics"
    [ ! -e "${snapshot}/${container}" ]
    grep -F 'actor identity refused: runtime-metrics' "${snapshot}/capture-errors.log"
    run grep -qE '^(cp|stats|exec) ' "${FAKE_DOCKER_STATE}/metrics-requests"
    [ "${status}" -eq 1 ]
  done
}

@test "missing or failed native inventory has no success digest and preserves original errors" {
  local container snapshot original failure
  container="$(printf '4%.0s' {1..64})"
  write_metrics_inspect "${container}" "${PROJECT}" runtime-metrics
  for original in 17 124 137; do
    for failure in 0 29; do
      rm -rf -- "${FIXTURE}/artifacts/runtime-metrics-diagnostics" \
        "${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics"
      # Status zero exercises a genuine missing source, not an injected cp error.
      run_acceptance_publication "FAKE_METRICS_CONTAINER=${container}" \
        "FAKE_OBSERVER_STATUS=${original}" "FAKE_INVENTORY_CP_STATUS=${failure}" FAKE_DOWN_STATUS=0

      [ "${status}" -eq "${original}" ]
      snapshot="${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics/${container}"
      jq -e '.native_inventory.status == "unavailable" and
        (.native_inventory | has("sha256") | not) and
        (.native_inventory | has("size_bytes") | not)' "${snapshot}/inspect.json"
      [ "$(cat "${snapshot}/inventory-capture.exit")" -ne 0 ]
      [ ! -e "${snapshot}/deb-packages.tsv" ]
      [ ! -e "${snapshot}/.deb-packages.tsv" ]
      assert_retained_capture
    done
  done
}

@test "successful observer keeps missing native inventory diagnostic without a new acceptance gate" {
  local container snapshot
  container="$(printf '5%.0s' {1..64})"
  write_metrics_inspect "${container}" "${PROJECT}" runtime-metrics

  run_acceptance_publication "FAKE_METRICS_CONTAINER=${container}" \
    FAKE_METRICS_BEFORE_STOP=true FAKE_OBSERVER_STATUS=0 FAKE_DOWN_STATUS=0

  [ "${status}" -eq 0 ]
  snapshot="${FIXTURE}/artifacts/runtime-metrics-diagnostics/${container}"
  jq -e '.native_inventory.status == "unavailable" and
    (.native_inventory | has("sha256") | not)' "${snapshot}/inspect.json"
  [ "$(cat "${snapshot}/inventory-capture.exit")" -ne 0 ]
  [ ! -e "${FIXTURE}/artifacts/acceptance-evidence" ]
}

@test "native inventory rejects empty directory or symlink payload and discards partial timeout bytes" {
  local container snapshot payload
  container="$(printf '6%.0s' {1..64})"
  write_metrics_inspect "${container}" "${PROJECT}" runtime-metrics
  write_actor_inventory "${container}"
  for payload in empty directory symlink timeout; do
    rm -rf -- "${FIXTURE}/artifacts/runtime-metrics-diagnostics" \
      "${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics"
    local copy_status=0
    [[ "${payload}" != timeout ]] || copy_status=124

    run_acceptance_publication "FAKE_METRICS_CONTAINER=${container}" \
      "FAKE_INVENTORY_PAYLOAD=${payload}" "FAKE_INVENTORY_CP_STATUS=${copy_status}" FAKE_DOWN_STATUS=0

    [ "${status}" -eq 17 ]
    snapshot="${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics/${container}"
    jq -e '.native_inventory.status == "unavailable" and
      (.native_inventory | has("sha256") | not)' "${snapshot}/inspect.json"
    [ "$(cat "${snapshot}/inventory-capture.exit")" -ne 0 ]
    [ ! -e "${snapshot}/deb-packages.tsv" ]
    [ ! -L "${snapshot}/deb-packages.tsv" ]
    [ ! -e "${snapshot}/.deb-packages.tsv" ]
    [ ! -L "${snapshot}/.deb-packages.tsv" ]
  done
}

@test "native inventory hash size and receipt failures never leave a success receipt" {
  local container snapshot tool actual pattern
  container="$(printf '7%.0s' {1..64})"
  write_metrics_inspect "${container}" "${PROJECT}" runtime-metrics
  write_actor_inventory "${container}"
  for tool in sha256sum stat mv; do
    actual="$(command -v "${tool}")"
    pattern='*.deb-packages.tsv*'
    [[ "${tool}" != mv ]] || pattern='*.inspect.json*'
    {
      printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
      printf 'if [[ "${FAKE_INVENTORY_TOOL_FAIL:-}" == %q && "$*" == %s ]]; then exit 61; fi\n' "${tool}" "${pattern}"
      printf 'exec %q "$@"\n' "${actual}"
    } >"${FAKE_BIN}/${tool}"
    chmod +x "${FAKE_BIN}/${tool}"
  done
  for tool in sha256sum stat jq mv; do
    rm -rf -- "${FIXTURE}/artifacts/runtime-metrics-diagnostics" \
      "${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics"

    run_acceptance_publication "FAKE_METRICS_CONTAINER=${container}" \
      "FAKE_INVENTORY_TOOL_FAIL=${tool}" FAKE_DOWN_STATUS=0

    [ "${status}" -eq 17 ]
    snapshot="${FIXTURE}/artifacts/acceptance-evidence/runtime-metrics-diagnostics/${container}"
    jq -e '.native_inventory.status == "unavailable" and
      (.native_inventory | has("sha256") | not) and
      (.native_inventory | has("size_bytes") | not)' "${snapshot}/inspect.json"
    [ "$(cat "${snapshot}/inventory-capture.exit")" -ne 0 ]
    [ ! -e "${snapshot}/deb-packages.tsv" ]
    [ ! -e "${snapshot}/.inspect.json" ]
  done
}
