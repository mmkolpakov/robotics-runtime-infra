#!/usr/bin/env bash
# Installed ROS lifecycle gates on the existing Linux/amd64 Docker runner.
set -Eeuo pipefail
shopt -s inherit_errexit
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"
node_image="docker.io/library/node@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697"
compose_sha="f9ebc6ebdb19d769b793c245a736caaeb198c62587f13b25c660c13b4987f959"
# Official library/registry metadata: https://hub.docker.com/v2/repositories/library/registry/tags/3.0.0
registry_image="docker.io/library/registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e"
compose=
for candidate in "${ROBOTICS_COMPOSE:-}" "$(command -v docker-compose || true)" \
  "${HOME}/.docker/cli-plugins/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose \
  /usr/libexec/docker/cli-plugins/docker-compose /usr/lib/docker/cli-plugins/docker-compose; do
  if [[ -f "${candidate}" && "$(sha256sum "${candidate}" | cut -d ' ' -f 1)" == "${compose_sha}" ]]; then
    compose="${candidate}"
    break
  fi
done
[[ -n "${compose}" && "$("${compose}" version --short)" == 5.3.1 ]] || exit 65
if [[ -n "${GITHUB_ENV:-}" ]]; then printf 'ROBOTICS_COMPOSE=%s\n' "${compose}" >>"${GITHUB_ENV}"; fi
ROBOTICS_COMPOSE="${compose}" PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s host/test/fixtures/installed-legacy -p test_prepare.py -v
if [[ "${1:-}" == --check-config ]]; then exit 0; fi
[[ $# == 0 ]] || exit 64
[[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] || exit 69
scope="installed-ros-${GITHUB_RUN_ID:?CI run required}-${GITHUB_RUN_ATTEMPT:?CI attempt required}"
[[ "${GITHUB_RUN_ID}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT}" =~ ^[0-9]+$ ]] || exit 64
socket="${ROBOTICS_DOCKER_SOCKET:-/var/run/docker.sock}"
[[ "${socket}" == /* && -S "${socket}" ]] || exit 65
export DOCKER_HOST="unix://${socket}"
unset DOCKER_CONTEXT
[[ "$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')" == linux/amd64 ]] || exit 69
socket_gid="$(stat --format='%g' "${socket}")"
docker_cli="$(readlink -f "$(command -v docker)")"
output="${root}/artifacts/installed-ros/${scope}"
[[ ! -e "${output}" ]] || exit 65
mkdir -p "${output}"
work="$(mktemp -d "${RUNNER_TEMP:?CI temporary directory required}/installed-ros.${scope}.XXXXXXXX")"
registry_id=
copy_id=
builder=
builder_created=0
host_prefix=installed-ros-host-
project_prefix=rr-installed-ros-host-
capture_failure() {
  local record run owner volume role meta snapshot_id native_owner expected_project
  if [[ -d "${consumer:-${work}/consumer}" ]]; then
    cp --archive "${consumer:-${work}/consumer}" "${output}/generated-inputs" || \
      printf 'generated inputs copy failed\n' >>"${output}/diagnostic-errors.log"
  fi
  record="${output}/launcher/failure.json"
  if [[ ! -r "${record}" ]]; then record="${output}/launcher/installed-ros-public-report.json"; fi
  if [[ ! -r "${record}" ]]; then record="${output}/launcher/installed-negative-report.json"; fi
  if [[ -r "${record}" ]]; then
    run="$(python3 -c 'import json,re,sys; d=json.load(open(sys.argv[1])); r=d["runId"]; assert re.fullmatch(r"run-[a-f0-9-]{36}",r); assert d["project"]==sys.argv[2]+r[4:12]; print(r)' "${record}" "${project_prefix}")" || run=
    if [[ -n "${run}" ]]; then
      owner="${host_prefix}${run:4:8}"
      for role in runtime host; do
        if [[ "${role}" == runtime ]]; then native_owner="${run}"; else native_owner="${owner}"; fi
        docker ps --all --no-trunc --filter "label=org.robotics.runtime.run-id=${native_owner}" \
          --format '{{json .}}' >"${output}/failed-${role}-containers.jsonl" || \
          printf 'owned container inventory failed: %s\n' "${role}" >>"${output}/diagnostic-errors.log"
      done
      for role in source retained; do
        if [[ "${role}" == source ]]; then volume="${source_volume}"; else volume="${retained_volume}"; fi
        meta="${output}/failed-${role}-volume.json"
        if ! docker volume inspect "${volume}" >"${meta}" 2>>"${output}/diagnostic-errors.log"; then continue; fi
        expected_project=
        if [[ "${role}" == source ]]; then expected_project="${project_prefix}${run:4:8}"; fi
        if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d)==1; v=d[0]; assert v["Name"]==sys.argv[2]; assert v["Labels"]["org.robotics.runtime.run-id"]==sys.argv[3]; assert v["Labels"]["org.robotics.runtime.storage-owner"]==sys.argv[3]; assert not sys.argv[4] or v["Labels"]["com.docker.compose.project"]==sys.argv[4]' \
          "${meta}" "${volume}" "${owner}" "${expected_project}" 2>>"${output}/diagnostic-errors.log"; then continue; fi
        snapshot_id="$(docker create --label "org.robotics.runtime.run-id=${scope}" --network none --read-only \
          --mount "type=volume,source=${volume},target=/snapshot,readonly" "${node_image}")" || continue
        mkdir "${output}/failed-${role}-snapshot"
        timeout 120s docker cp "${snapshot_id}:/snapshot/." "${output}/failed-${role}-snapshot" || \
          printf 'owned snapshot copy failed: %s\n' "${role}" >>"${output}/diagnostic-errors.log"
        docker rm "${snapshot_id}" >/dev/null || \
          printf 'snapshot container cleanup failed: %s\n' "${snapshot_id}" >>"${output}/diagnostic-errors.log"
      done
    fi
  fi
  python3 -c 'import json,sys; from pathlib import Path; Path(sys.argv[1]).write_text(json.dumps({"status":"incomplete","diagnostic_only":True,"settlement":"not-established","qualification_pass":False,"original_exit_code":int(sys.argv[2]),"preserved_work":sys.argv[3]},indent=2)+"\n")' \
    "${output}/failure-snapshot.json" "${gate_status}" "${work}" || \
    printf 'incomplete snapshot marker failed\n' >>"${output}/diagnostic-errors.log"
}
cleanup() {
  local gate_status=$? cleanup_failed=0
  trap - EXIT
  set +e
  if [[ "${gate_status}" != 0 ]]; then capture_failure; fi
  if [[ -n "${copy_id}" ]]; then docker rm "${copy_id}" >/dev/null || cleanup_failed=1; fi
  if [[ "${builder_created}" == 1 ]]; then docker buildx rm "${builder}" >/dev/null || cleanup_failed=1; fi
  if [[ -n "${registry_id}" ]]; then
    docker logs "${registry_id}" >"${output}/registry.log" 2>&1 || true
    if [[ "$(docker inspect --format '{{index .Config.Labels "org.robotics.runtime.run-id"}}' "${registry_id}")" == "${scope}" ]]; then
      docker rm --force --volumes "${registry_id}" >/dev/null || cleanup_failed=1
    else
      printf 'registry cleanup ownership mismatch\n' >&2
      cleanup_failed=1
    fi
  fi
  if [[ "${gate_status}" == 0 && "${cleanup_failed}" == 0 ]]; then
    rm -rf -- "${work}"
  fi
  if [[ "${gate_status}" == 0 && "${cleanup_failed}" != 0 ]]; then gate_status=1; fi
  exit "${gate_status}"
}
trap cleanup EXIT
docker version >"${output}/docker-version.txt"
bash scripts/ci/host/build-assets.sh
asset="${root}/host/.tools/host-asset"
cp "${asset}/source-identity.json" "${output}/host-source-identity.json"
mkdir "${output}/packages"
cp "${asset}/core.tgz" "${asset}/infra.tgz" "${output}/packages/"
registry_id="$(docker run --detach --platform linux/amd64 --name "${scope}-registry" \
  --label "org.robotics.runtime.run-id=${scope}" --publish 127.0.0.1::5000 "${registry_image}")"
port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "5000/tcp") 0).HostPort}}' "${registry_id}")"
[[ "${port}" =~ ^[0-9]+$ ]] || exit 65
registry="127.0.0.1:${port}"
curl --fail --silent --show-error --max-time 3 --retry 10 --retry-connrefused --retry-delay 1 \
  "http://${registry}/v2/" >"${output}/registry-ready.json"
# Reuse the project image pin; configure only this owned BuildKit instance.
buildkit_image="$(python3 -c 'import re,sys; from pathlib import Path; values=re.findall(r"^\s*image=(moby/buildkit:[^\s]+@sha256:[a-f0-9]{64})\s*$",Path(sys.argv[1]).read_text(),re.M); assert len(values)==1; print(values[0])' \
  .github/actions/setup-buildx/action.yml)"
printf '[registry."%s"]\n  http = true\n' "${registry}" >"${work}/buildkitd.toml"
cp "${work}/buildkitd.toml" "${output}/buildkitd.toml"
builder="${scope}-builder"
docker buildx create --name "${builder}" --driver docker-container \
  --driver-opt "image=${buildkit_image}" --driver-opt network=host \
  --buildkitd-config "${work}/buildkitd.toml" >"${output}/builder-create.txt"
builder_created=1
docker buildx inspect "${builder}" --bootstrap >"${output}/docker-builder.txt"
grep -Eq '^Driver:[[:space:]]+docker-container$' "${output}/docker-builder.txt"
expected_buildkit_version="${buildkit_image#*:}"
expected_buildkit_version="${expected_buildkit_version%%@*}"
actual_buildkit_version="$(awk '$1 == "BuildKit" && $2 == "version:" {print $3}' "${output}/docker-builder.txt")"
[[ "${actual_buildkit_version}" == "${expected_buildkit_version}" ]] || exit 65
share_image() {
  local image="$1" role="$2" repository="${registry}/installed-ros/$2" before reference
  before="$(docker image inspect --format '{{.Id}}' "${image}")"
  docker tag "${image}" "${repository}:${scope}"
  docker push "${repository}:${scope}" >"${output}/${role}-push.log"
  reference="$(docker image inspect "${repository}:${scope}" | python3 -c \
    'import json,sys; rows=json.load(sys.stdin); refs=[r for r in rows[0]["RepoDigests"] if r.startswith(sys.argv[1]+"@sha256:")]; assert len(refs)==1; print(refs[0])' "${repository}")"
  [[ "${reference}" =~ @sha256:[a-f0-9]{64}$ ]] || return 65
  docker pull "${reference}" >"${output}/${role}-pull.log"
  [[ "$(docker image inspect --format '{{.Id}}' "${reference}")" == "${before}" ]] || return 65
  docker image inspect "${image}" "${reference}" >"${output}/${role}-images.json"
  printf '%s\n' "${reference}"
}
base="$(share_image "${SIMULATION_IMAGE:?foundation simulation image required}" simulation-base)"
wheels_tag="${registry}/installed-ros/foundation-wheels:${scope}"
docker buildx bake --builder "${builder}" --file docker-bake.hcl --load \
  --set 'simulation.platform=linux/amd64' --set 'simulation.target=foundation-wheels' \
  --set "simulation.tags=${wheels_tag}" simulation
wheels="$(share_image "${wheels_tag}" foundation-wheels)"
coordinator_tag="${registry}/installed-ros/coordinator:${scope}"
docker buildx build --builder "${builder}" --platform linux/amd64 --load --file docker/foundation-coordinator.Dockerfile \
  --build-arg "FOUNDATION_WHEELS_IMAGE=${wheels}" --build-arg "LEGACY_BASE_IMAGE=${base}" \
  --tag "${coordinator_tag}" .
simulation="$(share_image "${coordinator_tag}" coordinator)"
# This target carries the central Cosign version argument into the license stage.
docker buildx bake --builder "${builder}" --file docker-bake.hcl --allow "fs.write=${work}" \
  --set 'evidence-sink.platform=linux/amd64' --set 'evidence-sink.target=cosign-license' \
  --set "evidence-sink.output=type=local,dest=${work}/cosign-license" evidence-sink
finalizer_tag="${registry}/installed-ros/finalizer:${scope}"
docker buildx build --builder "${builder}" --platform linux/amd64 --load --file docker/legacy-finalizer.Dockerfile \
  --build-context "cosign-license=${work}/cosign-license" --build-arg "COORDINATOR_IMAGE=${simulation}" \
  --tag "${finalizer_tag}" .
finalizer="$(share_image "${finalizer_tag}" finalizer)"
evidence_tag="${registry}/installed-ros/evidence:${scope}"
docker buildx build --builder "${builder}" --platform linux/amd64 --load --file docker/evidence-source.Dockerfile \
  --build-arg "EVIDENCE_BASE_IMAGE=${finalizer}" --tag "${evidence_tag}" .
evidence="$(share_image "${evidence_tag}" evidence)"
simulation_id="$(docker image inspect --format '{{.Id}}' "${simulation}")"
consumer="${work}/consumer"
source_volume="rr-${scope}-source"
retained_volume="rr-${scope}-retained"
python3 host/test/fixtures/installed-legacy/prepare.py --engine docker \
  --repo "${root}" --consumer "${consumer}" --assets "${asset}" --deployment-revision "$(git rev-parse HEAD)" \
  --compose "${compose}" --simulation-image "${simulation}" --simulation-id "${simulation_id}" \
  --finalizer-image "${finalizer}" --evidence-image "${evidence}" \
  --source-volume "${source_volume}" --retained-volume "${retained_volume}" >"${output}/consumer-identity.json"
docker run --rm --user "$(id -u):$(id -g)" --env NPM_CONFIG_CACHE=/tmp/npm-cache \
  --mount "type=bind,source=${consumer},target=${consumer}" --workdir "${consumer}" "${node_image}" \
  npm install --package-lock-only --ignore-scripts --no-audit --no-fund
docker run --rm --user "$(id -u):$(id -g)" --env NPM_CONFIG_CACHE=/tmp/npm-cache \
  --mount "type=bind,source=${consumer},target=${consumer}" --workdir "${consumer}" "${node_image}" \
  npm ci --ignore-scripts --no-audit --no-fund
node_tag="${registry}/installed-ros/host:${scope}"
docker buildx build --builder "${builder}" --platform linux/amd64 --load --tag "${node_tag}" "${consumer}"
host_image="$(share_image "${node_tag}" host)"
docker run --rm --user "$(id -u):$(id -g)" --group-add "${socket_gid}" \
  --mount "type=bind,source=${consumer},target=${consumer}" \
  --mount "type=bind,source=${socket},target=${socket},readonly" \
  --mount "type=bind,source=${docker_cli},target=/usr/bin/docker,readonly" \
  --mount "type=bind,source=${output},target=${output}" --workdir "${consumer}" "${node_image}" \
  node "${consumer}/launch.mjs" "${consumer}" "${socket}" "${host_image}" "${output}/launcher" \
  >"${output}/installed-launch.log" 2>&1
owner="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["status"]=="passed"; print("installed-ros-host-"+d["runId"][4:12])' \
  "${output}/launcher/installed-ros-public-report.json")"
docker volume inspect "${retained_volume}" >"${output}/retained-volume.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d)==1; v=d[0]; assert v["Name"]==sys.argv[2]; assert v["Labels"]["org.robotics.runtime.run-id"]==sys.argv[3]; assert v["Labels"]["org.robotics.runtime.storage-owner"]==sys.argv[3]' \
  "${output}/retained-volume.json" "${retained_volume}" "${owner}"
copy_id="$(docker create --label "org.robotics.runtime.run-id=${scope}" --network none --read-only \
  --mount "type=volume,source=${retained_volume},target=/retained,readonly" "${node_image}")"
mkdir "${output}/retained"
docker cp "${copy_id}:/retained/." "${output}/retained"
docker rm "${copy_id}" >/dev/null
copy_id=
printf 'Installed ROS positive gate completed: %s\n' "${output}"

# Reuse the observed Docker cohort for actual installed lifecycle negatives.
positive_output="${output}"
host_prefix=installed-ros-negative-
project_prefix=rr-installed-ros-negative-
for negative_mode in startup-cancel foreign-cleanup cancel timeout; do
  output="${positive_output}/negative-${negative_mode}"
  mkdir "${output}"
  consumer="${work}/consumer-negative-${negative_mode}"
  source_volume="rr-${scope}-${negative_mode}-source"
  retained_volume="rr-${scope}-${negative_mode}-retained"
  python3 host/test/fixtures/installed-legacy/prepare.py --engine docker --negative-lifecycle \
    --repo "${root}" --consumer "${consumer}" --assets "${asset}" --deployment-revision "$(git rev-parse HEAD)" \
    --compose "${compose}" --simulation-image "${simulation}" --simulation-id "${simulation_id}" \
    --finalizer-image "${finalizer}" --evidence-image "${evidence}" \
    --source-volume "${source_volume}" --retained-volume "${retained_volume}" >"${output}/consumer-identity.json"
  docker run --rm --user "$(id -u):$(id -g)" --env NPM_CONFIG_CACHE=/tmp/npm-cache \
    --mount "type=bind,source=${consumer},target=${consumer}" --workdir "${consumer}" "${node_image}" \
    npm install --package-lock-only --ignore-scripts --no-audit --no-fund
  docker run --rm --user "$(id -u):$(id -g)" --env NPM_CONFIG_CACHE=/tmp/npm-cache \
    --mount "type=bind,source=${consumer},target=${consumer}" --workdir "${consumer}" "${node_image}" \
    npm ci --ignore-scripts --no-audit --no-fund
  negative_tag="${registry}/installed-ros/host-${negative_mode}:${scope}"
  docker buildx build --builder "${builder}" --platform linux/amd64 --load --tag "${negative_tag}" "${consumer}"
  negative_image="$(share_image "${negative_tag}" "host-${negative_mode}")"
  docker run --rm --user "$(id -u):$(id -g)" --group-add "${socket_gid}" \
    --mount "type=bind,source=${consumer},target=${consumer}" \
    --mount "type=bind,source=${socket},target=${socket},readonly" \
    --mount "type=bind,source=${docker_cli},target=/usr/bin/docker,readonly" \
    --mount "type=bind,source=${output},target=${output}" --workdir "${consumer}" "${node_image}" \
    node "${consumer}/negative-launch.mjs" "${consumer}" "${socket}" "${negative_image}" "${output}/launcher" "${negative_mode}" \
    >"${output}/installed-launch.log" 2>&1
  owner="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["status"]=="passed"; assert d["sourceVolumeRemoved"] is True; assert d["mode"]==sys.argv[2]; print("installed-ros-negative-"+d["runId"][4:12])' \
    "${output}/launcher/installed-negative-report.json" "${negative_mode}")"
  docker volume inspect "${retained_volume}" >"${output}/retained-volume.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d)==1; v=d[0]; assert v["Name"]==sys.argv[2]; assert v["Labels"]["org.robotics.runtime.run-id"]==sys.argv[3]; assert v["Labels"]["org.robotics.runtime.storage-owner"]==sys.argv[3]' \
    "${output}/retained-volume.json" "${retained_volume}" "${owner}"
  copy_id="$(docker create --label "org.robotics.runtime.run-id=${scope}" --network none --read-only \
    --mount "type=volume,source=${retained_volume},target=/retained,readonly" "${node_image}")"
  mkdir "${output}/retained"
  docker cp "${copy_id}:/retained/." "${output}/retained"
  docker rm "${copy_id}" >/dev/null
  copy_id=
done
output="${positive_output}"
printf 'Installed ROS lifecycle negative gates completed: %s\n' "${output}"
