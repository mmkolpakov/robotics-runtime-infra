#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  SCRIPT="${REPOSITORY_ROOT}/scripts/ci/physical-attach.sh"
  MODULES="${REPOSITORY_ROOT}/scripts/ci/physical-attach"
  FIXTURES="${BATS_TEST_DIRNAME}/physical-attach"
}

@test "fails closed when required runtime inputs are absent" {
  run env -i PATH="${PATH}" bash -c '
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    check_prerequisites
  ' _ "${SCRIPT}"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"required environment variable is unset"* ]]
}

@test "preflight accepts one JSON document and lowercase sha256 only" {
  run bash -c '
    set -Eeuo pipefail
    source <(sed "/^command_name=/,\$d" "$1")
    temporary="$(mktemp -d)"
    trap "rm -rf -- \"${temporary}\"" EXIT
    printf "%s\n" "{}" >"${temporary}/one.json"
    printf "%s\n%s\n" "{}" "{}" >"${temporary}/two.json"
    assert_single_json_document "${temporary}/one.json"
    ! (assert_single_json_document "${temporary}/two.json")
    require_sha256_digest "sha256:$(printf "%064d" 1)" verifier
    ! (require_sha256_digest \
      "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
      verifier)
  ' _ "${REPOSITORY_ROOT}/docker/permit-preflight/core.sh"

  [ "${status}" -eq 0 ]
}

@test "DSSE verification cannot overwrite its caller output path" {
  run bash -c '
    set -Eeuo pipefail
    source <(sed "/^command_name=/,\$d" "$1")
    temporary="$(mktemp -d)"
    trap "rm -rf -- \"${temporary}\"" EXIT
    printf "%s\n" "{}" >"${temporary}/statement.json"
    jq -n \
      --arg payload "$(printf "%s" "{}" | base64 -w0)" \
      "{
        mediaType: \"application/vnd.dev.sigstore.bundle.v0.3+json\",
        dsseEnvelope: {
          payloadType: \"application/vnd.in-toto+json\",
          payload: \$payload
        }
      }" >"${temporary}/bundle.json"
    output=caller-output
    assert_bundle_statement \
      "${temporary}/statement.json" \
      "${temporary}/bundle.json" \
      "${temporary}/decoded-statement.json"
    test "${output}" = caller-output
  ' _ "${REPOSITORY_ROOT}/docker/permit-preflight/core.sh"

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
      \$permit[0].image_digest == \"sha256:$(printf "%064d" 1)\"
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

@test "physical Compose configuration is validated before host mutation" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    marker="$2"
    acquire_host_lock() { :; }
    verify_verifier_image_digest() { :; }
    validate_physical_compose_model() { return 65; }
    prepare_pty_pair() { touch "${marker}"; }
    run_setup
  ' _ "${SCRIPT}" "${BATS_TEST_TMPDIR}/host-mutated"
  [ "${status}" -eq 65 ]
  [ ! -e "${BATS_TEST_TMPDIR}/host-mutated" ]
}

@test "source verifier is frozen to its local Docker image ID" {
  local source_digest="sha256:$(printf '%064d' 7)"

  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    ROBOTICS_RUNTIME_MODE=source
    PERMIT_PREFLIGHT_IMAGE=permit-preflight:local
    expected="$2"
    docker() {
      test "$1" = image
      test "$2" = inspect
      printf "%s\n" "${expected}"
    }
    verify_verifier_image_digest
    test "${PERMIT_PREFLIGHT_IMAGE}" = "${expected}"
  ' _ "${SCRIPT}" "${source_digest}"
  [ "${status}" -eq 0 ]
}

@test "released verifier requires the canonical attested digest" {
  local release_digest="sha256:$(printf '%064d' 8)"

  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    work_root="$3"
    mkdir -p "${work_root}"
    GH_TOKEN=test-token
    ROBOTICS_RELEASE_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
    ROBOTICS_RELEASE_SOURCE_REF=refs/tags/v0.8.0
    gh() {
      test "$1" = attestation
      test "$2" = verify
      [[ " $* " == *" --repo mmkolpakov/robotics-runtime-infra "* ]]
      [[ " $* " == *" --signer-workflow mmkolpakov/robotics-runtime-infra/.github/workflows/release-image.yml "* ]]
      [[ " $* " == *" --source-digest ${ROBOTICS_RELEASE_SOURCE_SHA} "* ]]
      [[ " $* " == *" --source-ref ${ROBOTICS_RELEASE_SOURCE_REF} "* ]]
      [[ " $* " == *" --deny-self-hosted-runners "* ]]
      [[ " $* " == *" --bundle-from-oci "* ]]
      printf "[{}]\n"
    }
    docker() {
      test "$1" = image
      test "$2" = inspect
    }
    ROBOTICS_RUNTIME_MODE=released
    PERMIT_PREFLIGHT_IMAGE="ghcr.io/mmkolpakov/robotics-runtime-infra/permit-preflight:v1@$2"
    verify_verifier_image_digest
    test -s "${ROBOTICS_VERIFIER_PROVENANCE_EVIDENCE}"
  ' _ "${SCRIPT}" "${release_digest}" "${BATS_TEST_TMPDIR}/released-verifier"
  [ "${status}" -eq 0 ]

  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    docker() { return 0; }
    ROBOTICS_RUNTIME_MODE=released
    PERMIT_PREFLIGHT_IMAGE="ghcr.io/example/permit:v1@$2"
    verify_verifier_image_digest
  ' _ "${SCRIPT}" "${release_digest}"
  [ "${status}" -eq 65 ]
  [[ "${output}" == *"outside the trusted repository"* ]]
}

@test "released verifier provenance is checked before local image use" {
  local digest="sha256:$(printf '%064d' 9)"
  local marker="${BATS_TEST_TMPDIR}/docker-was-called"

  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    work_root="$4"
    mkdir -p "${work_root}"
    GH_TOKEN=test-token
    ROBOTICS_RUNTIME_MODE=released
    ROBOTICS_RELEASE_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
    ROBOTICS_RELEASE_SOURCE_REF=refs/tags/v0.8.0
    PERMIT_PREFLIGHT_IMAGE="ghcr.io/mmkolpakov/robotics-runtime-infra/permit-preflight:v0.8.0@$2"
    gh() { return 1; }
    docker() {
      touch "$3"
      return 0
    }
    verify_verifier_image_digest
  ' _ "${SCRIPT}" "${digest}" "${marker}" \
    "${BATS_TEST_TMPDIR}/rejected-verifier"

  [ "${status}" -ne 0 ]
  [ ! -e "${marker}" ]
}

@test "observer startup preserves the failure code and emits compose diagnostics" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    real_compose() {
      case " $* " in
        *" run "*)
          return 65
          ;;
        *" ps --all "*)
          printf "physical-permit-preflight exited 65\n"
          ;;
        *" logs --no-color "*)
          printf "permit validation failed\n"
          ;;
        *)
          return 64
          ;;
      esac
    }
    set +e
    run_observer_script observer-listen.sh
    status=$?
    set -e
    test "${status}" -eq 65
  ' _ "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"physical-permit-preflight exited 65"* ]]
  [[ "${output}" == *"permit validation failed"* ]]
}

@test "observer wait accepts a first message and reports ROS failures" {
  wait_script="${BATS_TEST_TMPDIR}/observer-wait.sh"
  awk '
    /^set \+e$/ {copy = 1}
    copy {print}
  ' "${FIXTURES}/observer-listen.sh" >"${wait_script}"

  timeout() {
    printf 'data: fixture\n'
    return 0
  }
  export -f timeout
  run bash "${wait_script}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"data: fixture"* ]]

  timeout() {
    printf 'topic subscription failed\n' >&2
    return 1
  }
  export -f timeout
  run bash "${wait_script}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"topic subscription failed"* ]]
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

@test "nonce inspection uses privilege and fails closed" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    sudo() {
      test "$1" = find
      printf "%s/consumed\n" "$2"
    }
    require_empty_nonce_store "$2"
  ' _ "${SCRIPT}" "${BATS_TEST_TMPDIR}/nonces"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"denied permit consumed a nonce"* ]]

  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    sudo() { return 42; }
    require_empty_nonce_store "$2"
  ' _ "${SCRIPT}" "${BATS_TEST_TMPDIR}/nonces"
  [ "${status}" -eq 70 ]
  [[ "${output}" == *"could not inspect the permit nonce store"* ]]
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

@test "CAN cleanup stops the owned unit without resetting an unloaded instance" {
  run bash -c '
    set -Eeuo pipefail
    export PHYSICAL_ATTACH_LIBRARY_ONLY=1
    source "$1"
    can_service_started=1
    can_unit=robotics-can-observation@vcantest0001.service
    sudo() {
      case "$*" in
        "systemctl stop ${can_unit}")
          return 0
          ;;
        "systemctl is-active --quiet ${can_unit}")
          return 3
          ;;
        *)
          printf "unexpected privileged command: %s\n" "$*" >&2
          return 99
          ;;
      esac
    }
    cleanup_owned_host_resources
  ' _ "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [[ "${output}" != *"unexpected privileged command"* ]]
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

@test "only the isolated offline verifier may bypass the transparency log" {
  run bash -ceu '
    production="$1"
    core="$2"
    ci="$3"
    ! grep -F -- "--insecure-ignore-tlog" "${production}" "${core}"
    ! grep -F -- "authorize-offline-test" "${production}" "${core}"
    ! grep -F -- "verify-offline-test-attestation" "${production}" "${core}"
    grep -F -- "--insecure-ignore-tlog" "${ci}"
    grep -F -- "authorize-offline-test" "${ci}"
    grep -F -- "verify-offline-test-attestation" "${ci}"
  ' _ \
    "${REPOSITORY_ROOT}/docker/permit-preflight/permit-preflight" \
    "${REPOSITORY_ROOT}/docker/permit-preflight/core.sh" \
    "${REPOSITORY_ROOT}/docker/permit-preflight/permit-preflight-ci"
  [ "${status}" -eq 0 ]
}
