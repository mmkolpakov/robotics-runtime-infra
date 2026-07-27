#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  SCRIPT="${REPOSITORY_ROOT}/scripts/ci/physical-attach.sh"
  MODULES="${REPOSITORY_ROOT}/scripts/ci/physical-attach"
  FIXTURES="${BATS_TEST_DIRNAME}/physical-attach"
}

@test "declares exactly the required five cases" {
  run bash "${SCRIPT}" --list-cases

  [ "${status}" -eq 0 ]
  [ "${output}" = "$(cat <<'EOF'
positive
expired-permit
wrong-target
wrong-signer
command-publish-denied
EOF
)" ]
}

@test "main and helper entrypoints are valid Bash" {
  run bash -n \
    "${SCRIPT}" \
    "${MODULES}/authorization.sh" \
    "${MODULES}/devices.sh" \
    "${MODULES}/observation.sh" \
    "${FIXTURES}/observer-command-denied.sh" \
    "${FIXTURES}/observer-listen.sh" \
    "${FIXTURES}/observer-unsecured-source-denied.sh"

  [ "${status}" -eq 0 ]
}

@test "coordinator sources only working modules under scripts" {
  run awk '
    /^[[:space:]]*source[[:space:]]/ {print}
  ' "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(cat <<'EOF'
source "${PHYSICAL_ATTACH_MODULE_ROOT}/devices.sh"
source "${PHYSICAL_ATTACH_MODULE_ROOT}/authorization.sh"
source "${PHYSICAL_ATTACH_MODULE_ROOT}/observation.sh"
EOF
)" ]
  [[ "${output}" != *"test/"* ]]

  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    test "${PHYSICAL_ATTACH_MODULE_ROOT}" = \
      "${REPOSITORY_ROOT}/scripts/ci/physical-attach"
    for module in devices authorization observation; do
      test -r "${PHYSICAL_ATTACH_MODULE_ROOT}/${module}.sh"
    done
    declare -F write_scenario_input_manifest >/dev/null
    declare -F physical_attach_scenario_sha256 >/dev/null
  ' _ "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "main run dispatches the real scenario entrypoint" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    run_scenario() { printf "run_scenario\n"; }
    main run
  ' _ "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "run_scenario" ]
}

@test "setup invokes the exact physical coordinator functions" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
      source "$1"
      acquire_host_lock() { printf "acquire_host_lock\n"; }
      verify_permit_image_digest() { printf "verify_permit_image_digest\n"; }
      validate_physical_compose_model() {
        printf "validate_physical_compose_model\n"
      }
      prepare_pty_pair() { printf "prepare_pty_pair\n"; }
      prepare_vcan_gateway() { printf "prepare_vcan_gateway\n"; }
      verify_time_evidence() { printf "verify_time_evidence\n"; }
      prepare_sros2_identity() { printf "prepare_sros2_identity\n"; }
      write_target_evidence() { printf "write_target_evidence\n"; }
      write_scenario_input_manifest() {
        printf "write_scenario_input_manifest\n"
      }
    write_trust_policy() { printf "write_trust_policy\n"; }
    generate_role_keys() { printf "generate_role_keys\n"; }
    check_production_authorize_contract() {
      printf "check_production_authorize_contract\n"
    }
    run_setup
  ' _ "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "$(cat <<'EOF'
acquire_host_lock
verify_permit_image_digest
validate_physical_compose_model
prepare_pty_pair
prepare_vcan_gateway
verify_time_evidence
prepare_sros2_identity
write_target_evidence
write_scenario_input_manifest
write_trust_policy
generate_role_keys
check_production_authorize_contract
EOF
)" ]
}

@test "case orchestrator invokes the exact five case functions in order" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    run_case_positive() { printf "positive\n"; }
    run_case_expired_permit() { printf "expired-permit\n"; }
      run_case_wrong_target() { printf "wrong-target\n"; }
      run_case_wrong_signer() { printf "wrong-signer\n"; }
      run_case_command_publish_denied() { printf "command-publish-denied\n"; }
      time_measured_at="$(date -u -d "-60 seconds" +%Y-%m-%dT%H:%M:%SZ)"
      run_cases target-identity
  ' _ "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "$(cat <<'EOF'
positive
expired-permit
wrong-target
wrong-signer
command-publish-denied
EOF
)" ]
}

@test "production keyless authorize remains a separate command contract" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    work_root=/tmp/physical-attach-command-contract
    permit_run() {
      printf "%s\n" \
        "permit-preflight authorize PERMIT STATEMENT OPERATOR_BUNDLE APPROVER_BUNDLE TRUSTED_ROOT TRUST_POLICY REQUEST NONCE_DIR OUTPUT COSIGN_IMAGE_DIGEST" >&2
      return 64
    }
    check_production_authorize_contract
  ' _ "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  run jq -e '
      .authorization.ci_equivalent == "two-key-cosign-rekor-opa" and
      .authorization.production_keyless_entrypoint == "command-contract-only" and
      .target_identity.kind == "x509_spki" and
      .target_identity.scope == "ci_synthetic_sros2_target" and
      (.target_identity.hardware_identity_verified | not)
  ' "${FIXTURES}/report.json"
  [ "${status}" -eq 0 ]
}

@test "fails closed when required runtime inputs are absent" {
  run env \
    -u BENCHMARK_IMAGE \
    -u CAN_CLIENT_IMAGE \
    -u COSIGN_PASSWORD \
      -u OBSERVER_IMAGE \
      -u PERMIT_PREFLIGHT_IMAGE \
      -u ROBOTICS_COSIGN_IMAGE_DIGEST \
      -u ROBOTICS_TIME_EVIDENCE \
      -u ROBOTICS_TIME_EVIDENCE_RUN_ID \
      -u ROBOTICS_TIME_EVIDENCE_WINDOW \
      bash "${SCRIPT}" --check-prerequisites

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"required environment variable is unset"* ]]
}

@test "declarative inputs are valid JSON" {
  run jq -e '
    .trust_policy.schema_version == "execution-trust-policy.v1" and
    .permit.schema_version == "execution-permit.v1" and
    .request.target.environment == "hil"
  ' "${FIXTURES}/authorization-template.json"
  [ "${status}" -eq 0 ]

  run jq -e '
      .schema_version == "physical-attach-evidence.v1" and
      .identity.kind == "x509_spki" and
      .identity.scope == "ci_synthetic_sros2_target" and
      (.identity.hardware_identity_verified | not) and
      .serial.transport == "pty" and
      .can.receive_only_gateway
  ' "${FIXTURES}/target-evidence.json"
  [ "${status}" -eq 0 ]
}

@test "synthetic target identity is the generated certificate SPKI" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    temporary="$(mktemp -d)"
    trap "rm -rf -- \"${temporary}\"" EXIT
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${temporary}/key.pem" \
      -out "${temporary}/cert.pem" \
      -subj /CN=ci-synthetic-target \
      -days 1 >/dev/null 2>&1
    identity="$(x509_spki_sha256 "${temporary}/cert.pem")"
    [[ "${identity}" =~ ^[a-f0-9]{64}$ ]]
    test "${identity}" = "$(
      openssl x509 -in "${temporary}/cert.pem" -pubkey -noout |
        openssl pkey -pubin -outform DER |
        sha256sum |
        awk "{print \$1}"
    )"
  ' _ "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "authorization renderer binds one identity across permit and statement" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    work_root="$(mktemp -d)"
    trap "rm -rf -- \"${work_root}\"" EXIT
    target_identity="$(
      printf "controller-ci" | sha256sum | awk "{print \$1}"
    )"
      printf "%s\n" "${target_identity}" >"${work_root}/target-identity.sha256"
      printf "fixture-manifest\n" >"${work_root}/scenario-inputs.manifest"
      scenario_manifest="${work_root}/scenario-inputs.manifest"
    jq \
      ".checked_at = \"2026-07-26T12:00:00Z\"" \
      "${PHYSICAL_ATTACH_FIXTURE_ROOT}/target-evidence.json" \
      >"${work_root}/target-evidence.json"
    docker() {
      test "$1" = image
      test "$2" = inspect
      case "$3" in
        acceptance-observer)
          printf "sha256:%064d\n" 1
          ;;
        permit-preflight)
          printf "sha256:%064d\n" 2
          ;;
        *)
          return 64
          ;;
      esac
    }
    OBSERVER_IMAGE=acceptance-observer
    PERMIT_PREFLIGHT_IMAGE=permit-preflight
    ROBOTICS_COSIGN_IMAGE_DIGEST="sha256:$(printf "%064d" 2)"
    write_trust_policy
    write_permit_case \
      "${work_root}/case" \
      "2026-07-26T12:00:00Z" \
      "2026-07-26T12:15:00Z" \
      "${target_identity}"
    scenario_sha256="$(
      jq -r ".scenario_sha256" \
        "${work_root}/case/execution-permit.json"
    )"
    jq -e \
      --arg target_identity "${target_identity}" \
      --arg scenario_sha256 "${scenario_sha256}" "
      .target.identity_sha256 == \$target_identity and
      .scenario_sha256 == \$scenario_sha256
    " \
      "${work_root}/case/execution-request.json"
    jq -e --slurpfile permit "${work_root}/case/execution-permit.json" "
      .predicate == \$permit[0] and
      .subject[0].digest.sha256 == \$permit[0].scenario_sha256 and
      (\"sha256:\" + .subject[1].digest.sha256) == \$permit[0].image_digest and
      \$permit[0].image_digest == \"sha256:$(printf "%064d" 1)\" and
      \$permit[0].image_digest != \"${ROBOTICS_COSIGN_IMAGE_DIGEST}\"
    " "${work_root}/case/execution-statement.json"
  ' _ "${SCRIPT}"

  [ "${status}" -eq 0 ]
}

@test "runtime manifest filter binds revisions and physical evidence" {
  run jq \
    --arg architecture x86_64 \
    --arg contracts_revision contracts-revision \
    --arg harness_revision harness-revision \
    --arg infra_revision infra-revision \
    --arg image_digest "sha256:$(printf '%064d' 0)" \
    --arg image_reference "local/synthetic-observer@sha256:$(printf '%064d' 0)" \
    --arg kernel 6.8.0 \
    --arg observer_policy_sha256 "$(printf '%064d' 1)" \
    --arg target_evidence_sha256 "$(printf '%064d' 2)" \
    --arg target_identity "$(printf '%064d' 3)" \
    -f "${FIXTURES}/runtime-manifest.jq" \
    "${REPOSITORY_ROOT}/test/physical/hil-runtime.input.json"
  [ "${status}" -eq 0 ]
  run jq -e '
      .runtime_id == "ci.physical-attach-runtime" and
      .execution.target_environment == "hil" and
      .physical_targets[0].target_id == "controller-ci" and
      .physical_targets[0].identity_kind == "x509_spki" and
      (.physical_targets[0] | has("stable_device_path") | not) and
      .clock.sync_protocol == "chrony_ntp"
  ' <<<"${output}"
  [ "${status}" -eq 0 ]
}

@test "local image digest and compose configuration are fail-closed" {
  run bash -c '
    set -Eeuo pipefail
    source "$1"
    docker() {
      test "$1" = image
      test "$2" = inspect
      printf "sha256:%064d\n" 7
    }
    ci_export_local_image_digest ROBOTICS_COSIGN_IMAGE_DIGEST fixture
    test "${ROBOTICS_COSIGN_IMAGE_DIGEST}" = "sha256:$(printf "%064d" 7)"
  ' _ "${REPOSITORY_ROOT}/scripts/ci/lib.sh"
  [ "${status}" -eq 0 ]

  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    real_compose() { printf "%s\n" "$*"; }
    validate_physical_compose_model
  ' _ "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--profile real-observation"* ]]
  [[ "${output}" == *"config --quiet"* ]]
}

@test "host lock serializes access and cleanup honors ownership flags" {
  lock="${BATS_TEST_TMPDIR}/physical-attach.lock"
  bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    export ROBOTICS_PHYSICAL_ATTACH_LOCK_FILE="$2"
    source "$1"
    acquire_host_lock
    printf ready >"$3"
    sleep 5
  ' _ "${SCRIPT}" "${lock}" "${BATS_TEST_TMPDIR}/ready" &
  holder=$!
  for _ in {1..50}; do
    [ -s "${BATS_TEST_TMPDIR}/ready" ] && break
    sleep 0.1
  done

  run env \
    PHYSICAL_ATTACH_LIBRARY_ONLY=1 \
    ROBOTICS_PHYSICAL_ATTACH_LOCK_FILE="${lock}" \
    bash -c 'source "$1"; acquire_host_lock' _ "${SCRIPT}"
  [ "${status}" -eq 75 ]
  kill "${holder}"
  wait "${holder}" || true

  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    work_root=
    real_compose() { printf "unexpected real cleanup\n"; }
    security_compose() { printf "unexpected security cleanup\n"; }
    can_compose() { printf "unexpected CAN cleanup\n"; }
    docker() { printf "unexpected Docker cleanup\n"; }
    sudo() { printf "unexpected sudo cleanup\n"; }
    cleanup
  ' _ "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "cleanup failure changes an otherwise successful process status" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    work_root=
    real_compose_started=1
    real_compose() { return 1; }
    security_compose() { return 0; }
    cleanup_owned_host_resources() { return 0; }
    trap "exit_with_cleanup \$?" EXIT
    exit 0
  ' _ "${SCRIPT}"

  [ "${status}" -eq 70 ]
}

@test "report is published only after successful workspace cleanup" {
  report_path="${BATS_TEST_TMPDIR}/physical-attach-report.json"
  pending="${report_path}.pending"
  run env \
    PHYSICAL_ATTACH_LIBRARY_ONLY=1 \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      RUNNER_TEMP="$2"
      work_root="${RUNNER_TEMP}/physical-attach.success"
      mkdir -p "${work_root}"
      report_output="$3"
      report_pending="$4"
      printf "verified\n" >"${report_pending}"
      cleanup_owned_host_resources() { return 0; }
      sudo() { return 0; }
      exit_with_cleanup 0
    ' _ "${SCRIPT}" "${BATS_TEST_TMPDIR}" "${report_path}" "${pending}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${report_path}")" = "verified" ]
  [ ! -e "${pending}" ]
}

@test "workspace cleanup failure suppresses a pending successful report" {
  report_path="${BATS_TEST_TMPDIR}/failed-physical-attach-report.json"
  pending="${report_path}.pending"
  run env \
    PHYSICAL_ATTACH_LIBRARY_ONLY=1 \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      RUNNER_TEMP="$2"
      work_root="${RUNNER_TEMP}/physical-attach.failure"
      mkdir -p "${work_root}"
      report_output="$3"
      report_pending="$4"
      printf "must-not-publish\n" >"${report_pending}"
      cleanup_owned_host_resources() { return 0; }
      sudo() { return 0; }
      rm() {
        if test "${*: -1}" = "${work_root}"; then
          return 1
        fi
        command rm "$@"
      }
      exit_with_cleanup 0
    ' _ "${SCRIPT}" "${BATS_TEST_TMPDIR}" "${report_path}" "${pending}"

  [ "${status}" -eq 70 ]
  [ ! -e "${report_path}" ]
  [ ! -e "${pending}" ]
}

@test "report publication rejects a directory substituted after cleanup" {
  report_path="${BATS_TEST_TMPDIR}/substituted-report"
  pending="${BATS_TEST_TMPDIR}/substituted-report.pending"
  run env \
    PHYSICAL_ATTACH_LIBRARY_ONLY=1 \
    bash -c '
      set -Eeuo pipefail
      source "$1"
      work_root=
      report_output="$2"
      report_pending="$3"
      printf "must-not-move-into-directory\n" >"${report_pending}"
      cleanup() {
        mkdir "${report_output}"
        return 0
      }
      exit_with_cleanup 0
    ' _ "${SCRIPT}" "${report_path}" "${pending}"

  [ "${status}" -eq 70 ]
  [ -d "${report_path}" ]
  [ ! -e "${pending}" ]
  [ -z "$(find "${report_path}" -mindepth 1 -print -quit)" ]
}

@test "permit preflight directories use the fixed unprivileged identity" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    sudo() { printf "%s\n" "$*"; }
    prepare_preflight_directories "$2/state/nonces" "$2/state/output"
    test "$(stat -c "%a" "$2/state")" = 755
  ' _ "${SCRIPT}" "${BATS_TEST_TMPDIR}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"-m 0700 -o 10002 -g 10002 ${BATS_TEST_TMPDIR}/state/nonces"* ]]
  [[ "${output}" == *"-m 0755 -o 10002 -g 10002 ${BATS_TEST_TMPDIR}/state/output"* ]]
}

@test "denial and replay cases invoke the real preflight entrypoint" {
  run grep -Fc 'expect_preflight_denial' "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [ "${output}" -eq 4 ]

  run grep -F 'authorize-offline-test' "${MODULES}/authorization.sh"
  [ "${status}" -eq 0 ]

  run grep -F 'require_empty_nonce_store' "${SCRIPT}"
  [ "${status}" -eq 0 ]

  run grep -F 'offline attestation signature verification failed' \
    "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "CAN cleanup rejects a residual fixed network" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    project=physical-attach-test
    can_compose_created=1
    can_compose() { return 0; }
    docker() {
      case "$1 ${2:-}" in
        "network inspect")
          return 1
          ;;
        "network ls")
          printf "leftover-network\n"
          ;;
        "info ")
          return 0
          ;;
        *)
          return 64
          ;;
      esac
    }
    cleanup_owned_host_resources
  ' _ "${SCRIPT}"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"CAN observation network remains after cleanup"* ]]
}

@test "pre-existing global host resources fail closed before mutation" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    work_root="$(mktemp -d)"
    trap "rm -rf -- \"${work_root}\"" EXIT
    project=physical-attach-test
    vcan_interface=vcantest0001
    can_unit="robotics-can-observation@${vcan_interface}.service"
    sudo() {
      if test "$1" = systemctl && test "$2" = cat; then
        return 1
      fi
      printf "unexpected host mutation: %s\n" "$*" >&2
      return 99
    }
    docker() {
      if test "$1" = network && test "$2" = inspect &&
        test "$3" = robotics-can-observation; then
        return 0
      fi
      printf "unexpected Docker mutation: %s\n" "$*" >&2
      return 99
    }
    prepare_vcan_gateway
  ' _ "${SCRIPT}"
  [ "${status}" -eq 73 ]
  [[ "${output}" == *"refusing to reuse an existing Docker network"* ]]
  [[ "${output}" != *"unexpected host mutation"* ]]
  [[ "${output}" != *"unexpected Docker mutation"* ]]
}

@test "scenario manifest covers inputs and fails on mutation or omission" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    source_root="$(mktemp -d)"
    trap "rm -rf -- \"${source_root}\"" EXIT
    diff -u "$2" <(physical_attach_input_paths)
    while IFS= read -r path; do
      mkdir -p "${source_root}/$(dirname "${path}")"
      cp "${REPOSITORY_ROOT}/${path}" "${source_root}/${path}"
    done < <(physical_attach_input_paths)

    write_file_input_manifest "${source_root}" "${source_root}/first"
    scenario_manifest="${source_root}/first"
    first="$(physical_attach_scenario_sha256)"
    printf "\nmutation\n" >>"${source_root}/compose.edge-attach.yaml"
    write_file_input_manifest "${source_root}" "${source_root}/second"
    scenario_manifest="${source_root}/second"
    second="$(physical_attach_scenario_sha256)"
    test "${first}" != "${second}"

    rm "${source_root}/config/sros2/observer.policy.xml"
    if write_file_input_manifest "${source_root}" "${source_root}/third"; then
      printf "manifest accepted an omitted required input\n" >&2
      exit 1
    fi
  ' _ "${SCRIPT}" "${FIXTURES}/scenario-inputs.expected"
  [ "${status}" -eq 0 ]
}

@test "time evidence policy accepts only its fresh measurement window" {
  common_args=(
    --arg evidence_sha256 fcdc985da6acac1247b59e969557ca58ceeaa208bee2d4d01a7f69b4ab0f5be2
    --arg run_id test-run
    --arg source_revision local
    --arg workflow_run_attempt 1
    --arg workflow_run_id local
    --argjson future_tolerance_ns 0
    --argjson max_age_ns 300000000000
    --argjson max_window_ns 900000000000
    --slurpfile window "${FIXTURES}/time-evidence-window.json"
  )
  run jq -s -e \
    "${common_args[@]}" \
    --argjson now_ns 1785000002000000000 \
    -f "${FIXTURES}/verify-time-evidence.jq" \
    "${FIXTURES}/time-evidence.jsonl"
  [ "${status}" -eq 0 ]

  run bash -c '
    jq \
      ".resourceMetrics[0].scopeMetrics[0].metrics[1].gauge.dataPoints[0].asDouble = 21" \
        "$1" |
        jq -s -e \
          --arg evidence_sha256 "$3" \
          --arg run_id test-run \
          --arg source_revision local \
          --arg workflow_run_attempt 1 \
          --arg workflow_run_id local \
          --argjson future_tolerance_ns 0 \
          --argjson max_age_ns 300000000000 \
          --argjson max_window_ns 900000000000 \
          --argjson now_ns 1785000002000000000 \
          --slurpfile window "$4" \
          -f "$2"
    ' _ \
      "${FIXTURES}/time-evidence.jsonl" \
      "${FIXTURES}/verify-time-evidence.jq" \
      fcdc985da6acac1247b59e969557ca58ceeaa208bee2d4d01a7f69b4ab0f5be2 \
      "${FIXTURES}/time-evidence-window.json"
  [ "${status}" -eq 1 ]

  run jq -s -e \
    "${common_args[@]}" \
    --argjson now_ns 1785000302000000000 \
    -f "${FIXTURES}/verify-time-evidence.jq" \
    "${FIXTURES}/time-evidence.jsonl"
  [ "${status}" -eq 1 ]

  run jq -s -e \
    "${common_args[@]}" \
    --argjson now_ns 1784999999000000000 \
    -f "${FIXTURES}/verify-time-evidence.jq" \
    "${FIXTURES}/time-evidence.jsonl"
  [ "${status}" -eq 1 ]
}

@test "time evidence cannot be consumed twice" {
  run bash -c '
    set -Eeuo pipefail
    export GITHUB_RUN_ATTEMPT=1
    export GITHUB_RUN_ID=local
    export GITHUB_SHA=local
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    work_root="$(mktemp -d)"
    trap "rm -rf -- \"${work_root}\"" EXIT
    now_ns="$(date -u +%s%N)"
    sample_ns="$((now_ns - 1000000000))"
    start_ns="$((now_ns - 2000000000))"
    jq \
      --arg sample_ns "${sample_ns}" \
      "walk(if type == \"object\" and has(\"timeUnixNano\") then .timeUnixNano = \$sample_ns else . end)" \
      "$2" >"${work_root}/evidence.json"
    jq -n \
      --arg evidence_sha256 "$(sha256_file "${work_root}/evidence.json")" \
      --arg finished_at_unix_nano "${now_ns}" \
      --arg run_id replay-test \
      --arg source_revision local \
      --arg started_at_unix_nano "${start_ns}" \
      --arg workflow_run_attempt 1 \
      --arg workflow_run_id local \
      "{
        schema_version: \"physical-attach-time-window.v1\",
        run_id: \$run_id,
        workflow_run_id: \$workflow_run_id,
        workflow_run_attempt: \$workflow_run_attempt,
        source_revision: \$source_revision,
        started_at_unix_nano: \$started_at_unix_nano,
        finished_at_unix_nano: \$finished_at_unix_nano,
        evidence_sha256: \$evidence_sha256
      }" >"${work_root}/window.json"
    ROBOTICS_TIME_EVIDENCE="${work_root}/evidence.json"
    ROBOTICS_TIME_EVIDENCE_WINDOW="${work_root}/window.json"
    ROBOTICS_TIME_EVIDENCE_RUN_ID=replay-test
    ROBOTICS_TIME_EVIDENCE_REPLAY_DIR="${work_root}/consumed"
    verify_time_evidence
    if verify_time_evidence; then
      printf "replayed evidence was accepted\n" >&2
      exit 1
    fi
  ' _ "${SCRIPT}" "${FIXTURES}/time-evidence.jsonl"
  [ "${status}" -eq 0 ]
}

@test "coordinator uses Rekor-backed Cosign and contains no Python fallback" {
  run grep -R -F -- '--insecure-ignore-tlog' "${SCRIPT}" "${FIXTURES}"
  [ "${status}" -eq 1 ]

  run grep -R -F -- '--tlog-upload=false' "${SCRIPT}" "${FIXTURES}"
  [ "${status}" -eq 1 ]

  run grep -F -- '--with-default-services' \
    "${MODULES}/authorization.sh"
  [ "${status}" -eq 0 ]

  run grep -F -- '--signing-config keys/signing-config.json' \
    "${MODULES}/authorization.sh"
  [ "${status}" -eq 0 ]

  run grep -R -E 'python(3)?([[:space:]]|$)' \
    "${SCRIPT}" "${MODULES}" "${FIXTURES}"
  [ "${status}" -eq 1 ]
}

@test "only the isolated offline verifier may bypass the transparency log" {
  run bash -ceu '
    script="$1"
    keyless="$(
      sed -n \
        "/^verify_keyless_attestation()/,/^verify_offline_attestation()/p" \
        "${script}"
    )"
    offline="$(
      sed -n \
        "/^verify_offline_attestation()/,/^authorize_common()/p" \
        "${script}"
    )"
    ! grep -F -- "--insecure-ignore-tlog" <<<"${keyless}"
    grep -F -- "--insecure-ignore-tlog" <<<"${offline}"
  ' _ "${REPOSITORY_ROOT}/docker/permit-preflight/permit-preflight"
  [ "${status}" -eq 0 ]
}
