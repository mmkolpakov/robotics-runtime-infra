#!/usr/bin/env bash
set -Eeuo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${project_root}/host/.tools/PX4-Autopilot"
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
"${engine}" run --rm --init "${engine_options[@]}" \
  --user "$(id -u):$(id -g)" --env HOME=/tmp/px4-build --env GZ_DISTRO=jetty \
  --volume "${source_root}:/opt/px4:rw" --workdir /opt/px4 \
  "${PX4_DEPS_IMAGE}" make -j4 px4_sitl_default
