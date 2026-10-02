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
