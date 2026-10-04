#!/usr/bin/env bash

CI_REPO_ROOT="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 || exit 1
  pwd
)"

ci_enter_repo() {
  cd "${CI_REPO_ROOT}" || return 1
}

ci_set_compose_fixture_env() {
  export ROBOTICS_RUNTIME_MODE="${ROBOTICS_RUNTIME_MODE:-source}"
  # Source tags and socket path below are Compose syntax fixtures, not observations.
  export MEDIA_IMAGE="${MEDIA_IMAGE:-local/robotics-runtime-infra/media:dev}"
  export HOST_IMAGE="${HOST_IMAGE:-local/robotics-runtime-infra/host:dev}"
  export ROBOTICS_WEBOTS_IMAGE="${ROBOTICS_WEBOTS_IMAGE:-local/native-webots:dev}"
  export ROBOTICS_WEBOTS_SCOPE="${ROBOTICS_WEBOTS_SCOPE:-ci-webots}"
  export ROBOTICS_PX4_IMAGE="${ROBOTICS_PX4_IMAGE:-local/native-px4:dev}"
  export ROBOTICS_PX4_SCOPE="${ROBOTICS_PX4_SCOPE:-ci-px4}"
  export ROBOTICS_PX4_GRPC_PORT="${ROBOTICS_PX4_GRPC_PORT:-50052}"
  export ROBOTICS_RUN_VOLUME="${ROBOTICS_RUN_VOLUME:-ci-run-data}"
  export ROBOTICS_RETAINED_VOLUME="${ROBOTICS_RETAINED_VOLUME:-ci-retained-data}"
  export LEGACY_FINALIZER_IMAGE="${LEGACY_FINALIZER_IMAGE:-local/native-finalizer:dev}"
  export ROBOTICS_INPUT_VOLUME="${ROBOTICS_INPUT_VOLUME:-ci-input}"
  export ROBOTICS_RESULT_VOLUME="${ROBOTICS_RESULT_VOLUME:-ci-result}"
  export ISAAC_SCENE_SHA256="${ISAAC_SCENE_SHA256:-0a19bca17a24a7d61bdef19dc410a220ef1ffe464f4e992a5c1cae7c52cbca29}"
  export ROBOTICS_ISAAC_INPUT_VOLUME="${ROBOTICS_ISAAC_INPUT_VOLUME:-ci-isaac-input}"
  export ROBOTICS_ISAAC_RESULT_VOLUME="${ROBOTICS_ISAAC_RESULT_VOLUME:-ci-isaac-result}"
  export ROBOTICS_ISAAC_SCOPE="${ROBOTICS_ISAAC_SCOPE:-ci-isaac}"
  export ROBOTICS_ISAAC_PHASE_TOKEN="${ROBOTICS_ISAAC_PHASE_TOKEN:-ci-correlation}"
  export ROBOTICS_ISAAC_PHASE_TIMEOUT="${ROBOTICS_ISAAC_PHASE_TIMEOUT:-90}"
  export ROBOTICS_ISAAC_STEPS="${ROBOTICS_ISAAC_STEPS:-60}"
  export ROBOTICS_ISAAC_DT="${ROBOTICS_ISAAC_DT:-0.016666666666666666}"
  export ROBOTICS_ISAAC_RENDER_FRAMES="${ROBOTICS_ISAAC_RENDER_FRAMES:-0}"
  export ROBOTICS_ISAAC_WIDTH="${ROBOTICS_ISAAC_WIDTH:-640}"
  export ROBOTICS_ISAAC_HEIGHT="${ROBOTICS_ISAAC_HEIGHT:-480}"
  export ROBOTICS_HOST_ID="${ROBOTICS_HOST_ID:-host-ci-compose}"
  export ROBOTICS_ENGINE_HOST_SOCKET="${ROBOTICS_ENGINE_HOST_SOCKET:-/run/robotics-ci/engine.sock}"
  export SIMULATION_IMAGE="${SIMULATION_IMAGE:-local/robotics-runtime-infra/simulation:ci}"
  export ROBOTICS_METRICS_TOPIC="${ROBOTICS_METRICS_TOPIC:-/example/sequence}"
  export ROBOTICS_PLAYBACK_CLOCK_HZ="${ROBOTICS_PLAYBACK_CLOCK_HZ:-200}"
  export ROBOTICS_PLAYBACK_RATE="${ROBOTICS_PLAYBACK_RATE:-1}"
  export ROBOTICS_PLAYBACK_START_OFFSET="${ROBOTICS_PLAYBACK_START_OFFSET:-0}"
  export ROBOTICS_CHRONY_IDENTITY="${ROBOTICS_CHRONY_IDENTITY:-100:101}"
  export ROBOTICS_DOMAIN_ID="${ROBOTICS_DOMAIN_ID:-0}"
  export PERMIT_PREFLIGHT_CI_IMAGE="${PERMIT_PREFLIGHT_CI_IMAGE:-local/robotics-runtime-infra/permit-preflight-ci:dev}"
  export ROBOTICS_PTP_SAMPLE_DIR="${ROBOTICS_PTP_SAMPLE_DIR:-./test/time}"
  export ROBOTICS_RKNN_RENDER_GID="${ROBOTICS_RKNN_RENDER_GID:-65534}"
  export ROBOTICS_RUN_ID="${ROBOTICS_RUN_ID:-run-ci-compose}"
  export ROBOTICS_SERIAL_DEVICE="${ROBOTICS_SERIAL_DEVICE:-/dev/robotics/controller-alpha}"
  export ROBOTICS_TEST_KEY_DIR="${ROBOTICS_TEST_KEY_DIR:-./test/ci/physical-attach/test-keys}"
}

ci_opa() {
  docker run --rm \
    --volume "${CI_REPO_ROOT}:/project:ro" \
    --workdir /project \
    "${POLICY_TOOLING_IMAGE:-local/robotics-runtime-infra/policy-tooling:ci}" \
    "$@"
}

ci_yq() {
  docker run --rm \
    --volume "${CI_REPO_ROOT}:/project:ro" \
    --workdir /project \
    --entrypoint /yq \
    "${POLICY_TOOLING_IMAGE:-local/robotics-runtime-infra/policy-tooling:ci}" \
    "$@"
}

ci_yq_from_root() {
  local root="$1"
  shift
  root="$(realpath -e -- "${root}")" || return
  docker run --rm \
    --volume "${root}:/input:ro" \
    --entrypoint /yq \
    "${POLICY_TOOLING_IMAGE:-local/robotics-runtime-infra/policy-tooling:ci}" \
    "$@"
}

ci_policy_deny_count() {
  local policy="$1"
  local package="$2"
  local input="$3"
  ci_opa eval \
    --format raw \
    --data "${policy}" \
    --input "${input}" \
    "count(data.${package}.deny)"
}

ci_require_policy_allows() {
  local policy="$1"
  local package="$2"
  local input="$3"
  local denials
  denials="$(ci_opa eval \
    --fail \
    --format json \
    --data "${policy}" \
    --input "${input}" \
    "data.${package}.deny")" || return
  jq -e '
    (.result | length) == 1 and
    (.result[0].expressions | length) == 1 and
    (.result[0].expressions[0].value | type) == "array" and
    (.result[0].expressions[0].value | length) == 0
  ' <<<"${denials}" >/dev/null || {
    jq -r '.result[0].expressions[0].value[]? // "invalid OPA result"' \
      <<<"${denials}" >&2
    return 1
  }
}

ci_require_model_paths_within_root() {
  local model="$1"
  local root="$2"
  local canonical_root path canonical_path
  canonical_root="$(realpath -e -- "${root}")" || return
  while IFS= read -r path; do
    canonical_path="$(realpath -e -- "${path}")" || {
      printf 'consumer path does not exist: %s\n' "${path}" >&2
      return 1
    }
    case "${canonical_path}" in
      "${canonical_root}" | "${canonical_root}"/*) ;;
      *)
        printf 'consumer path escapes its repository: %s -> %s\n' \
          "${path}" "${canonical_path}" >&2
        return 1
        ;;
    esac
  done < <(
    jq -er '[
      .services[]?.volumes[]? | select(.type == "bind") | .source,
      .services[]?.build.context? // empty,
      .configs[]?.file? // empty,
      .secrets[]?.file? // empty
    ] | .[]' "${model}"
  )
}

ci_require_source_paths_within_root() {
  local model="$1"
  local root="$2"
  local canonical_root path candidate canonical_path
  canonical_root="$(realpath -e -- "${root}")" || return
  while IFS= read -r path; do
    if [[ "${path}" == /* ]]; then
      candidate="${path}"
    else
      candidate="${canonical_root}/${path}"
    fi
    canonical_path="$(realpath -e -- "${candidate}")" || {
      printf 'consumer source path does not exist: %s\n' "${path}" >&2
      return 1
    }
    case "${canonical_path}" in
      "${canonical_root}" | "${canonical_root}"/*) ;;
      *)
        printf 'consumer source path escapes its repository: %s -> %s\n' \
          "${path}" "${canonical_path}" >&2
        return 1
        ;;
    esac
  done < <(
    jq -er '[
      .configs[]?.file? // empty
    ] | .[] | select(type == "string")' "${model}"
  )
}

ci_validate_contract_documents() {
  local foundation="${CI_REPO_ROOT}/dependencies/robotics-runtime"
  if [[ ! -e "${foundation}/.git" ]]; then
    bash "${CI_REPO_ROOT}/scripts/ci/foundation/import-sources.sh"
  fi
  python3 "${CI_REPO_ROOT}/scripts/ci/foundation/sync-workspace-pins.py" --check
  uv run --project "${foundation}" --locked --no-default-groups \
    --package robotics-runtime-contracts --no-editable \
    robotics-contracts validate --quiet "$@"
}

ci_bake_target_images() {
  test "$#" -gt 0
  docker buildx bake --file docker-bake.hcl --print "$@" |
    jq -er '
      [
        .target
        | to_entries[]
        | select((.value.tags // []) | length > 0)
        | if (.value.tags | length) == 1
          then [.key, .value.tags[0]]
          else error("Bake target \(.key) must have exactly one tag")
          end
      ]
      | if length > 0
        then .[] | @tsv
        else error("Bake selection has no tagged images")
        end
    '
}
