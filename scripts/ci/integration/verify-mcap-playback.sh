#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"
# shellcheck source=scripts/ci/lib.sh
source "${root}/scripts/ci/lib.sh"
# shellcheck source=scripts/ci/image-identity.sh
source "${root}/scripts/ci/image-identity.sh"
# shellcheck source=scripts/ci/foundation/released-mode.sh
source "${root}/scripts/ci/foundation/released-mode.sh"

retain_inputs() {
  local model="$1" run_dir="$2" dataset bag qos
  # Native paths are data: preserve terminal newlines instead of trimming them.
  IFS= read -r -d '' dataset < <(jq -j '(.services.playback.volumes[] |
    select(.target == "/datasets") | .source), "\u0000"' "${model}")
  IFS= read -r -d '' bag < <(jq -j '(.services.playback.command |
    .[index("--input") + 1]), "\u0000"' "${model}")
  IFS= read -r -d '' qos < <(jq -j '(.services.playback.volumes[] |
    select(.target == "/etc/robotics/playback") | .source), "\u0000"' "${model}")
  [[ "${bag}" == /datasets || "${bag}" == /datasets/* ]]
  IFS= read -r -d '' dataset < <(realpath -e --zero -- "${dataset}")
  if [[ "${bag}" == /datasets ]]; then
    bag="${dataset}"
  else
    IFS= read -r -d '' bag < <(realpath -e --zero -- "${dataset}/${bag#/datasets/}")
  fi
  [[ ( "${bag}" == "${dataset}" || "${bag}" == "${dataset}/"* ) && -d "${bag}" ]]
  [[ -z "$(find "${bag}" "${qos}" ! -type d ! -type f -print -quit)" ]]
  mkdir -p "${run_dir}/source" "${run_dir}/configuration" "${run_dir}/logs"
  cp -R -- "${bag}" "${run_dir}/source/bag"
  cp -R -- "${qos}" "${run_dir}/source/qos"
  cp -- "${root}/config/qualification/recorded-playback.json" "${run_dir}/profile.json"
  local path relative digest size
  while IFS= read -r -d '' path; do
    relative="${path#"${run_dir}/"}"
    digest="$(sha256sum "${path}" | cut -d' ' -f1)"
    size="$(stat -c '%s' "${path}")"
    jq -cn --arg path "${relative}" --arg sha256 "${digest}" --argjson size "${size}" \
      '{path: $path, sha256: $sha256, size_bytes: $size}'
  done < <(find "${run_dir}/source" -type f -print0 | sort -z) >"${run_dir}/configuration/sources.jsonl"
}

publish_manifest() {
  local run_dir="$1" run_id="$2" subject_digest="$3"
  local manifest_run=(
    "${compose[@]}" run --rm --no-deps --pull never
    --user "$(id -u):$(id -g)"
    -e ROBOTICS_INFRA_REVISION="${ROBOTICS_RELEASE_SOURCE_SHA:-${GITHUB_SHA:-$(git rev-parse HEAD)}}"
    -e ROBOTICS_HOST_PLATFORM_FILE=/run/robotics/configuration/host-platform.json
    -e ROBOTICS_PROVIDER_BINDINGS_FILE=/run/robotics/provider-bindings.json
  )
  "${manifest_run[@]}" \
    --volume "${root}/scripts/ci/integration/create-playback-provider.py:/tmp/create-playback-provider.py:ro" \
    runtime-manifest /opt/contracts/bin/python /tmp/create-playback-provider.py \
    --run-dir /run/robotics --host-run-dir "${run_dir}" --run-id "${run_id}" \
    --subject-digest "${subject_digest}" --output /run/robotics/conformance-result.json \
    >"${run_dir}/provider-bindings.json"
  "${manifest_run[@]}" runtime-manifest
  "${manifest_run[@]}" runtime-manifest robotics-contracts validate --quiet \
    /run/robotics/runtime-manifest.json /run/robotics/conformance-result.json /run/robotics/profile.json
  # File URIs describe this retained host directory, not a download API.
  # Check raw references after emission and before project cleanup.
  "${manifest_run[@]}" runtime-manifest /opt/contracts/bin/python - /run/robotics "${run_dir}" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

root = Path(sys.argv[1])
host = Path(sys.argv[2])
manifest = json.loads((root / "runtime-manifest.json").read_bytes())
result = json.loads((root / "conformance-result.json").read_bytes())
binding = manifest["provider_bindings"][0]
for field, path in (
    ("qualification_profile_sha256", "profile.json"),
    ("conformance_result_sha256", "conformance-result.json"),
):
    if binding[field] != hashlib.sha256((root / path).read_bytes()).hexdigest():
        raise SystemExit("playback profile/result binding differs from retained bytes")
if (binding["provider"] != result["provider"]
    or binding["capabilities"] != ["playback_probe_delivery"]
    or result["execution_subject_digest"] != manifest["execution_subject"]["digest"]
    or result["provider"]["configuration_sha256"] != hashlib.sha256(
        (root / "configuration/provider.json").read_bytes()).hexdigest()):
    raise SystemExit("playback manifest differs from retained provider result")
for ref in result["evidence"]:
    uri = urlparse(ref["uri"])
    if uri.scheme != "file" or uri.netloc:
        raise SystemExit("playback evidence must identify retained local files")
    path = root / Path(unquote(uri.path)).relative_to(host)
    with path.open("rb") as stream:
        size = os.fstat(stream.fileno()).st_size
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if size != ref["size_bytes"] or digest != ref["sha256"]:
        raise SystemExit("playback retained evidence differs from its digest/size")
PY
}


observe_player_exit() {
  local id="$1" run_dir="$2" project="$3" image="$4" deadline="$5"
  local started settled client_status log_status=0
  [[ "$id" =~ ^[a-f0-9]{64}$ && "$deadline" =~ ^[1-9][0-9]{0,2}$ ]] || return 64
  ((deadline <= 300)) || return 64
  docker inspect "$id" >"$run_dir/player-before-wait.json"
  jq -e --arg id "$id" --arg project "$project" --arg image "$image" '
    length == 1 and (.[0] | .Id == $id and .Image == $image and
      .Config.Labels["com.docker.compose.project"] == $project and
      .Config.Labels["com.docker.compose.service"] == "playback" and
      .RestartCount == 0 and .State.OOMKilled == false and
      (.State.Status == "running" or .State.Status == "exited"))
  ' "$run_dir/player-before-wait.json" >/dev/null
  started="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
  if timeout --foreground "$deadline" docker wait "$id" >"$run_dir/player-wait.stdout" 2>"$run_dir/player-wait.stderr"; then
    client_status=0
  else
    client_status=$?
  fi
  settled="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
  docker inspect "$id" >"$run_dir/player-after-wait.json"
  docker logs "$id" >"$run_dir/logs/playback-player.log" 2>&1 || log_status=$?
  jq -n --arg id "$id" --arg project "$project" --arg mode "$ROBOTICS_RUNTIME_MODE" \
    --arg tooling "$(git rev-parse HEAD)" --arg started "$started" --arg settled "$settled" \
    --argjson deadline "$deadline" --argjson client "$client_status" --argjson logs "$log_status" \
    --arg output "$(cat "$run_dir/player-wait.stdout")" \
    '{container_id:$id,project:$project,runtime_mode:$mode,tooling_revision:$tooling,
      started_at:$started,settled_at:$settled,deadline_seconds:$deadline,
      command:["timeout","--foreground",($deadline|tostring),"docker","wait",$id],
      wait_client_exit_code:$client,reported_player_exit_code:$output,
      player_logs_exit_code:$logs,stop_requested_before_wait:false}' >"$run_dir/player-terminal.json"
  ((client_status == 0)) || return "$client_status"
  ((log_status == 0)) || return "$log_status"
  [[ "$(cat "$run_dir/player-wait.stdout")" == 0 ]]
  jq -e --arg id "$id" --arg image "$image" \
    --slurpfile before "$run_dir/player-before-wait.json" '
      length == 1 and (.[0] | .Id == $id and .Image == $image and
        .Config == $before[0][0].Config and .RestartCount == 0 and
        .State.Status == "exited" and .State.Running == false and
        .State.ExitCode == 0 and .State.OOMKilled == false and .State.Dead == false)
    ' "$run_dir/player-after-wait.json" >/dev/null
}


run_case() (
  local name="$1" domain_id="$2" expect_failure="$3"
  local project="playback-${name}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"
  local artifact_root="${ROBOTICS_PLAYBACK_ARTIFACT_ROOT:-${root}/artifacts/runtime/playback}"
  mkdir -p -- "${artifact_root}"
  local run_dir
  run_dir="$(mktemp -d "$(realpath -- "${artifact_root}")/${name}.XXXXXX")"
  local compose=(
    docker compose -p "${project}" -f compose.yaml -f compose.playback.yaml
    --profile playback --profile test --profile acceptance
  )
  local acquired=false
  trap 'if [[ "$acquired" == true ]]; then "${compose[@]}" down --volumes --remove-orphans >"${run_dir}/logs/cleanup.log" 2>&1 || true; fi' EXIT
  mkdir "${run_dir}/logs"
  foundation_prepare_execution_mode "${ROBOTICS_FOUNDATION_CONSUMER_ROOT:-${root}}" "${run_dir}/release"
  local mode="${ROBOTICS_RUNTIME_MODE:-source}"
  if [[ "${mode}" == released ]]; then
    foundation_prepare_released_image "${EDGE_IMAGE}"
    compose=(docker compose -p "${project}" --env-file "${ROBOTICS_RELEASE_LOCK_SNAPSHOT}"
      -f compose.yaml -f compose.playback.yaml -f compose.released.yaml
      --profile playback --profile test --profile acceptance)
  fi
  export ROS_DOMAIN_ID="${domain_id}"
  if ((expect_failure)); then
    export ROBOTICS_PLAYBACK_READINESS_TOPIC=/never_present
    export ROBOTICS_PLAYBACK_READY_TIMEOUT_SEC=2
    export ROBOTICS_PLAYBACK_PROBE_TIMEOUT_SEC=4
  fi
  "${compose[@]}" config --format json >"${run_dir}/compose-original.json"
  retain_inputs "${run_dir}/compose-original.json" "${run_dir}"
  ci_image_identity "$(jq -er '.services.playback.image' "${run_dir}/compose-original.json")" "${mode}" \
    >"${run_dir}/playback-image.json"
  ci_image_identity "$(jq -er '.services["playback-probe"].image' "${run_dir}/compose-original.json")" "${mode}" \
    >"${run_dir}/probe-image.json"
  local playback_image probe_image version run_id
  playback_image="$(jq -er '.local_image_id' "${run_dir}/playback-image.json")"
  probe_image="$(jq -er '.local_image_id' "${run_dir}/probe-image.json")"
  # Observe the native version before the short playback process can exit.
  docker run --rm --pull never "${playback_image}" ros2 pkg xml rosbag2_transport --tag version \
    >"${run_dir}/configuration/rosbag2-version.txt"
  version="$(cat "${run_dir}/configuration/rosbag2-version.txt")"
  if [[ "${mode}" == source ]]; then
    export SIMULATION_IMAGE="${playback_image}" EDGE_IMAGE="${probe_image}"
  fi
  export ROBOTICS_RUN_DIR="${run_dir}" ROBOTICS_DATASET_DIR="${run_dir}/source"
  export ROBOTICS_PLAYBACK_BAG=/datasets/bag ROBOTICS_PLAYBACK_CONFIG_DIR="${run_dir}/source/qos"
  export ROBOTICS_SIMULATION_OCI_REFERENCE ROBOTICS_SIMULATION_OCI_DIGEST
  ROBOTICS_SIMULATION_OCI_REFERENCE="$(jq -er '.reference' "${run_dir}/playback-image.json")"
  ROBOTICS_SIMULATION_OCI_DIGEST="$(jq -er '.digest' "${run_dir}/playback-image.json")"
  "${compose[@]}" config --format json >"${run_dir}/compose.json"
  jq -n --arg version "${version}" --arg playback "${playback_image}" --arg probe "${probe_image}" \
    --slurpfile model "${run_dir}/compose.json" \
    --slurpfile sources "${run_dir}/configuration/sources.jsonl" \
    '{version: $version, expected_playback_image_id: $playback, expected_probe_image_id: $probe,
      playback_command: $model[0].services.playback.command,
      terminal_observation: "native-player-exit",
      gate_command: $model[0].services["playback-gate"].command,
      probe_command: $model[0].services["playback-probe"].command, sources: $sources}' \
    >"${run_dir}/configuration/provider.json"
  python3 - >"${run_dir}/configuration/host-platform.json" <<'PY'
import json
import platform
values = platform.freedesktop_os_release()
print(json.dumps({"os": values["ID"], "os_version": values["VERSION_ID"],
                  "architecture": platform.machine(), "kernel": platform.release()}))
PY
  run_id="$(python3 -c 'import uuid; print("run-" + str(uuid.uuid4()))')"
  acquired=true
  "${compose[@]}" up --no-build --pull never --detach playback playback-gate playback-probe
  "${compose[@]}" wait playback-gate playback-probe || true
  local playback_id gate_id probe_id gate_status probe_status actual_playback actual_gate actual_probe
  playback_id="$("${compose[@]}" ps --all --quiet playback)"
  gate_id="$("${compose[@]}" ps --all --quiet playback-gate)"
  probe_id="$("${compose[@]}" ps --all --quiet playback-probe)"
  [[ -n "${playback_id}" && -n "${gate_id}" && -n "${probe_id}" ]]
  gate_status="$(docker inspect --format '{{.State.ExitCode}}' "${gate_id}")"
  probe_status="$(docker inspect --format '{{.State.ExitCode}}' "${probe_id}")"
  actual_playback="$(docker inspect --format '{{.Image}}' "${playback_id}")"
  actual_gate="$(docker inspect --format '{{.Image}}' "${gate_id}")"
  actual_probe="$(docker inspect --format '{{.Image}}' "${probe_id}")"
  local gate_log_status=0 probe_log_status=0
  docker logs "${gate_id}" >"${run_dir}/logs/playback-gate.log" 2>&1 || gate_log_status=$?
  docker logs "${probe_id}" >"${run_dir}/logs/playback-probe.log" 2>&1 || probe_log_status=$?
  jq -n --argjson gate "${gate_status}" --argjson probe "${probe_status}" \
    --argjson gate_logs "${gate_log_status}" --argjson probe_logs "${probe_log_status}" \
    --arg playback_image "${actual_playback}" --arg gate_image "${actual_gate}" \
    --arg probe_image "${actual_probe}" \
    --arg log_sha256 "$(sha256sum "${run_dir}/logs/playback-probe.log" | cut -d' ' -f1)" \
    '{gate_exit_code: $gate, probe_exit_code: $probe, gate_logs_exit_code: $gate_logs,
      probe_logs_exit_code: $probe_logs, playback_image_id: $playback_image,
      gate_image_id: $gate_image, probe_image_id: $probe_image, probe_log_sha256: $log_sha256}' \
    >"${run_dir}/observation.json"
  if ((expect_failure)); then
    test "${gate_status}" -eq 1
    test "${probe_status}" -eq 124
  else
    test "${gate_status}" -eq 0
    test "${probe_status}" -eq 0
  fi
  ((gate_log_status == 0)) || return "${gate_log_status}"
  ((probe_log_status == 0)) || return "${probe_log_status}"
  [[ "${actual_playback}" == "${playback_image}" && "${actual_gate}" == "${playback_image}" &&
    "${actual_probe}" == "${probe_image}" ]]
  if ((expect_failure)); then
    grep -Eq '^data:' "${run_dir}/logs/playback-probe.log" && return 1
    printf 'playback timeout fixture failed closed\n'
  else
    grep -Eq '^data:' "${run_dir}/logs/playback-probe.log"
    observe_player_exit "${playback_id}" "${run_dir}" "${project}" "${playback_image}" "${ROBOTICS_PLAYBACK_PROBE_TIMEOUT_SEC:-75}"
    publish_manifest "${run_dir}" "${run_id}" "${ROBOTICS_SIMULATION_OCI_DIGEST}"
  fi
)

run_case ready 87 0
run_case timeout 86 1
