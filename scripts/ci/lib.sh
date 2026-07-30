#!/usr/bin/env bash

CI_REPO_ROOT="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 || exit 1
  pwd
)"

ci_enter_repo() {
  cd "${CI_REPO_ROOT}" || return 1
}

ci_set_build_metadata() {
  : "${GITHUB_ENV:?GITHUB_ENV must identify the GitHub Actions environment file}"
  : "${GITHUB_SHA:?GITHUB_SHA must identify the source revision}"
  {
    printf 'IMAGE_CREATED=%s\n' "$(git show --no-patch --format=%cI HEAD)"
    printf 'SOURCE_DATE_EPOCH=%s\n' "$(git show --no-patch --format=%ct HEAD)"
    printf 'VCS_REF=%s\n' "${GITHUB_SHA}"
  } >>"${GITHUB_ENV}"
}

ci_set_compose_fixture_env() {
  export ROBOTICS_COSIGN_IMAGE_DIGEST="${ROBOTICS_COSIGN_IMAGE_DIGEST:-sha256:4444444444444444444444444444444444444444444444444444444444444444}"
  export ROBOTICS_CHRONY_IDENTITY="${ROBOTICS_CHRONY_IDENTITY:-100:101}"
  export ROBOTICS_DOMAIN_ID="${ROBOTICS_DOMAIN_ID:-0}"
  export ROBOTICS_PTP_SAMPLE_FILE="${ROBOTICS_PTP_SAMPLE_FILE:-./test/time/pmc.fixture}"
  export ROBOTICS_RKNN_RENDER_GID="${ROBOTICS_RKNN_RENDER_GID:-65534}"
  export ROBOTICS_RUN_ID="${ROBOTICS_RUN_ID:-run-ci-compose}"
  export ROBOTICS_SERIAL_DEVICE="${ROBOTICS_SERIAL_DEVICE:-/dev/robotics/controller-alpha}"
  export ROBOTICS_TEST_KEY_DIR="${ROBOTICS_TEST_KEY_DIR:-./test/ci/physical-attach/test-keys}"
}

ci_export_local_image_digest() {
  local variable_name="$1"
  local image_reference="$2"
  local image_digest

  image_digest="$(
    docker image inspect "${image_reference}" --format '{{.Id}}'
  )"
  case "${image_digest}" in
    sha256:????????????????????????????????????????????????????????????????)
      ;;
    *)
      printf 'local image has no immutable sha256 identity: %s\n' \
        "${image_reference}" >&2
      return 65
      ;;
  esac
  printf -v "${variable_name}" '%s' "${image_digest}"
  export "${variable_name?}"
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

ci_validate_contract_documents() {
  local projection="$1"
  shift
  uv run --isolated --with "${ROBOTICS_CONTRACTS_REQUIREMENT}" \
    python -c '
import json
import sys

from robotics_runtime_contracts import validate_document

projection = sys.argv[1]
for path in sys.argv[2:]:
    with open(path, encoding="utf-8") as source:
        document = json.load(source)
    if projection:
        document = document[projection]
    validate_document(document)
' "${projection}" "$@"
}

ci_runtime_images() {
  : "${SIMULATION_IMAGE:?SIMULATION_IMAGE is required}"
  : "${EDGE_IMAGE:?EDGE_IMAGE is required}"
  : "${SENSOR_IMAGE:?SENSOR_IMAGE is required}"
  : "${INFERENCE_CPU_IMAGE:?INFERENCE_CPU_IMAGE is required}"
  : "${OBSERVER_IMAGE:?OBSERVER_IMAGE is required}"
  : "${BENCHMARK_IMAGE:?BENCHMARK_IMAGE is required}"
  : "${EVIDENCE_IMAGE:?EVIDENCE_IMAGE is required}"
  : "${PERMIT_PREFLIGHT_IMAGE:?PERMIT_PREFLIGHT_IMAGE is required}"
  : "${HOST_IO_FIXTURE_IMAGE:?HOST_IO_FIXTURE_IMAGE is required}"
  printf '%s\n' \
    "${SIMULATION_IMAGE}" \
    "${EDGE_IMAGE}" \
    "${SENSOR_IMAGE}" \
    "${INFERENCE_CPU_IMAGE}" \
    "${OBSERVER_IMAGE}" \
    "${BENCHMARK_IMAGE}" \
    "${EVIDENCE_IMAGE}" \
    "${PERMIT_PREFLIGHT_IMAGE}" \
    "${HOST_IO_FIXTURE_IMAGE}"
}
