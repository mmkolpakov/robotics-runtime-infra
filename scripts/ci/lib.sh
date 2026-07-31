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
  export ROBOTICS_CHRONY_IDENTITY="${ROBOTICS_CHRONY_IDENTITY:-100:101}"
  export ROBOTICS_DOMAIN_ID="${ROBOTICS_DOMAIN_ID:-0}"
  export PERMIT_PREFLIGHT_CI_IMAGE="${PERMIT_PREFLIGHT_CI_IMAGE:-local/robotics-runtime-infra/permit-preflight-ci:dev}"
  export ROBOTICS_PTP_SAMPLE_FILE="${ROBOTICS_PTP_SAMPLE_FILE:-./test/time/pmc.fixture}"
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
  uv run --isolated --with "${ROBOTICS_CONTRACTS_REQUIREMENT}" \
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
