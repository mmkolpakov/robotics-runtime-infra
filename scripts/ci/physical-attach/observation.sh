#!/usr/bin/env bash

# This module is sourced by physical-attach.sh and uses its coordinator state.
# shellcheck disable=SC2034,SC2154

prepare_sros2_identity() {
  mkdir -p "${security_dir}"
  chmod 0777 "${security_dir}"
  export ROBOTICS_SECURITY_WORK_DIR="${security_dir}"
  export ROS_DOMAIN_ID=92
  security_compose_used=1
  security_compose --profile security-init \
    run --rm security-artifacts
  test -s \
    "${security_dir}/keystore/enclaves/robotics/telemetry_source/cert.pem"
}

write_runtime_manifest_input() {
  local runtime_dir="${work_root}/runtime"
  local target_identity
  local target_evidence_sha256
  local observer_policy_sha256
  local image_digest
  local contracts_revision
  local harness_revision

  mkdir -p "${runtime_dir}"
  chmod 0777 "${runtime_dir}"
  target_identity="$(<"${work_root}/target-identity.sha256")"
  target_evidence_sha256="$(sha256_file "${work_root}/target-evidence.json")"
  observer_policy_sha256="$(
    sha256_file "${REPOSITORY_ROOT}/config/sros2/observer.policy.xml"
  )"
  image_digest="$(
    docker image inspect "${OBSERVER_IMAGE}" --format '{{.Id}}'
  )"
  contracts_revision="$(
    awk '
      /^  robotics-runtime-contracts:/ {contracts = 1; next}
      contracts && /^    version:/ {print $2; exit}
    ' "${REPOSITORY_ROOT}/foundation.repos"
  )"
  harness_revision="$(
    awk '
      /^  robotics-acceptance-harness:/ {harness = 1; next}
      harness && /^    version:/ {print $2; exit}
    ' "${REPOSITORY_ROOT}/foundation.repos"
  )"

  jq \
    --arg architecture "$(uname -m)" \
    --arg contracts_revision "${contracts_revision}" \
    --arg harness_revision "${harness_revision}" \
    --arg infra_revision "$(git -C "${REPOSITORY_ROOT}" rev-parse HEAD)" \
    --arg image_digest "${image_digest}" \
    --arg image_reference "${OBSERVER_IMAGE}@${image_digest}" \
    --arg kernel "$(uname -r)" \
    --arg observer_policy_sha256 "${observer_policy_sha256}" \
    --arg target_evidence_sha256 "${target_evidence_sha256}" \
    --arg target_identity "${target_identity}" \
    -f "${PHYSICAL_ATTACH_FIXTURE_ROOT}/runtime-manifest.jq" \
    "${REPOSITORY_ROOT}/test/physical/hil-runtime.input.json" \
    >"${runtime_dir}/runtime-manifest.input.json"
}

run_observer_script() {
  local script="$1"
  shift
  real_compose --profile real-observation \
    run --rm "$@" --no-TTY real-observation-observer \
    bash -Eeuo pipefail -s <"${PHYSICAL_ATTACH_FIXTURE_ROOT}/${script}"
}

start_sros2_observer() {
  local case_dir="$1"
  local runtime_dir="${work_root}/runtime"
  local authorization_dir="${work_root}/authorization"
  local evidence_dir="${work_root}/evidence"
  local input_dir="${work_root}/input"
  local results_dir="${work_root}/results"
  local preflight_state_dir="${work_root}/preflight-positive"
  local authorization_output_dir="${preflight_state_dir}/output"
  local nonces_dir="${preflight_state_dir}/nonces"
  local authorization_file
  local target_identity

  mkdir -p \
    "${authorization_dir}" \
    "${evidence_dir}" \
    "${input_dir}" \
    "${results_dir}"
  chmod -R 0777 \
    "${authorization_dir}" \
    "${evidence_dir}" \
    "${input_dir}" \
    "${results_dir}"
  prepare_preflight_directories \
    "${nonces_dir}" \
    "${authorization_output_dir}"
  for authorization_file in \
    execution-permit.json \
    execution-statement.json \
    operator.sigstore.json \
    approver.sigstore.json \
    trust-policy.json \
    execution-request.json; do
    cp \
      "${case_dir}/${authorization_file}" \
      "${authorization_dir}/${authorization_file}"
  done
  cp \
    "${runtime_dir}/runtime-manifest.input.json" \
    "${input_dir}/runtime-manifest.input.json"
  cp "${ROBOTICS_TIME_EVIDENCE}" "${evidence_dir}/hardware-time.otlp.json"

  export ROBOTICS_ATTACH_NETWORK="${attach_network}"
  export ROBOTICS_AUTHORIZATION_DIR="${authorization_dir}"
  export ROBOTICS_AUTHORIZATION_OUTPUT_DIR="${authorization_output_dir}"
  export ROBOTICS_EVIDENCE_DIR="${evidence_dir}"
  export ROBOTICS_RUN_INPUT_DIR="${input_dir}"
  export ROBOTICS_NONCE_DIR="${nonces_dir}"
  export ROBOTICS_RESULTS_DIR="${results_dir}"
  export ROBOTICS_SECURITY_WORK_DIR="${security_dir}"
  export ROBOTICS_TEST_KEY_DIR="${work_root}/keys"
  export ROS_DOMAIN_ID=92

  if docker network inspect "${attach_network}" >/dev/null 2>&1; then
    printf 'refusing to reuse an existing Docker network: %s\n' \
      "${attach_network}" >&2
    return 73
  fi
  docker network create \
    --driver bridge \
    --internal \
    --label "org.robotics-runtime.owner=${project}" \
    "${attach_network}"
  attach_network_created=1
  real_compose_started=1
  real_compose \
    --profile real-observation \
    --profile real-observation-test \
    up --detach edge-attach-data-plane real-observation-test-source
  run_observer_script observer-listen.sh

  test -s "${authorization_output_dir}/execution-verification.json"
  test -s "${authorization_output_dir}/runtime-manifest.json"
  jq -e \
    --slurpfile expected "${case_dir}/execution-verification.json" \
    '. == $expected[0]' \
    "${authorization_output_dir}/execution-verification.json" >/dev/null
  target_identity="$(<"${work_root}/target-identity.sha256")"
  jq -e \
    --arg target_identity "${target_identity}" '
      .authorization.mode == "verified_execution_permit" and
      .execution.target_environment == "hil" and
      (.physical_targets | length) == 1 and
        .physical_targets[0].target_id == "controller-ci" and
        .physical_targets[0].scope == "controller" and
        .physical_targets[0].identity_kind == "x509_spki" and
        .physical_targets[0].identity_sha256 == $target_identity and
        (.physical_targets[0] | has("stable_device_path") | not) and
        (.physical_targets[0].preflight_evidence_sha256 | length) == 64 and
      .clock.sync_protocol == "chrony_ntp"
    ' "${authorization_output_dir}/runtime-manifest.json" >/dev/null
}

verify_command_publish_denied() {
  run_observer_script observer-command-denied.sh --no-deps
}

verify_unsecured_source_denied() {
  real_compose \
    --profile real-observation \
    --profile real-observation-test \
    stop real-observation-test-source
  real_compose \
    --profile real-observation \
    --profile real-observation-test \
    rm --force real-observation-test-source
  real_compose \
    --profile real-observation \
    --profile real-observation-test-negative \
    up --detach edge-attach-data-plane real-observation-test-unsecured-source
  run_observer_script observer-unsecured-source-denied.sh --no-deps
}
