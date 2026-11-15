#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
}

prepare_firmware_fixture() {
  fixture="${BATS_TEST_TMPDIR}/repo"
  mock_bin="${BATS_TEST_TMPDIR}/bin"
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
case "$1" in
  create)
    touch "${CALLS}.created"
    printf '%s\n' "$@" >"${CALLS}.create"
    if [[ "${MOCK_CREATE_LOST:-}" == 1 ]]; then exit 1; fi
    printf '%s\n' 1234567890abcdef
    ;;
  start)
    if [[ "${MOCK_TERM:-}" == 1 ]]; then kill -TERM "$PPID"; exit 143; fi
    exit "${MOCK_BUILD_EXIT:-0}"
    ;;
  ps)
    if [[ "${MOCK_ENGINE_DOWN:-}" == 1 ]]; then exit 1; fi
    if [[ -e "${CALLS}.created" || "${MOCK_PREEXISTING:-}" == 1 ]]; then printf '%s\n' 1234567890abcdef; fi
    ;;
  inspect)
    if [[ "${MOCK_INSPECT_DOWN:-}" == 1 ]]; then exit 1; fi
    if [[ "${MOCK_OWNER:-}" == foreign ]]; then
      printf '%s\n' different-invocation
    else
      sed -n 's/^org.robotics.build.invocation=//p' "${CALLS}.create"
    fi
    ;;
  rm) printf '%s\n' "$*" >>"${CALLS}"; rm -f "${CALLS}.created" ;;
  *) printf '%s\n' "$*" >>"${CALLS}" ;;
esac
SH
  cp "${mock_bin}/docker" "${mock_bin}/podman"
  chmod +x "${mock_bin}"/*
  export CALLS="${BATS_TEST_TMPDIR}/calls"
}

prepare_cleanup_fixture() {
  fixture="${BATS_TEST_TMPDIR}/repo"
  mock_bin="${BATS_TEST_TMPDIR}/bin"
  scope=px4-source-10-1
  tool_root="${fixture}/host/.tools/${scope}"
  output_dir="${fixture}/artifacts/${scope}"
  mkdir -p "${fixture}/scripts/ci" "${fixture}/host/.tools" "${mock_bin}"
  cp "${REPOSITORY_ROOT}/scripts/ci/build-px4-source-images.sh" "${fixture}/scripts/ci/"
  cat >"${mock_bin}/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALLS}"
case "$1 $2" in
  "ps --all")
    if [[ "${MOCK_ENGINE_DOWN:-}" == 1 ]]; then exit 1; fi
    if [[ "$*" == *'--filter label='* ]]; then
      if [[ -n "${MOCK_REMAINING:-}" ]]; then printf '%s\n' "${MOCK_REMAINING}"; fi
    elif [[ -n "${MOCK_CONTAINERS:-}" ]]; then cat "${MOCK_CONTAINERS}"; fi
    ;;
  "image inspect")
    if [[ "$*" == *Config.Labels* ]]; then
      printf '%s\n' "${MOCK_IMAGE_OWNER:-px4-source-10-1}"
    else
      printf 'sha256:%064d\n' 1
    fi
    ;;
  "image ls")
    if [[ -n "${MOCK_IMAGES:-}" ]]; then cat "${MOCK_IMAGES}"; fi
    ;;
  "version --format") printf 'linux/amd64\n' ;;
  "version ") exit 42 ;;
esac
SH
  chmod +x "${mock_bin}/docker"
  export CALLS="${BATS_TEST_TMPDIR}/calls"
}

claim_fixture() {
  mkdir -p "${output_dir}/build-owner" "${tool_root}"
  printf '999999999\n' >"${output_dir}/build-owner/pid"
  printf '1\n' >"${output_dir}/build-owner/start"
  stat -c '%d:%i' "${tool_root}" >"${output_dir}/build-owner/tool-root-id"
}

@test "PX4 firmware builds keep engine-specific init and user options" {
  prepare_firmware_fixture
  run env PATH="${mock_bin}:${PATH}" PX4_CONTAINER_ENGINE=docker \
    PX4_BUILD_OWNER=px4-source-10-1 PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 0 ]
  grep -Fxq -- --init "${CALLS}.create"
  ! grep -Fxq -- --init-path "${CALLS}.create"
  ! grep -Fxq -- --userns=keep-id "${CALLS}.create"
  grep -Fxq -- px4_sitl_default "${CALLS}.create"
  grep -Fxq 'rm 1234567890abcdef' "${CALLS}"
  run env PATH="${mock_bin}:${PATH}" PX4_CONTAINER_ENGINE=podman \
    PX4_BUILD_OWNER=px4-source-10-1 PX4_INIT_PATH=/project/init \
    PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 0 ]
  grep -Fxq -- --init-path "${CALLS}.create"
  grep -Fxq -- /project/init "${CALLS}.create"
  grep -Fxq -- --userns=keep-id "${CALLS}.create"
}

@test "PX4 source image CI builds the complete worker with normal factories and security gates" {
  cd "${REPOSITORY_ROOT}" || return
  grep -Fq 'PX4_CONTAINER_ENGINE=docker PX4_DEPS_IMAGE=' scripts/ci/build-px4-source-images.sh
  grep -Fq 'bash host/tools/build-px4-stock.sh' scripts/ci/build-px4-source-images.sh
  grep -Fq -- '--engine docker --controller native-python-source' scripts/ci/build-px4-source-images.sh
  grep -Fq -- '--context-parent "${tool_root}"' scripts/ci/build-px4-source-images.sh
  grep -Fq 'scripts/ci/security/scan-image.sh "${deps_image}"' scripts/ci/build-px4-source-images.sh
  grep -Fq 'scripts/ci/security/scan-image.sh "${worker_image}"' scripts/ci/build-px4-source-images.sh
  grep -Fq 'host/workers/px4/mavsdk-source-lock.json' .github/workflows/px4-consumer.yml
  grep -Fq 'docker/px4-sitl*.Dockerfile' .github/workflows/px4-consumer.yml
  grep -Fq 'timeout-minutes: 120' .github/workflows/px4-consumer.yml
  grep -Fq 'docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc' .github/workflows/px4-consumer.yml
  grep -Fq 'load: true' .github/workflows/px4-consumer.yml
  grep -Fq 'run: scripts/ci/build-px4-source-images.sh --cleanup' .github/workflows/px4-consumer.yml
  ! grep -Fq 'type=gha' scripts/ci/build-px4-source-images.sh
  ! grep -Eq 'continue-on-error|ignore-unfixed|--severity|native-worker|run-land' scripts/ci/build-px4-source-images.sh
}

@test "PX4 firmware build rejects an unknown engine" {
  prepare_firmware_fixture
  run env PX4_CONTAINER_ENGINE=unknown PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"unsupported PX4 container engine"* ]]
}

@test "PX4 build and external cleanup preserve an unclaimed preexisting directory" {
  prepare_cleanup_fixture
  mkdir "${tool_root}"
  printf retained >"${tool_root}/input"
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh"
  [ "${status}" -eq 65 ]
  [ -f "${tool_root}/input" ]
  [ ! -e "${CALLS}" ]
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 65 ]
  [ -f "${tool_root}/input" ]
  [ ! -e "${CALLS}" ]
}

@test "PX4 cleanup preserves a live owner's paths" {
  prepare_cleanup_fixture
  claim_fixture
  printf '%s\n' "$$" >"${output_dir}/build-owner/pid"
  awk '{print $22}' "/proc/$$/stat" >"${output_dir}/build-owner/start"
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 65 ]
  [ -d "${tool_root}" ]
  [ ! -e "${CALLS}" ]
}

@test "PX4 cleanup preserves owned paths when the container engine is unavailable" {
  prepare_cleanup_fixture
  claim_fixture
  printf retained >"${tool_root}/input"
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 MOCK_ENGINE_DOWN=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 1 ]
  [ -f "${tool_root}/input" ]
  [ "$(cat "${output_dir}/cleanup.exit")" = unknown ]
  ! grep -E '^stop|^rm' "${CALLS}"
}

@test "PX4 cleanup refuses a matching name with a foreign owner" {
  prepare_cleanup_fixture
  claim_fixture
  export MOCK_CONTAINERS="${BATS_TEST_TMPDIR}/containers.jsonl"
  printf '%s\n' '{"ID":"foreign","Names":"px4-source-10-1-registry","Owned":false}' >"${MOCK_CONTAINERS}"
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 65 ]
  [ -d "${tool_root}" ]
  ! grep -E '^stop|^rm' "${CALLS}"
}

@test "PX4 cleanup refuses a replaced root and preserves its destination" {
  prepare_cleanup_fixture
  claim_fixture
  rmdir "${tool_root}"
  mkdir "${BATS_TEST_TMPDIR}/outside"
  printf retained >"${BATS_TEST_TMPDIR}/outside/input"
  ln -s "${BATS_TEST_TMPDIR}/outside" "${tool_root}"
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 65 ]
  [ -f "${BATS_TEST_TMPDIR}/outside/input" ]
}

@test "PX4 cleanup serializes duplicate cleanup invocations" {
  prepare_cleanup_fixture
  claim_fixture
  exec 8<"${output_dir}/build-owner"
  flock --exclusive 8
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 65 ]
  [ -d "${tool_root}" ]
  [ ! -e "${CALLS}" ]
  exec 8<&-
}

@test "PX4 cleanup removes recorded run tags while preserving unrelated shared tags" {
  prepare_cleanup_fixture
  claim_fixture
  local digest="sha256:$(printf '%064d' 1)"
  printf '[{"Id":"%s"}]\n' "${digest}" >"${output_dir}/dependency-image.json"
  printf '[{"Id":"%s"},{"Id":"%s"}]\n' "${digest}" "${digest}" >"${output_dir}/images.json"
  printf '127.0.0.1:5000/px4-deps:px4-source-10-1\n' >"${output_dir}/dependency-registry-tag.txt"
  export MOCK_IMAGES="${BATS_TEST_TMPDIR}/images.jsonl"
  printf '{"Repository":"local/robotics-px4-deps","Tag":"px4-source-10-1","ID":"%s"}\n' "${digest}" >"${MOCK_IMAGES}"
  printf '{"Repository":"local/robotics-px4-worker","Tag":"px4-source-10-1","ID":"%s"}\n' "${digest}" >>"${MOCK_IMAGES}"
  printf '{"Repository":"127.0.0.1:5000/px4-deps","Tag":"px4-source-10-1","ID":"%s"}\n' "${digest}" >>"${MOCK_IMAGES}"
  printf '{"Repository":"shared/worker","Tag":"retained","ID":"%s"}\n' "${digest}" >>"${MOCK_IMAGES}"
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 0 ]
  grep -Fxq 'image rm --no-prune local/robotics-px4-deps:px4-source-10-1' "${CALLS}"
  grep -Fxq 'image rm --no-prune local/robotics-px4-worker:px4-source-10-1' "${CALLS}"
  grep -Fxq 'image rm --no-prune 127.0.0.1:5000/px4-deps:px4-source-10-1' "${CALLS}"
  ! grep -Fq 'image rm --no-prune shared/worker' "${CALLS}"
  ! grep -Eq 'image rm --no-prune .*sha256:|image rm .*--force' "${CALLS}"
}

@test "PX4 cleanup removes partial owned contexts and preserves metadata and other runs" {
  prepare_cleanup_fixture
  claim_fixture
  context="${tool_root}/px4-image-${scope}"
  mkdir -p "${context}/metadata" "${fixture}/host/.tools/px4-source-11-1"
  printf evidence >"${context}/metadata/source.json"
  printf lock >"${context}/source-sdk-lock.json"
  printf 'retained\n' >"${output_dir}/receipt.json"
  export MOCK_CONTAINERS="${BATS_TEST_TMPDIR}/containers.jsonl"
  printf '%s\n' \
    '{"ID":"owned","Names":"px4-source-10-1-registry","Owned":true}' \
    '{"ID":"other","Names":"px4-source-11-1-registry","Owned":false}' >"${MOCK_CONTAINERS}"
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 0 ]
  [ ! -e "${tool_root}" ]
  [ -d "${fixture}/host/.tools/px4-source-11-1" ]
  [ "$(cat "${output_dir}/receipt.json")" = retained ]
  [ "$(cat "${output_dir}/source-metadata/source.json")" = evidence ]
  [ "$(cat "${output_dir}/source-sdk-lock.json")" = lock ]
  grep -Fxq 'stop --time 10 owned' "${CALLS}"
  grep -Fxq 'rm --volumes owned' "${CALLS}"
  ! grep -Eq '^(stop|rm).*other' "${CALLS}"
}

@test "PX4 build failure keeps its status after cleaning its acquired run directory" {
  prepare_cleanup_fixture
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh"
  [ "${status}" -eq 42 ]
  [ ! -e "${tool_root}" ]
  [ "$(cat "${output_dir}/cleanup.exit")" = 0 ]
}

@test "PX4 firmware cancellation preserves its status and stops only its captured container" {
  prepare_firmware_fixture
  run env PATH="${mock_bin}:${PATH}" PX4_CONTAINER_ENGINE=docker MOCK_TERM=1 \
    PX4_BUILD_OWNER=px4-source-10-1 PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 143 ]
  grep -Fxq 'stop --time 10 1234567890abcdef' "${CALLS}"
  grep -Fxq 'rm 1234567890abcdef' "${CALLS}"
}

@test "PX4 firmware cleanup recovers an owned container after a lost create reply" {
  prepare_firmware_fixture
  run env PATH="${mock_bin}:${PATH}" PX4_CONTAINER_ENGINE=docker MOCK_CREATE_LOST=1 \
    PX4_BUILD_OWNER=px4-source-10-1 PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 1 ]
  grep -Fxq 'rm 1234567890abcdef' "${CALLS}"
}

@test "PX4 firmware cleanup reports unknown when inspection fails" {
  prepare_firmware_fixture
  run env PATH="${mock_bin}:${PATH}" PX4_CONTAINER_ENGINE=docker MOCK_INSPECT_DOWN=1 \
    PX4_BUILD_OWNER=px4-source-10-1 PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"cleanup state unknown"* ]]
  [ ! -e "${CALLS}" ]
}

@test "PX4 firmware cleanup preserves the original build error and a foreign container" {
  prepare_firmware_fixture
  run env PATH="${mock_bin}:${PATH}" PX4_CONTAINER_ENGINE=docker MOCK_OWNER=foreign MOCK_BUILD_EXIT=23 \
    PX4_BUILD_OWNER=px4-source-10-1 PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 23 ]
  [[ "${output}" == *"refusing foreign"* ]]
  [ ! -e "${CALLS}" ]
}

@test "PX4 firmware refuses a preexisting matching container before claiming cleanup" {
  prepare_firmware_fixture
  run env PATH="${mock_bin}:${PATH}" PX4_CONTAINER_ENGINE=docker MOCK_PREEXISTING=1 \
    PX4_BUILD_OWNER=px4-source-10-1 PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
    bash "${fixture}/host/tools/build-px4-stock.sh"
  [ "${status}" -eq 65 ]
  [[ "${output}" == *"name already exists"* ]]
  [ ! -e "${CALLS}.create" ]
  [ ! -e "${CALLS}" ]
}

@test "PX4 cleanup rechecks that owned containers are gone before deleting contexts" {
  prepare_cleanup_fixture
  claim_fixture
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 MOCK_REMAINING=owned \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 1 ]
  [ -d "${tool_root}" ]
  [ "$(cat "${output_dir}/cleanup.exit")" = unknown ]
}

@test "PX4 cleanup verifies the dependency action image without a source claim" {
  prepare_cleanup_fixture
  export MOCK_IMAGES="${BATS_TEST_TMPDIR}/images.jsonl"
  printf '{"Repository":"local/robotics-px4-deps","Tag":"px4-source-10-1","ID":"sha256:%064d"}\n' 1 >"${MOCK_IMAGES}"
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 0 ]
  grep -Fxq 'image rm --no-prune local/robotics-px4-deps:px4-source-10-1' "${CALLS}"
  rm "${CALLS}"
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 MOCK_IMAGE_OWNER=foreign \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 65 ]
  ! grep -Fq 'image rm --no-prune ' "${CALLS}"
}

@test "PX4 cleanup requests only scoped identity fields from the Docker inventory" {
  prepare_cleanup_fixture
  claim_fixture
  run env PATH="${mock_bin}:${PATH}" GITHUB_RUN_ID=10 GITHUB_RUN_ATTEMPT=1 \
    bash "${fixture}/scripts/ci/build-px4-source-images.sh" --cleanup
  [ "${status}" -eq 0 ]
  grep -Fq -- 'ps --all --no-trunc --filter name=^/?px4-source-10-1-(firmware|inspection|registry)$' "${CALLS}"
  grep -Fq -- '"Owned":{{eq (.Label "org.robotics.build.owner") "px4-source-10-1"}}' "${CALLS}"
  ! grep -Fq -- "ps --all --no-trunc --format {{json .}}" "${CALLS}"
  grep -Fq -- 'image ls --no-trunc --filter reference=local/robotics-px4-deps:px4-source-10-1' "${CALLS}"
  grep -Fq -- '--filter reference=local/robotics-px4-worker:px4-source-10-1' "${CALLS}"
}

@test "PX4 firmware callers with the same owner preserve the concurrent winner and sentinel" {
  prepare_firmware_fixture
  export STATE="${BATS_TEST_TMPDIR}/engine"
  mkdir "${STATE}"
  printf retained >"${STATE}/sentinel"
  cat >"${mock_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  ps)
    if [[ ! -e "${STATE}/preflight-${CALLER}" ]]; then
      touch "${STATE}/preflight-${CALLER}"
      while [[ ! -e "${STATE}/preflight-a" || ! -e "${STATE}/preflight-b" ]]; do sleep .01; done
    elif [[ -d "${STATE}/container" ]]; then printf '1234567890abcdef\n'
    fi
    ;;
  create)
    if mkdir "${STATE}/container" 2>/dev/null; then
      printf '%s\n' "$@" | sed -n 's/^org.robotics.build.invocation=//p' >"${STATE}/invocation"
      printf '%s\n' "${CALLER}" >"${STATE}/winner"
      printf '1234567890abcdef\n'
    else
      while [[ ! -e "${STATE}/started" ]]; do sleep .01; done
      printf '%s\n' "${CALLER}" >"${STATE}/loser"
      exit 125
    fi
    ;;
  start)
    touch "${STATE}/started"
    while [[ ! -s "${STATE}/loser" ]]; do sleep .01; done
    while [[ ! -s "${STATE}/exit-$(cat "${STATE}/loser")" ]]; do sleep .01; done
    ;;
  inspect) cat "${STATE}/invocation" ;;
  stop|rm)
    printf '%s %s\n' "${CALLER}" "$*" >>"${STATE}/mutations"
    [[ "${CALLER}" == "$(cat "${STATE}/winner")" && "${*: -1}" == 1234567890abcdef ]]
    if [[ "$1" == rm ]]; then rmdir "${STATE}/container"; fi
    ;;
esac
SH
  for caller in a b; do
    (
      attempt_status=0
      timeout 10s env PATH="${mock_bin}:${PATH}" CALLER="${caller}" PX4_CONTAINER_ENGINE=docker \
        PX4_BUILD_OWNER=px4-source-10-1 PX4_DEPS_IMAGE="sha256:$(printf '%064d' 1)" \
        bash "${fixture}/host/tools/build-px4-stock.sh" || attempt_status=$?
      printf '%s\n' "${attempt_status}" >"${STATE}/exit-${caller}"
    ) >"${STATE}/output-${caller}" 2>&1 &
  done
  wait
  winner="$(cat "${STATE}/winner")"
  loser="$(cat "${STATE}/loser")"
  [ "$(cat "${STATE}/exit-${winner}")" -eq 0 ]
  [ "$(cat "${STATE}/exit-${loser}")" -eq 125 ]
  grep -Fq 'refusing foreign' "${STATE}/output-${loser}"
  [ "$(cat "${STATE}/sentinel")" = retained ]
  [ ! -d "${STATE}/container" ]
  [ "$(wc -l <"${STATE}/mutations")" -eq 2 ]
  grep -Fxq "${winner} stop --time 10 1234567890abcdef" "${STATE}/mutations"
  grep -Fxq "${winner} rm 1234567890abcdef" "${STATE}/mutations"
}
