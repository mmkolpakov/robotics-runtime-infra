#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${root}"
: "${GITHUB_RUN_ID:?CI run identity required}"
: "${GITHUB_RUN_ATTEMPT:?CI attempt identity required}"
scope="px4-source-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
output="${root}/artifacts/${scope}"
mkdir -p "${output}" "${root}/host/.tools"
deps_tag="local/robotics-px4-deps:${scope}"
worker_tag="local/robotics-px4-worker:${scope}"
inspection_container=
registry_container=
# shellcheck disable=SC2329
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "${inspection_container}" ]]; then
    docker rm "${inspection_container}" > /dev/null || status=1
  fi
  if [[ -n "${registry_container}" ]]; then
    docker rm --force --volumes "${registry_container}" > /dev/null || status=1
  fi
  exit "${status}"
}
trap cleanup EXIT

test "$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')" = linux/amd64
docker version >"${output}/docker-version.txt"
docker buildx version >"${output}/buildx-version.txt"
deps_image="$(docker image inspect --format '{{.Id}}' "${deps_tag}")"
docker inspect "${deps_image}" >"${output}/dependency-image.json"
[[ "${deps_image}" =~ ^sha256:[a-f0-9]{64}$ ]]
registry_container="$(docker run --detach --name "${scope}-registry" \
  --label "org.robotics.runtime.run-id=${scope}" --publish 127.0.0.1::5000 \
  docker.io/library/registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e)"
port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "5000/tcp") 0).HostPort}}' "${registry_container}")"
[[ "${port}" =~ ^[0-9]+$ ]]
registry="127.0.0.1:${port}"
curl --fail --silent --show-error --max-time 3 --retry 10 --retry-connrefused \
  --retry-delay 1 --retry-all-errors "http://${registry}/v2/" >"${output}/registry-ready.json"
deps_reference="${registry}/px4-deps:${scope}"
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
sdk_source="${root}/host/.tools/MAVSDK-v4.2.0"
git clone --depth=1 --single-branch --branch "${sdk[1]}" "${sdk[0]}" "${sdk_source}"
PX4_CONTAINER_ENGINE=docker PX4_DEPS_IMAGE="${deps_reference}" \
  bash host/tools/build-px4-stock.sh
context_name="px4-image-${scope}"
python3 -B host/tools/prepare-px4-image.py \
  --engine docker --controller native-python-source \
  --source "${root}/host/.tools/PX4-Autopilot" --sdk-source "${sdk_source}" \
  --deps-image "${deps_reference}" --context-name "${context_name}" --tag "${worker_tag}"
worker_image="$(cat "${root}/host/.tools/${context_name}/image-id.txt")"
[[ "${worker_image}" =~ ^sha256:[a-f0-9]{64}$ ]]
docker image inspect "${deps_image}" "${worker_image}" >"${output}/images.json"
cp -a "${root}/host/.tools/${context_name}/metadata" "${output}/source-metadata"
cp "${root}/host/.tools/${context_name}/source-sdk-lock.json" "${output}/source-sdk-lock.json"

inspection_container="$(docker create --network none --read-only \
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
