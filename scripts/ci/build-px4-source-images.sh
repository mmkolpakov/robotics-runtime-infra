#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${root}"
: "${GITHUB_RUN_ID:?CI run identity required}"
: "${GITHUB_RUN_ATTEMPT:?CI attempt identity required}"
[[ "${GITHUB_RUN_ID}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT}" =~ ^[0-9]+$ ]] || exit 64
scope="px4-source-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
output="${root}/artifacts/${scope}"
tool_root="${root}/host/.tools/${scope}"
context_name="px4-image-${scope}"
[[ "$(realpath -m -- "${output}")" == "${output}" &&
   "$(realpath -m -- "${tool_root}")" == "${tool_root}" ]] || exit 65
mkdir -p "${output}" "${root}/host/.tools"
deps_tag="local/robotics-px4-deps:${scope}"
worker_tag="local/robotics-px4-worker:${scope}"
context="${tool_root}/${context_name}"
claim="${output}/build-owner"
has_claim=true
if [[ "${1:-}" == --cleanup ]]; then
  [[ $# == 1 ]] || exit 64
  if [[ ! -d "${claim}" ]]; then
    [[ ! -e "${tool_root}" && ! -L "${tool_root}" ]] || exit 65
    has_claim=false
  else
    [[ ! -L "${claim}" ]] || exit 65
    owner_pid="$(cat "${claim}/pid")"
    owner_start="$(cat "${claim}/start")"
    [[ "${owner_pid}" =~ ^[0-9]+$ && "${owner_start}" =~ ^[0-9]+$ ]] || exit 65
    if [[ -r "/proc/${owner_pid}/stat" &&
          "$(awk '{print $22}' "/proc/${owner_pid}/stat")" == "${owner_start}" ]]; then
      printf 'refusing cleanup while the build owner is active\n' >&2
      exit 65
    fi
  fi
else
  [[ $# == 0 && ! -e "${tool_root}" && ! -L "${tool_root}" ]] || exit 65
  mkdir "${claim}" || exit 65
  printf '%s\n' "$$" >"${claim}/pid"
  awk '{print $22}' "/proc/$$/stat" >"${claim}/start"
  mkdir "${tool_root}"
  stat -c '%d:%i' "${tool_root}" >"${claim}/tool-root-id"
fi
if ${has_claim}; then
  exec 9<"${claim}"
  flock --nonblock 9 || exit 65
fi
# shellcheck disable=SC2329
cleanup() {
  local status=$? cleanup_status=0 container tag observed image_id owner_label registry_tag
  local image_filters=(--filter "reference=${deps_tag}")
  local container_format='{"ID":{{json .ID}},"Names":{{json .Names}},"Owned":{{eq (.Label "org.robotics.build.owner") "'"${scope}"'"}}}'
  trap - EXIT
  if ! docker ps --all --no-trunc --filter "name=^/?${scope}-(firmware|inspection|registry)$" \
    --format "${container_format}" \
    >"${output}/cleanup-containers.jsonl"; then
    printf 'container engine unavailable; build resources retained\n' >&2
    printf 'unknown\n' >"${output}/cleanup.exit"
    ((status != 0)) || status=1
    exit "${status}"
  fi
  if ${has_claim} && python3 - "${output}/cleanup-containers.jsonl" "${scope}" >"${output}/cleanup-container-ids" <<'PY'
import json
import sys
from pathlib import Path
scope = sys.argv[2]
names = {scope + suffix for suffix in ("-firmware", "-inspection", "-registry")}
for line in Path(sys.argv[1]).read_text().splitlines():
    row = json.loads(line)
    if row["Names"] not in names:
        continue
    if not row["Owned"]:
        print("refusing foreign container cleanup: " + row["Names"], file=sys.stderr)
        sys.exit(65)
    print(row["ID"])
PY
  then
    while IFS= read -r container; do
      if ! docker stop --time 10 "${container}" > /dev/null ||
         ! docker rm --volumes "${container}" > /dev/null; then
        cleanup_status=1
      fi
    done <"${output}/cleanup-container-ids"
  else
    observed=$?
    if ${has_claim}; then cleanup_status=${observed}; fi
  fi
  if ! docker ps --all --no-trunc --filter "label=org.robotics.build.owner=${scope}" --format '{{.ID}}' >"${output}/cleanup-remaining.txt"; then
    cleanup_status=1
  elif [[ -s "${output}/cleanup-remaining.txt" ]]; then
    printf 'owned containers remain; build directories retained\n' >&2
    cleanup_status=1
  fi
  if ${has_claim} && ((cleanup_status == 0)) && [[ -e "${tool_root}" || -L "${tool_root}" ]]; then
    if [[ -L "${tool_root}" || "$(realpath -e -- "${tool_root}")" != "${tool_root}" ||
          "$(stat -c '%d:%i' "${tool_root}")" != "$(cat "${claim}/tool-root-id")" ]]; then
      printf 'unclaimed or aliased build directory retained: %s\n' "${tool_root}" >&2
      cleanup_status=65
    else
      if [[ -d "${context}/metadata" ]]; then
        mkdir -p "${output}/source-metadata"
        cp -a "${context}/metadata/." "${output}/source-metadata/" || cleanup_status=1
      fi
      if [[ -f "${context}/source-sdk-lock.json" ]]; then
        cp "${context}/source-sdk-lock.json" "${output}/source-sdk-lock.json" || cleanup_status=1
      fi
      if ((cleanup_status == 0)); then rm -rf -- "${tool_root}" || cleanup_status=1; fi
    fi
  fi
  if ${has_claim}; then
    image_filters+=(--filter "reference=${worker_tag}")
    if [[ -f "${output}/dependency-registry-tag.txt" ]]; then
      registry_tag="$(cat "${output}/dependency-registry-tag.txt")"
      if [[ "${registry_tag}" =~ ^127\.0\.0\.1:[0-9]+/px4-deps:${scope}$ ]]; then
        image_filters+=(--filter "reference=${registry_tag}")
      else
        printf 'refusing unexpected dependency registry tag\n' >&2
        cleanup_status=65
      fi
    fi
  fi
  if ! docker image ls --no-trunc "${image_filters[@]}" --format '{{json .}}' >"${output}/cleanup-images.jsonl"; then
    cleanup_status=1
  elif python3 - "${output}" "${deps_tag}" "${worker_tag}" "${has_claim}" >"${output}/cleanup-image-tags" <<'PY'
import json
import sys
from pathlib import Path
output = Path(sys.argv[1])
expected = {sys.argv[2]: None}
deps = output / "dependency-image.json"
if sys.argv[4] == "true" and deps.is_file():
    expected[sys.argv[2]] = json.loads(deps.read_text())[0]["Id"]
    registry = output / "dependency-registry-tag.txt"
    if registry.is_file():
        expected[registry.read_text().strip()] = expected[sys.argv[2]]
worker = output / "images.json"
if sys.argv[4] == "true" and worker.is_file():
    expected[sys.argv[3]] = json.loads(worker.read_text())[1]["Id"]
for line in (output / "cleanup-images.jsonl").read_text().splitlines():
    row = json.loads(line)
    tag = row["Repository"] + ":" + row["Tag"]
    if tag not in expected:
        continue
    if expected[tag] is not None and row["ID"] != expected[tag]:
        print("refusing changed image tag: " + tag, file=sys.stderr)
        sys.exit(65)
    print(tag + "\t" + row["ID"])
PY
  then
    while IFS=$'\t' read -r tag image_id; do
      if ! observed="$(docker image inspect --format '{{.Id}}' "${tag}")"; then
        cleanup_status=1
        continue
      fi
      if [[ "${observed}" != "${image_id}" ]]; then
        cleanup_status=65
        continue
      fi
      if [[ "${tag}" == "${deps_tag}" ]]; then
        if ! owner_label="$(docker image inspect --format '{{index .Config.Labels "org.robotics.build.owner"}}' "${image_id}")"; then
          cleanup_status=1
          continue
        fi
        if [[ "${owner_label}" != "${scope}" ]]; then
          printf 'refusing unowned dependency image tag: %s\n' "${tag}" >&2
          cleanup_status=65
          continue
        fi
      fi
      docker image rm --no-prune "${tag}" > /dev/null || cleanup_status=1
    done <"${output}/cleanup-image-tags"
  else
    cleanup_status=$?
  fi
  if ((cleanup_status == 1)); then observed=unknown; else observed=${cleanup_status}; fi
  printf '%s\n' "${observed}" >"${output}/cleanup.exit"
  ((status != 0)) || status=${cleanup_status}
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "${1:-}" == --cleanup ]]; then exit 0; fi

test "$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')" = linux/amd64
docker version >"${output}/docker-version.txt"
docker buildx version >"${output}/buildx-version.txt"
deps_image="$(docker image inspect --format '{{.Id}}' "${deps_tag}")"
docker inspect "${deps_image}" >"${output}/dependency-image.json"
[[ "${deps_image}" =~ ^sha256:[a-f0-9]{64}$ ]]
registry_container="$(docker run --detach --name "${scope}-registry" \
  --label "org.robotics.build.owner=${scope}" --publish 127.0.0.1::5000 \
  docker.io/library/registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e)"
port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "5000/tcp") 0).HostPort}}' "${registry_container}")"
[[ "${port}" =~ ^[0-9]+$ ]]
registry="127.0.0.1:${port}"
curl --fail --silent --show-error --max-time 3 --retry 10 --retry-connrefused \
  --retry-delay 1 --retry-all-errors "http://${registry}/v2/" >"${output}/registry-ready.json"
deps_reference="${registry}/px4-deps:${scope}"
printf '%s\n' "${deps_reference}" >"${output}/dependency-registry-tag.txt"
docker tag "${deps_image}" "${deps_reference}"
docker push "${deps_reference}" >"${output}/dependency-push.log"
deps_reference="$(docker image inspect "${deps_reference}" | python3 -c \
  'import json,sys; refs=[v for v in json.load(sys.stdin)[0]["RepoDigests"] if v.startswith(sys.argv[1]+"@sha256:")]; assert len(refs)==1; print(refs[0])' "${registry}/px4-deps")"
docker pull "${deps_reference}" >"${output}/dependency-pull.log"
test "$(docker image inspect --format '{{.Id}}' "${deps_reference}")" = "${deps_image}"

readarray -t sdk < <(python3 - <<'PY'
import json
from pathlib import Path
lock = json.loads(Path("host/workers/px4/mavsdk-source-lock.json").read_text())
print(lock["sdk"]["repository"])
print(lock["sdk"]["tag"])
PY
)
sdk_source="${tool_root}/MAVSDK-v4.2.0"
git clone --depth=1 --single-branch --branch "${sdk[1]}" "${sdk[0]}" "${sdk_source}"
PX4_CONTAINER_ENGINE=docker PX4_DEPS_IMAGE="${deps_reference}" \
  PX4_SOURCE_ROOT="${tool_root}/PX4-Autopilot" PX4_BUILD_OWNER="${scope}" \
  bash host/tools/build-px4-stock.sh
python3 -B host/tools/prepare-px4-image.py \
  --engine docker --controller native-python-source \
  --source "${tool_root}/PX4-Autopilot" --sdk-source "${sdk_source}" \
  --deps-image "${deps_reference}" --context-parent "${tool_root}" \
  --context-name "${context_name}" --tag "${worker_tag}"
worker_image="$(cat "${context}/image-id.txt")"
[[ "${worker_image}" =~ ^sha256:[a-f0-9]{64}$ ]]
docker image inspect "${deps_image}" "${worker_image}" >"${output}/images.json"
cp -a "${context}/metadata" "${output}/source-metadata"
cp "${context}/source-sdk-lock.json" "${output}/source-sdk-lock.json"

inspection_container="$(docker create --name "${scope}-inspection" \
  --label "org.robotics.build.owner=${scope}" --network none --read-only \
  --entrypoint /bin/true "${worker_image}")"
docker cp "${inspection_container}:/usr/share/robotics-px4/sdk-source" "${output}/sdk-source"
docker rm "${inspection_container}" > /dev/null
inspection_container=
python3 - "${output}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
output = Path(sys.argv[1])
lock = json.loads((output / "source-sdk-lock.json").read_text())
for kind in ("build", "runtime"):
    expected = lock["apt_closure"][kind]
    for filename, key in (
        (f"{kind}-apt-closure.tsv", "inventory_sha256"),
        (f"{kind}-debs.tsv", "deb_manifest_sha256"),
    ):
        path = output / "sdk-source" / filename
        assert hashlib.sha256(path.read_bytes()).hexdigest() == expected[key], filename
assert (output / "sdk-source/runtime-pip-check.txt").read_text().strip() == "No broken requirements found."
PY
failed=0
scripts/ci/security/scan-image.sh "${deps_image}" px4-deps linux/amd64 || failed=1
scripts/ci/security/scan-image.sh "${worker_image}" px4-worker linux/amd64 || failed=1
exit "${failed}"
