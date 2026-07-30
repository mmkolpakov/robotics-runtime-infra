#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/ci/hardware-qualification/cleanup-runtime-resources.sh"
  FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
  FAKE_DOCKER_STATE="${BATS_TEST_TMPDIR}/docker-state"
  FAKE_DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  IMAGE_REF="registry.example/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  SUPPORT_IMAGE_REF="registry.example/support@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  mkdir -p "${FAKE_BIN}" "${FAKE_DOCKER_STATE}"
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >>"${FAKE_DOCKER_LOG}"
case "$1 $2" in
  "compose -f")
    test "${FAKE_COMPOSE_DOWN_FAIL:-0}" -eq 0
    ;;
  "image ls")
    test "${FAKE_IMAGE_QUERY_FAIL:-0}" -eq 0 || exit 70
    image="${5}"
    key="$(printf '%s' "${image}" | sha256sum | awk '{print $1}')"
    test ! -f "${FAKE_DOCKER_STATE}/present-${key}" ||
      printf 'sha256:%064d\n' 1
    ;;
  "image rm")
    test "${FAKE_IMAGE_REMOVE_FAIL:-0}" -eq 0 || exit 70
    image="${3}"
    key="$(printf '%s' "${image}" | sha256sum | awk '{print $1}')"
    rm -f "${FAKE_DOCKER_STATE}/present-${key}"
    ;;
  "container ls")
    test "${FAKE_CONTAINER_REMAINS:-0}" -eq 0 ||
      printf 'leftover-container\n'
    ;;
  "network ls")
    test "${FAKE_NETWORK_REMAINS:-0}" -eq 0 ||
      printf 'leftover-network\n'
    ;;
  "volume ls")
    test "${FAKE_VOLUME_REMAINS:-0}" -eq 0 ||
      printf 'leftover-volume\n'
    ;;
  *)
    exit 64
    ;;
esac
EOF
  chmod +x "${FAKE_BIN}/docker"
}

mark_image_present() {
  local image="$1"
  local key
  key="$(printf '%s' "${image}" | sha256sum | awk '{print $1}')"
  touch "${FAKE_DOCKER_STATE}/present-${key}"
}

run_cleanup() {
  run env \
    "PATH=${FAKE_BIN}:${PATH}" \
    "FAKE_DOCKER_LOG=${FAKE_DOCKER_LOG}" \
    "FAKE_DOCKER_STATE=${FAKE_DOCKER_STATE}" \
    COMPOSE_PROJECT_NAME=hardware-test \
    "IMAGE_REF=${IMAGE_REF}" \
    OVERLAY=compose.nvidia.yaml \
    PROFILE=conformance-nvidia \
    "$@" \
    "${SCRIPT}"
}

@test "hardware cleanup succeeds when all resources are absent" {
  run_cleanup

  [ "${status}" -eq 0 ]
}

@test "hardware cleanup fails when a Compose resource remains" {
  run_cleanup FAKE_CONTAINER_REMAINS=1

  [ "${status}" -eq 70 ]
  [[ "${output}" == *"container resources remain"* ]]
}

@test "hardware cleanup fails when Compose down fails" {
  run_cleanup FAKE_COMPOSE_DOWN_FAIL=1

  [ "${status}" -eq 70 ]
}

@test "hardware cleanup fails when image removal fails" {
  mark_image_present "${IMAGE_REF}"

  run_cleanup FAKE_IMAGE_REMOVE_FAIL=1

  [ "${status}" -eq 70 ]
  [[ "${output}" == *"qualification image remains after cleanup"* ]]
}

@test "hardware cleanup fails when Docker image inventory is unavailable" {
  run_cleanup FAKE_IMAGE_QUERY_FAIL=1

  [ "${status}" -eq 70 ]
  [[ "${output}" == *"qualification image inventory failed"* ]]
}

@test "hardware cleanup removes the runtime and support images" {
  mark_image_present "${IMAGE_REF}"
  mark_image_present "${SUPPORT_IMAGE_REF}"

  run_cleanup "SUPPORT_IMAGE_REF=${SUPPORT_IMAGE_REF}"

  [ "${status}" -eq 0 ]
  run grep -F "image rm ${IMAGE_REF}" "${FAKE_DOCKER_LOG}"
  [ "${status}" -eq 0 ]
  run grep -F "image rm ${SUPPORT_IMAGE_REF}" "${FAKE_DOCKER_LOG}"
  [ "${status}" -eq 0 ]
}

@test "hardware workflow serializes jobs by physical runner label" {
  run grep -F \
    'group: hardware-runner-${{ needs.prepare.outputs.runner_label }}' \
    .github/workflows/hardware-qualification.yml
  [ "${status}" -eq 0 ]

  run grep -F 'cancel-in-progress: false' \
    .github/workflows/hardware-qualification.yml
  [ "${status}" -eq 0 ]

  run grep -F 'COMPOSE_PROJECT_NAME:' \
    .github/workflows/hardware-qualification.yml
  [ "${status}" -eq 0 ]

  run grep -F \
    'run: scripts/ci/hardware-qualification/cleanup-runtime-resources.sh' \
    .github/workflows/hardware-qualification.yml
  [ "${status}" -eq 0 ]

  run grep -F '|| true' .github/workflows/hardware-qualification.yml
  [ "${status}" -eq 1 ]
}
