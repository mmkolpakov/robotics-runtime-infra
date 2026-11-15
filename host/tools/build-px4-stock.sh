#!/usr/bin/env bash
set -Eeuo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PX4_SOURCE_ROOT:-${project_root}/host/.tools/PX4-Autopilot}"
source_root="$(realpath -m -- "${source_root}")"
case "${source_root}" in "${project_root}/host/.tools/"*) ;; *) exit 65 ;; esac
owner="${PX4_BUILD_OWNER:-px4-build-${UID}-$$}"
[[ "${owner}" =~ ^[a-z0-9][a-z0-9_.-]{1,63}$ ]] || exit 64
container_name="${owner}-firmware"
read -r invocation </proc/sys/kernel/random/uuid
: "${PX4_DEPS_IMAGE:?immutable project dependency image required}"
engine="${PX4_CONTAINER_ENGINE:-podman}"
case "${engine}" in
  podman)
    : "${PX4_INIT_PATH:?verified project stock OCI init path required}"
    engine_options=(--init-path "${PX4_INIT_PATH}" --userns=keep-id)
    ;;
  docker) engine_options=() ;;
  *) printf 'unsupported PX4 container engine: %s\n' "${engine}" >&2; exit 64 ;;
esac
if [[ ! ${PX4_DEPS_IMAGE} =~ (^sha256:|@sha256:)[a-f0-9]{64}$ ]]; then
  printf 'immutable dependency image required\n' >&2
  exit 1
fi
mkdir -p "${project_root}/host/.tools"
existing="$("${engine}" ps --all --no-trunc --filter "name=^${container_name}$" --format '{{.ID}}')" || exit 1
[[ -z "${existing}" ]] || { printf 'build container name already exists: %s\n' "${container_name}" >&2; exit 65; }
container_id=
attach_pid=
# shellcheck disable=SC2329
cleanup_build() {
  local status=$? cleanup_status=0 ids candidate actual
  trap - EXIT
  if ! ids="$("${engine}" ps --all --no-trunc --filter "name=^${container_name}$" --format '{{.ID}}')"; then
    printf 'firmware container cleanup state unknown: %s\n' "${container_name}" >&2
    ((status != 0)) || status=1
    exit "${status}"
  fi
  for candidate in ${ids}; do
    if ! actual="$("${engine}" inspect --format '{{index .Config.Labels "org.robotics.build.invocation"}}' "${candidate}")"; then
      printf 'firmware container cleanup state unknown: %s\n' "${candidate}" >&2
      cleanup_status=1
    elif [[ "${actual}" != "${invocation}" || ( -n "${container_id}" && "${candidate}" != "${container_id}" ) ]]; then
      printf 'refusing foreign build container cleanup: %s\n' "${container_name}" >&2
      cleanup_status=65
    elif ! "${engine}" stop --time 10 "${candidate}" > /dev/null ||
         ! "${engine}" rm "${candidate}" > /dev/null; then
      printf 'firmware container cleanup state unknown: %s\n' "${candidate}" >&2
      cleanup_status=1
    fi
  done
  if ! ids="$("${engine}" ps --all --no-trunc --filter "name=^${container_name}$" --format '{{.ID}}')" || [[ -n "${ids}" ]]; then
    printf 'firmware container cleanup incomplete: %s\n' "${container_name}" >&2
    ((cleanup_status != 0)) || cleanup_status=1
  fi
  if [[ -n "${attach_pid}" ]]; then wait "${attach_pid}" 2>/dev/null || true; fi
  ((status != 0)) || status=${cleanup_status}
  exit "${status}"
}
trap cleanup_build EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ ! -d ${source_root}/.git ]]; then
  git -c http.version=HTTP/1.1 clone --depth=1 --branch=v1.17.0 --filter=blob:none --sparse \
    https://github.com/PX4/PX4-Autopilot.git "${source_root}"
fi
test "$(git -C "${source_root}" rev-parse HEAD)" = d6f12ad1c4f70ad3230afd7d86e971421e02fef4
test -z "$(git -C "${source_root}" status --porcelain --untracked-files=all)"
git -C "${source_root}" -c http.version=HTTP/1.1 sparse-checkout set --cone \
  src platforms boards/px4/sitl cmake msg ROMFS Tools
git -C "${source_root}" checkout --detach d6f12ad1c4f70ad3230afd7d86e971421e02fef4
git -C "${source_root}" -c http.version=HTTP/1.1 submodule update --init --recursive --depth=1 --filter=blob:none --jobs=4 -- \
  src/modules/mavlink/mavlink src/drivers/gps/devices src/lib/events/libevents \
  src/modules/uxrce_dds_client/Micro-XRCE-DDS-Client src/lib/cdrstream/cyclonedds \
  src/lib/cdrstream/rosidl src/lib/heatshrink/heatshrink Tools/simulation/gz
container_id="$("${engine}" create --init --name "${container_name}" \
  --label "org.robotics.build.owner=${owner}" --label "org.robotics.build.invocation=${invocation}" \
  "${engine_options[@]}" \
  --user "$(id -u):$(id -g)" --env HOME=/tmp/px4-build --env GZ_DISTRO=jetty \
  --volume "${source_root}:/opt/px4:rw" --workdir /opt/px4 \
  "${PX4_DEPS_IMAGE}" make -j4 px4_sitl_default)"
"${engine}" start --attach "${container_id}" &
attach_pid=$!
wait "${attach_pid}"
