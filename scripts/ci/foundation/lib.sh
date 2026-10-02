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
  [[ -n "${arguments_file}" ]] || return 0
  arguments_file="$(foundation_consumer_file "${consumer_root}" "${arguments_file}")" ||
    return 64
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
    path="$(foundation_consumer_file "${consumer_root}" "${path}")" || return 64
    FOUNDATION_ARTIFACT_ARGUMENTS+=("${option}" "${header}=${path}")
  done <"${arguments_file}"
}


# Invoke only after successful native bundle verification on these same subjects.
foundation_explain_qualification() (
  local package="$1" output="$2" desired="$3"
  shift 3
  local value index
  local -a inputs scenarios=() runtimes=() datasets=() extensions=() arguments
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
        esac
        ;;
      *) return 65 ;;
    esac
  done
  ((${#scenarios[@]} == 1 && ${#runtimes[@]} == 1 && ${#datasets[@]} <= 1)) || return 65
  arguments=(explain --scenario "${scenarios[0]}" --runtime "${runtimes[0]}" "${extensions[@]}")
  if ((${#datasets[@]})); then
    arguments+=(--dataset "${datasets[0]}")
  fi
  "$@" "${arguments[@]}" >"${output}" || return "$?"
  jq -e --arg desired "${desired}" '.execution.data_source == $desired' "${output}" >/dev/null
)
