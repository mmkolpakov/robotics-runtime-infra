#!/usr/bin/env bash

foundation_repository_root() (
  cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P
)

foundation_require_env() {
  local name

  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      printf 'required environment variable is unset: %s\n' "${name}" >&2
      return 1
    fi
  done
}

foundation_run_id() {
  if [[ -n "${ROBOTICS_FOUNDATION_RUN_ID:-}" ]]; then
    printf '%s\n' "${ROBOTICS_FOUNDATION_RUN_ID}"
  elif [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    printf '%s\n' "${GITHUB_RUN_ID}"
  else
    printf 'local-%s\n' "$$"
  fi
}

foundation_artifact_dir() {
  local root="$1"
  local project="$2"

  if [[ -n "${ROBOTICS_FOUNDATION_ARTIFACT_DIR:-}" ]]; then
    printf '%s\n' "${ROBOTICS_FOUNDATION_ARTIFACT_DIR}"
  elif [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    printf '%s/artifacts\n' "${root}"
  else
    printf '%s/artifacts/%s\n' "${root}" "${project}"
  fi
}

foundation_project_name() {
  local kind="$1"
  local run_id="$2"
  local run_attempt="$3"

  case "${kind}" in
    runtime)
      printf 'foundation-%s-%s\n' "${run_id}" "${run_attempt}"
      ;;
    acceptance)
      printf 'foundation-e2e-%s-%s\n' "${run_id}" "${run_attempt}"
      ;;
    *)
      printf 'unknown foundation project kind: %s\n' "${kind}" >&2
      return 2
      ;;
  esac
}

foundation_compose_cleanup() {
  local log_path="$1"
  local project="$2"
  shift 2

  foundation_compose_logs "${log_path}" "$@"
  foundation_cleanup_project "${project}" "$@"
}

foundation_compose_logs() {
  local log_path="$1"
  shift

  "$@" logs --no-color > "${log_path}" 2>&1 || true
}

foundation_compose_down() {
  local status=0

  "$@" down --volumes --remove-orphans || status=$?
  if ((status != 0)); then
    printf 'foundation cleanup: Compose down failed (%s):' "${status}" >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
  fi
  return "${status}"
}

foundation_cleanup_project() {
  local project="$1"
  local status=0
  local assertion_status=0
  shift

  foundation_compose_down "$@" || status=$?
  foundation_assert_project_clean "${project}" || assertion_status=$?
  if ((status != 0)); then
    return "${status}"
  fi
  return "${assertion_status}"
}

foundation_wait_for_clock() {
  local project="$1"

  docker compose -p "${project}" exec -T simulation \
    robotics-entrypoint timeout 20 ros2 topic echo \
    /clock rosgraph_msgs/msg/Clock --once
}

foundation_assert_project_clean() {
  local project="$1"
  local kind resources
  local status=0
  local -a command

  for kind in container network volume; do
    command=(docker "${kind}" ls --quiet)
    if [[ "${kind}" == container ]]; then
      command+=(--all)
    fi
    if ! resources="$("${command[@]}" \
      --filter "label=com.docker.compose.project=${project}")"; then
      printf 'foundation cleanup: %s inventory failed for project %s\n' \
        "${kind}" "${project}" >&2
      return 70
    fi
    if [[ -n "${resources}" ]]; then
      printf 'foundation cleanup: %s resources remain for project %s: %s\n' \
        "${kind}" "${project}" "${resources}" >&2
      status=1
    fi
  done
  return "${status}"
}

foundation_validate_document() {
  local python="$1"
  local document="$2"

  "${python}" -c \
    'import json, sys; from robotics_runtime_contracts import validate_document; validate_document(json.load(open(sys.argv[1], encoding="utf-8")))' \
    "${document}"
}

foundation_recording_duration() {
  local python="$1"
  local scenario="$2"

  "${python}" - "${scenario}" <<'PY'
import math
import sys

from robotics_runtime_contracts.serialization import load_mapping

duration = load_mapping(sys.argv[1])["evidence_policy"]["max_segment_duration_sec"]
# rosbag2 and the evidence sink accept whole seconds. Round down so a
# fractional scenario limit is never enlarged, and never emit 0 (unbounded).
if type(duration) not in (int, float) or not math.isfinite(duration) or duration < 1:
    sys.exit("foundation recording requires a finite segment duration of at least 1 second")
print(math.floor(duration))
PY
}

foundation_scenario_topics() {
  local python="$1"
  local scenario="$2"

  "${python}" - "${scenario}" <<'PY'
import json
import re
import sys

from robotics_runtime_contracts.serialization import load_mapping

scenario = load_mapping(sys.argv[1])
topics = scenario["evidence_policy"]["topics"]
if not topics or any(not isinstance(topic, str) or not topic for topic in topics):
    sys.exit("foundation recording requires declared evidence topics")
probes = [
    topic["name"]
    for topic in scenario.get("expected_ros_graph", {}).get("topics", [])
    if topic.get("type") == "std_msgs/msg/UInt64"
]
if len(probes) > 1:
    sys.exit("foundation supports one declared UInt64 probe topic")
# Earlier caller scenarios may declare only /clock while using the stock probe.
probe = probes[0] if probes else "/robotics/runtime_probe"
if probes and probe not in topics:
    sys.exit("the declared UInt64 probe must be an evidence topic")
print(json.dumps({
    "metrics_topic": probe,
    "record_regex": "^(" + "|".join(re.escape(topic) for topic in topics) + ")$",
}))
PY
}

foundation_consumer_file() {
  local consumer_root="$1"
  local path="$2"
  local resolved

  if [[ "${consumer_root}${path}" == *[$'\r\n\t']* ]]; then
    printf 'consumer artifact paths must not contain control characters\n' >&2
    return 64
  fi
  IFS= read -r -d '' consumer_root < <(realpath --zero -e "${consumer_root}") ||
    return 64
  if [[ "${path}" != /* ]]; then
    path="${consumer_root}/${path}"
  fi
  IFS= read -r -d '' resolved < <(realpath --zero -e "${path}") || return 64
  if [[ "${consumer_root}" == *[$'\r\n\t']* ]]; then
    printf 'consumer root must not contain control characters\n' >&2
    return 64
  fi
  case "${resolved}" in
    "${consumer_root}"/*) ;;
    *)
      printf 'consumer artifact file is outside its repository: %s\n' "${path}" >&2
      return 64
      ;;
  esac
  if [[ ! -f "${resolved}" || ! -r "${resolved}" ||
        "${resolved}" == *[$'\r\n\t']* ]]; then
    printf 'consumer artifact is not a readable regular file: %s\n' "${resolved}" >&2
    return 64
  fi
  printf '%s\n' "${resolved}"
}

# Populate an argument vector; the public contracts CLI owns kind/schema validation.
# shellcheck disable=SC2034
foundation_load_artifact_arguments() {
  local consumer_root="$1"
  local arguments_file="$2"
  local option specification header path
  FOUNDATION_ARTIFACT_ARGUMENTS=()
  FOUNDATION_ARTIFACT_SOURCE_ARGUMENTS=()
  FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS=()
  FOUNDATION_EXTENSION_SCHEMA_DIRECTORY=''
  [[ -n "${arguments_file}" ]] || return 0
  arguments_file="$(foundation_consumer_file "${consumer_root}" "${arguments_file}")" ||
    return 64
  consumer_root="$(realpath -e -- "${consumer_root}")" || return 64
  while IFS= read -r option || [[ -n "${option}" ]]; do
    case "${option}" in
      --artifact|--extension-schema) ;;
      *)
        printf 'unsupported consumer artifact argument: %s\n' "${option}" >&2
        return 64
        ;;
    esac
    specification=''
    if ! IFS= read -r specification && [[ -z "${specification}" ]]; then
      printf 'consumer artifact argument requires a value: %s\n' "${option}" >&2
      return 64
    fi
    if [[ "${specification}" != *=* ]]; then
      printf 'consumer artifact argument requires NAME=PATH: %s\n' "${option}" >&2
      return 64
    fi
    header="${specification%%=*}"
    path="${specification#*=}"
    [[ -n "${header}" && -n "${path}" ]] || return 64
    if [[ "${path}" == /* ]]; then
      FOUNDATION_ARTIFACT_SOURCE_ARGUMENTS+=("${option}" "${header}=${path}")
    else
      FOUNDATION_ARTIFACT_SOURCE_ARGUMENTS+=("${option}" "${header}=${consumer_root}/${path}")
    fi
    path="$(foundation_consumer_file "${consumer_root}" "${path}")" || return 64
    FOUNDATION_ARTIFACT_ARGUMENTS+=("${option}" "${header}=${path}")
    if [[ "${option}" == --extension-schema ]]; then
      FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS+=(--extension-schema "${header}=${path}")
    fi
  done <"${arguments_file}"
}


# Preserve caller schema bytes once for every host and container CLI invocation.
foundation_stage_extension_schemas() {
  local run_root="$1" index specification uri source digest destination
  FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS=()
  FOUNDATION_EXTENSION_SCHEMA_DIRECTORY=''
  for ((index=0; index<${#FOUNDATION_ARTIFACT_ARGUMENTS[@]}; index+=2)); do
    [[ "${FOUNDATION_ARTIFACT_ARGUMENTS[index]}" == --extension-schema ]] || continue
    if [[ -z "${FOUNDATION_EXTENSION_SCHEMA_DIRECTORY}" ]]; then
      run_root="$(realpath -e -- "${run_root}")" || return 64
      FOUNDATION_EXTENSION_SCHEMA_DIRECTORY="${run_root}/configuration/extension-schemas"
      mkdir -p -- "${FOUNDATION_EXTENSION_SCHEMA_DIRECTORY}" || return "$?"
    fi
    specification="${FOUNDATION_ARTIFACT_ARGUMENTS[index+1]}"
    uri="${specification%%=*}"
    source="${specification#*=}"
    digest="$(sha256sum -- "${source}" | cut -d' ' -f1)" || return "$?"
    destination="${FOUNDATION_EXTENSION_SCHEMA_DIRECTORY}/${digest}.json"
    install -m 0444 -- "${source}" "${destination}" || return "$?"
    [[ "$(sha256sum -- "${destination}" | cut -d' ' -f1)" == "${digest}" ]] || {
      printf 'caller extension schema changed while staging\n' >&2
      return 65
    }
    FOUNDATION_ARTIFACT_ARGUMENTS[index+1]="${uri}=${destination}"
    FOUNDATION_ARTIFACT_SOURCE_ARGUMENTS[index+1]="${uri}=${destination}"
    FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS+=(--extension-schema "${uri}=${destination}")
  done
}

# Compose owns argv and read-only mount merging; no shell command is generated.
foundation_schema_observer_override() {
  local model="$1" service="$2" input_root="$3" output="$4" index specification
  local -a arguments=()
  [[ "${input_root}" == /run/robotics || "${input_root}" == /input ]] || return 64
  [[ "${service}" == acceptance-observer || "${service}" == edge-attach-observer ]] || return 64
  for ((index=1; index<${#FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS[@]}; index+=2)); do
    specification="${FOUNDATION_EXTENSION_SCHEMA_ARGUMENTS[index]}"
    arguments+=(--extension-schema "${specification%%=*}=${input_root}/configuration/extension-schemas/${specification##*/}")
  done
  ((${#arguments[@]})) || return 0
  jq -e --arg service "${service}" --arg source "${FOUNDATION_EXTENSION_SCHEMA_DIRECTORY}" \
    --arg target "${input_root}/configuration/extension-schemas" --args '
      .services[$service].command as $command |
      if ($command | type) != "array" or $command[0:2] != ["robotics-acceptance", "verify"]
      then error("observer must use the public verify argv")
      else {services: {($service): {
        command: ($command + $ARGS.positional),
        volumes: [{type: "bind", source: $source, target: $target, read_only: true}]
      }}} end' -- "${arguments[@]}" <"${model}" >"${output}" || return "$?"
  chmod 0444 -- "${output}"
}


# Invoke only after successful native bundle verification on these same subjects.
foundation_explain_qualification() (
  local package="$1" output="$2" desired="$3"
  shift 3
  [[ "${output}" == /* ]] || output="${PWD}/${output}"
  local value index tooling admission_python
  tooling="$(foundation_repository_root)"
  local -a inputs scenarios=() runtimes=() datasets=() extensions=() products=() arguments
  cd "${package}" || return "$?"
  mapfile -t inputs <qualification-arguments.txt
  ((${#inputs[@]} % 2 == 0)) || return 65
  for ((index=0; index<${#inputs[@]}; index+=2)); do
    value="${inputs[index+1]}"
    case "${inputs[index]}" in
      --extension-schema) extensions+=(--extension-schema "${value}") ;;
      --artifact)
        case "${value%%=*}" in
          scenario:scenario.json) scenarios+=("${value#*=}") ;;
          runtime_manifest:runtime-manifests/primary.json) runtimes+=("${value#*=}") ;;
          dataset_manifest:*) datasets+=("${value#*=}") ;;
          other_evidence:products/robot-description/*)
            products+=(--artifact "${value%%=*}=${PWD}/${value#*=}") ;;
        esac
        ;;
      *) return 65 ;;
    esac
  done
  ((${#scenarios[@]} == 1 && ${#runtimes[@]} == 1 && ${#datasets[@]} <= 1)) || return 65
  admission_python="$(command -v "${1}")" || return "$?"
  admission_python="$(dirname -- "${admission_python}")/python"
  "${admission_python}" "${tooling}/docker/runtime/admit-robot-description" \
    --root "${PWD}/subjects/products/robot-description" \
    --scenario "${scenarios[0]}" "${products[@]}" "${extensions[@]}" \
    >"${output%.json}.robot-description.json" || return "$?"
  arguments=(explain --scenario "${scenarios[0]}" --runtime "${runtimes[0]}" "${extensions[@]}")
  if ((${#datasets[@]})); then
    arguments+=(--dataset "${datasets[0]}")
  fi
  "$@" "${arguments[@]}" >"${output}" || return "$?"
  jq -e --arg desired "${desired}" '.execution.data_source == $desired' "${output}" >/dev/null
)

# A caller supplies only a subset of services already admitted by the model.
foundation_load_settle_services() {
  local raw="$1" service candidate admitted
  shift
  FOUNDATION_SETTLE_SERVICES=()
  while IFS= read -r service; do
    [[ -n "${service}" ]] || continue
    [[ "${service}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || return 64
    admitted=false
    for candidate in "$@"; do [[ "${candidate}" != "${service}" ]] || admitted=true; done
    [[ "${admitted}" == true ]] || {
      printf 'settlement service is outside the admitted caller list: %s\n' "${service}" >&2
      return 64
    }
    for candidate in "${FOUNDATION_SETTLE_SERVICES[@]}"; do
      [[ "${candidate}" != "${service}" ]] || {
        printf 'duplicate settlement service: %s\n' "${service}" >&2
        return 64
      }
    done
    FOUNDATION_SETTLE_SERVICES+=("${service}")
  done <<<"${raw}"
}

foundation_owned_service_snapshot() {
  local container="$1" project="$2" service="$3" image="$4" route="$5" inspection
  [[ "${container}" =~ ^[0-9a-f]{64}$ ]] || return 65
  inspection="$(timeout --foreground 10 docker inspect "${container}")" || return "$?"
  printf '%s\n' "${inspection}" |
    jq -e --arg id "${container}" --arg project "${project}" \
      --arg service "${service}" --arg image "${image}" \
      --arg run "${ROBOTICS_RUN_ID:?runner-issued run ID is required}" \
      --arg domain "${ROBOTICS_DOMAIN_ID:?runner-issued domain ID is required}" \
      --argjson route "${route}" '
      if length != 1 or .[0].Id != $id or .[0].Image != $image or
        .[0].Config.Labels["com.docker.compose.project"] != $project or
        .[0].Config.Labels["com.docker.compose.service"] != $service
      then error("caller service native identity is not owned") else .[0] end |
      def one($key; $expected):
        [(.Config.Env // [])[] | select(startswith($key + "="))] as $values |
        ($values | length) == 1 and $values[0] == ($key + "=" + $expected);
      def optional($key; $expected):
        [(.Config.Env // [])[] | select(startswith($key + "="))] as $values |
        ($values | length) == 0 or one($key; $expected);
      if (.Config.Env | type) != "array" or
        (one("ROBOTICS_RUN_ID"; $run) | not) or
        (one("ROBOTICS_DOMAIN_ID"; $domain) | not) or
        (optional("ROS_DOMAIN_ID"; $route.ROS_DOMAIN_ID) | not) or
        (optional("RMW_IMPLEMENTATION"; $route.RMW_IMPLEMENTATION) | not)
      then error("caller service run ownership or routing is not admitted") else . end |
      {container_id: .Id, image_id: .Image,
       project: .Config.Labels["com.docker.compose.project"],
       service: .Config.Labels["com.docker.compose.service"],
       environment: [(.Config.Env // [])[] | select(
         startswith("ROS_DOMAIN_ID=") or startswith("RMW_IMPLEMENTATION=") or
         startswith("ROBOTICS_RUN_ID=") or startswith("ROBOTICS_DOMAIN_ID="))],
       state: {status: .State.Status, running: .State.Running, pid: .State.Pid, exit_code: .State.ExitCode,
         oom_killed: .State.OOMKilled,
         started_at: .State.StartedAt, finished_at: .State.FinishedAt},
       restart_count: .RestartCount}'
}

# Existing Docker logging, bounded by command time and local file size.
foundation_service_logs() (
  local container="$1" output="$2"
  ulimit -f 1024
  timeout --foreground 10 docker logs --timestamps --tail 1000 "${container}" >"${output}" 2>&1
)

# Bind the endpoint already selected by the trusted runner; never select a new one.
foundation_settlement_endpoint_fingerprint() {
  local context endpoint document
  context="$(timeout --foreground 10 docker context show)" || return "$?"
  endpoint="$(timeout --foreground 10 docker context inspect "${context}" --format '{{json .Endpoints.docker}}')" || return "$?"
  document="$(jq -n --arg context "${context}" --argjson endpoint "${endpoint}" \
    --arg host "${DOCKER_HOST:-}" --arg override "${DOCKER_CONTEXT:-}" \
    --arg tls "${DOCKER_TLS_VERIFY:-}" --arg cert "${DOCKER_CERT_PATH:-}" \
    --arg config "${DOCKER_CONFIG:-}" \
    '{context:$context,endpoint:$endpoint,host:$host,override:$override,tls:$tls,cert:$cert,config:$config}')" || return "$?"
  printf '%s\n' "${document}" | sha256sum | cut -d' ' -f1
}

foundation_bind_settlement_endpoint() {
  ((${#FOUNDATION_SETTLE_SERVICES[@]})) || return 0
  FOUNDATION_SETTLEMENT_ENDPOINT_FINGERPRINT="$(foundation_settlement_endpoint_fingerprint)" || return "$?"
}

foundation_settle_caller_services() {
  local compose_name="$1" project="$2" model="$3" output="$4" provider="$5"
  local -n settlement_compose="${compose_name}"
  ((${#FOUNDATION_SETTLE_SERVICES[@]})) || return 0
  local service image reference containers container directory index status candidate native_exit primary=0
  local endpoint route
  local -a ids=() services=() images=()
  endpoint="$(foundation_settlement_endpoint_fingerprint)" || return "$?"
  [[ -n "${FOUNDATION_SETTLEMENT_ENDPOINT_FINGERPRINT:-}" &&
    "${endpoint}" == "${FOUNDATION_SETTLEMENT_ENDPOINT_FINGERPRINT}" ]] || {
    printf 'admitted caller settlement endpoint changed\n' >&2
    return 65
  }
  [[ "${provider}" == simulation || "${provider}" == playback ]] || return 64
  route="$(jq -er --arg provider "${provider}" '
    .services[$provider].environment |
    {ROS_DOMAIN_ID, RMW_IMPLEMENTATION} |
    if all(.[]; type == "string" and length > 0) then .
    else error("foundation provider route is not admitted") end' "${model}")" || return "$?"
  mkdir -p -- "${output}"
  printf '%s\n' "${endpoint}" >"${output}/endpoint.sha256"
  # Preflight every selected native identity before any stop or native wait.
  for service in "${FOUNDATION_SETTLE_SERVICES[@]}"; do
    reference="$(jq -er --arg service "${service}" '.services[$service].image | strings' "${model}")" || return "$?"
    image="$(timeout --foreground 10 docker image inspect --format '{{.Id}}' "${reference}")" || return "$?"
    [[ "${image}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 65
    containers="$(timeout --foreground 10 "${settlement_compose[@]}" ps --all --quiet "${service}")" || return "$?"
    [[ -n "${containers}" ]] || return 65
    while IFS= read -r container; do
      [[ "${container}" =~ ^[0-9a-f]{64}$ ]] || return 65
      for candidate in "${ids[@]}"; do [[ "${candidate}" != "${container}" ]] || return 65; done
      directory="${output}/${service}/${container}"
      mkdir -p -- "${directory}"
      foundation_owned_service_snapshot "${container}" "${project}" "${service}" "${image}" "${route}" \
        >"${directory}/before.json" || return "$?"
      ids+=("${container}"); services+=("${service}"); images+=("${image}")
    done <<<"${containers}"
  done
  for index in "${!ids[@]}"; do
    directory="${output}/${services[index]}/${ids[index]}"
    if foundation_service_logs "${ids[index]}" "${directory}/logs-before.txt"; then
      status=0
    else status=$?; fi
    printf '%s\n' "${status}" >"${directory}/logs-before.status"
    if ((status != 0 && primary == 0)); then primary="${status}"; fi
  done
  ((primary == 0)) || return "${primary}"
  if timeout --foreground 70 docker stop --time 60 \
    "${ids[@]}" >"${output}/native-stop.stdout" 2>"${output}/native-stop.stderr"; then
    status=0
  else status=$?; primary="${status}"; fi
  printf '%s\n' "${status}" >"${output}/native-stop.status"
  # Retain terminal facts even if an earlier native operation refused.
  for index in "${!ids[@]}"; do
    container="${ids[index]}"; directory="${output}/${services[index]}/${container}"
    if timeout --foreground 10 docker wait "${container}" \
      >"${directory}/native-wait.stdout" 2>"${directory}/native-wait.stderr"; then
      status=0
    else status=$?; fi
    printf '%s\n' "${status}" >"${directory}/native-wait.status"
    if ((status != 0 && primary == 0)); then primary="${status}"; fi
    if foundation_owned_service_snapshot "${container}" "${project}" "${services[index]}" "${images[index]}" "${route}" \
      >"${directory}/after.json"; then
      status=0
    else status=$?; fi
    printf '%s\n' "${status}" >"${directory}/native-inspect.status"
    if ((status != 0 && primary == 0)); then primary="${status}"; fi
    if foundation_service_logs "${container}" "${directory}/logs-after.txt"; then
      status=0
    else status=$?; fi
    printf '%s\n' "${status}" >"${directory}/logs-after.status"
    if ((status != 0 && primary == 0)); then primary="${status}"; fi
    if [[ -s "${directory}/after.json" && -s "${directory}/native-wait.stdout" ]]; then
      if jq -e --rawfile wait "${directory}/native-wait.stdout" '
        .state.running == false and ($wait | test("^[0-9]+\\n?$")) and
        .state.exit_code == ($wait | tonumber) and
        .state.exit_code >= 0 and .state.exit_code <= 255' \
        "${directory}/after.json" >/dev/null; then
        native_exit="$(jq -r '.state.exit_code' "${directory}/after.json")"
        if ((native_exit != 0 && primary == 0)); then primary="${native_exit}"; fi
        if ! jq -e '.state.oom_killed == false and .restart_count == 0' \
          "${directory}/after.json" >/dev/null; then
          if ((primary == 0)); then primary=65; fi
        fi
      elif ((primary == 0)); then primary=65; fi
    elif ((primary == 0)); then primary=65; fi
  done
  find "${output}" -type f -exec chmod 0444 -- {} +
  return "${primary}"
}
