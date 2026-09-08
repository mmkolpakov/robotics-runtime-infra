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
  local inputs="${work_root}/runtime/inputs"
  local image_identity

  mkdir -p "$inputs"
  chmod 0777 "$runtime_dir"
  image_identity="$(ci_image_identity "${OBSERVER_IMAGE}" "${ROBOTICS_RUNTIME_MODE:-source}")" || return
  cp "${REPOSITORY_ROOT}/test/physical/hil-runtime.input.json" "$inputs/template.json"
  cp "${REPOSITORY_ROOT}/config/sros2/observer.policy.xml" "$inputs/observer.policy.xml"
  cp "${work_root}/target-evidence.json" "$inputs/target-evidence.json"
  cp "${work_root}/serial-received.txt" "$inputs/serial-received.txt"
  cp "${work_root}/serial-reverse-received.txt" "$inputs/serial-reverse-received.txt"
  cp "${work_root}/can-received.txt" "$inputs/can-received.txt"
  python3 -c '
import json
import platform
release = platform.freedesktop_os_release()
print(json.dumps({"os": release["ID"], "os_version": release["VERSION_ID"],
                  "architecture": platform.machine(), "kernel": platform.release()}))
' >"$inputs/host-platform.json"
  write_clock_facts "${ROBOTICS_TIME_EVIDENCE}" "$inputs/clock.json"
  chmod 0444 "$inputs"/*
  run_runtime_manifest_writer "$runtime_dir" "$image_identity"
  cp "$runtime_dir/provider/runtime-manifest.input.json" "$runtime_dir/runtime-manifest.input.json"
  export ROBOTICS_RUN_ID
  ROBOTICS_RUN_ID="$(jq -er '.run_id' "$runtime_dir/provider/conformance.json")"
}

run_runtime_manifest_writer() {
  local runtime_dir="$1" image_identity="$2" workspace_revision
  local -a run_arguments=()
  workspace_revision="$(jq -er '.workspace.revision' "${REPOSITORY_ROOT}/config/foundation-lock.json")"
  if [[ -n "${ROBOTICS_RUN_ID:-}" ]]; then
    run_arguments+=(--run-id "$ROBOTICS_RUN_ID")
  fi
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --tmpfs /tmp \
    --mount "type=bind,src=${runtime_dir},dst=/runtime" \
    --mount "type=bind,src=${PHYSICAL_ATTACH_MODULE_ROOT}/create-runtime-input.py,dst=/create-runtime-input.py,readonly" \
    "${OBSERVER_IMAGE}" python3 /create-runtime-input.py \
    --inputs /runtime/inputs --output /runtime/provider \
    --subject-digest "$(jq -er '.digest' <<<"$image_identity")" \
    --subject-reference "$(jq -er '.reference' <<<"$image_identity")" \
    --workspace-revision "$workspace_revision" \
    --infra-revision "$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)" \
    --domain-id "${ROS_DOMAIN_ID:-92}" "${run_arguments[@]}"
}

write_clock_facts() {
  # verify_time_evidence already checked the units, observation window and policy.
  # Retain the largest absolute observed offset/drift, never fixed template values.
  jq -s '
    [.[].resourceMetrics[].scopeMetrics[].metrics[] as $metric |
      ($metric.gauge.dataPoints // $metric.sum.dataPoints // [])[] |
      {name: $metric.name, value: (.asDouble // (.asInt | tonumber))}]
    | {offset_ms: ([.[] | select(.name == "robotics.hardware.clock.offset") | .value | fabs] | max),
       drift_ppm: ([.[] | select(.name == "robotics.hardware.clock.drift") | .value | fabs] | max)}
  ' "$1" >"$2"
}

retain_runtime_evidence() {
  local destination filename
  destination="$(mktemp -d "${report_output%.json}.runtime.XXXXXXXX")"
  mkdir "$destination/inputs" "$destination/provider"
  # Retain only public observations; the keystore and authorization inputs stay
  # in the temporary work directory. Mount this directory at /runtime to replay
  # the file URIs recorded by the provider.
  for filename in template.json host-platform.json target-evidence.json \
    serial-received.txt serial-reverse-received.txt can-received.txt \
    clock.json observer.policy.xml; do
    install -m 0644 "${work_root}/runtime/inputs/$filename" "$destination/inputs/$filename"
  done
  for filename in profile.json configuration.json conformance.json runtime-manifest.input.json; do
    install -m 0644 "${work_root}/runtime/provider/$filename" "$destination/provider/$filename"
  done
  install -m 0644 "${work_root}/preflight-positive/output/runtime-manifest.json" \
    "$destination/runtime-manifest.json"
  jq --arg directory "$(basename "$destination")" \
    '.runtime_evidence_directory = $directory' "$case_report" >"${case_report}.tmp"
  mv "${case_report}.tmp" "$case_report"
}

run_observer_script() {
  local script="$1"
  local status=0
  shift
  real_compose --profile real-observation \
    run --rm "$@" --no-TTY real-observation-observer \
    bash -Eeuo pipefail -s <"${PHYSICAL_ATTACH_FIXTURE_ROOT}/${script}" ||
    status=$?
  if test "${status}" -ne 0; then
    real_compose --profile real-observation \
      ps --all >&2 || true
    real_compose --profile real-observation \
      logs --no-color --timestamps \
      physical-permit-preflight \
      physical-runtime-manifest >&2 || true
    return "${status}"
  fi
}

start_sros2_observer() {
  local case_dir="$1"
  local runtime_dir="${work_root}/runtime"
  local evidence_dir="${work_root}/evidence"
  local input_dir="${work_root}/input"
  local results_dir="${work_root}/results"
  local preflight_state_dir="${work_root}/preflight-positive"
  local authorization_output_dir="${preflight_state_dir}/output"
  local nonces_dir="${preflight_state_dir}/nonces"
  local target_identity

  mkdir -p \
    "${evidence_dir}" \
    "${input_dir}" \
    "${results_dir}"
  chmod -R 0777 \
    "${evidence_dir}" \
    "${input_dir}" \
    "${results_dir}"
  prepare_preflight_directories \
    "${nonces_dir}" \
    "${authorization_output_dir}"
  cp \
    "${runtime_dir}/runtime-manifest.input.json" \
    "${input_dir}/runtime-manifest.input.json"
  cp "${ROBOTICS_TIME_EVIDENCE}" "${evidence_dir}/hardware-time.otlp.json"

  export ROBOTICS_ATTACH_NETWORK="${attach_network}"
  export ROBOTICS_AUTHORIZATION_DIR="${case_dir}"
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

  test -s "${authorization_output_dir}/execution-verification.json" || {
    printf 'permit preflight did not emit execution verification\n' >&2
    return 70
  }
  test -s "${authorization_output_dir}/runtime-manifest.json" || {
    printf 'permit preflight did not materialize the runtime manifest\n' >&2
    return 70
  }
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
    ' "${authorization_output_dir}/runtime-manifest.json" >/dev/null || {
    printf 'runtime manifest does not bind the authorized physical target\n' >&2
    return 70
  }
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
