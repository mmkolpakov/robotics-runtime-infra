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
  shift

  foundation_compose_logs "${log_path}" "$@"
  foundation_compose_down "$@"
}

foundation_compose_logs() {
  local log_path="$1"
  shift

  "$@" logs --no-color > "${log_path}" 2>&1 || true
}

foundation_compose_down() {
  "$@" down --volumes --remove-orphans || true
}

foundation_wait_for_clock() {
  local project="$1"

  docker compose -p "${project}" exec -T simulation \
    robotics-entrypoint timeout 20 ros2 topic echo \
    /clock rosgraph_msgs/msg/Clock --once
}

foundation_assert_project_clean() {
  local project="$1"

  test -z "$(
    docker ps --all --quiet \
      --filter "label=com.docker.compose.project=${project}"
  )"
  test -z "$(
    docker network ls --quiet \
      --filter "label=com.docker.compose.project=${project}"
  )"
}

foundation_validate_document() {
  local python="$1"
  local document="$2"

  "${python}" -c \
    'import json, sys; from robotics_runtime_contracts import validate_document; validate_document(json.load(open(sys.argv[1], encoding="utf-8")))' \
    "${document}"
}
