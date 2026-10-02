#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  LIBRARY="${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh"
  FIXTURE="${BATS_TEST_TMPDIR}/runtime"
  FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
  FAKE_DOCKER_STATE="${BATS_TEST_TMPDIR}/docker-state"
  PROJECT=foundation-cleanup-1
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
      logs | down | up | exec | run) operation="$1"; shift; break ;;
      *) exit 64 ;;
    esac
  done
  [[ -n "${project}" ]] || exit 64
  case "${operation}" in
    logs) printf 'fixture Compose logs\n' ;;
    up) exit "${FAKE_UP_STATUS:-0}" ;;
    exec) exit 0 ;;
    run) exit "${FAKE_RUN_STATUS:-0}" ;;
    down)
      [[ "$*" == '--volumes --remove-orphans' ]] || exit 64
      test "${FAKE_DOWN_STATUS:-0}" -eq 0 || exit "${FAKE_DOWN_STATUS}"
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
elif [[ "$1" == cp ]]; then
  exit "${FAKE_CP_STATUS:-0}"
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
