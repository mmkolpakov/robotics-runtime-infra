#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
}

@test "PX4 firmware builds keep engine-specific init and user options" {
  local fixture="${BATS_TEST_TMPDIR}/repo" mock_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fixture}/host/tools" "${fixture}/host/.tools/PX4-Autopilot/.git" "${mock_bin}"
  cp "${REPOSITORY_ROOT}/host/tools/build-px4-stock.sh" "${fixture}/host/tools/"
  cat >"${mock_bin}/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'rev-parse HEAD') printf '%s\n' d6f12ad1c4f70ad3230afd7d86e971421e02fef4 ;;
esac
SH
  cat >"${mock_bin}/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${CALLS}"
SH
  cp "${mock_bin}/docker" "${mock_bin}/podman"
  chmod +x "${mock_bin}"/*
  export CALLS="${BATS_TEST_TMPDIR}/calls"
  run env PATH="${mock_bin}:${PATH}" PX4_CONTAINER_ENGINE=docker \
    PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 0 ]
  grep -Fxq -- --init "${CALLS}"
  ! grep -Fxq -- --init-path "${CALLS}"
  ! grep -Fxq -- --userns=keep-id "${CALLS}"
  grep -Fxq -- px4_sitl_default "${CALLS}"
  run env PATH="${mock_bin}:${PATH}" PX4_CONTAINER_ENGINE=podman \
    PX4_INIT_PATH=/project/init PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 0 ]
  grep -Fxq -- --init-path "${CALLS}"
  grep -Fxq -- /project/init "${CALLS}"
  grep -Fxq -- --userns=keep-id "${CALLS}"
}

@test "PX4 source image CI builds the complete worker with normal factories and security gates" {
  cd "${REPOSITORY_ROOT}" || return
  grep -Fq 'PX4_CONTAINER_ENGINE=docker PX4_DEPS_IMAGE=' scripts/ci/build-px4-source-images.sh
  grep -Fq 'bash host/tools/build-px4-stock.sh' scripts/ci/build-px4-source-images.sh
  grep -Fq -- '--engine docker --controller native-python-source' scripts/ci/build-px4-source-images.sh
  grep -Fq 'scripts/ci/security/scan-image.sh "${deps_image}"' scripts/ci/build-px4-source-images.sh
  grep -Fq 'scripts/ci/security/scan-image.sh "${worker_image}"' scripts/ci/build-px4-source-images.sh
  grep -Fq 'host/workers/px4/mavsdk-source-lock.json' .github/workflows/px4-consumer.yml
  grep -Fq 'docker/px4-sitl*.Dockerfile' .github/workflows/px4-consumer.yml
  grep -Fq 'timeout-minutes: 120' .github/workflows/px4-consumer.yml
  grep -Fq 'docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc' .github/workflows/px4-consumer.yml
  grep -Fq 'load: true' .github/workflows/px4-consumer.yml
  ! grep -Fq 'type=gha' scripts/ci/build-px4-source-images.sh
  ! grep -Eq 'continue-on-error|ignore-unfixed|--severity|native-worker|run-land' scripts/ci/build-px4-source-images.sh
}


@test "PX4 firmware build rejects an unknown engine" {
  local fixture="${BATS_TEST_TMPDIR}/repo" mock_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fixture}/host/tools" "${mock_bin}"
  cp "${REPOSITORY_ROOT}/host/tools/build-px4-stock.sh" "${fixture}/host/tools/"
  run env PX4_CONTAINER_ENGINE=unknown PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"unsupported PX4 container engine"* ]]
}
