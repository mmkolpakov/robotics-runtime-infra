#!/usr/bin/env bash
# Coordinator state is shared with the sourced physical-attach modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

readonly CASES=(
  positive
  expired-permit
  wrong-target
  wrong-signer
  command-publish-denied
)

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd -P
)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(
  cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1
  pwd -P
)"
readonly REPOSITORY_ROOT
readonly PHYSICAL_ATTACH_MODULE_ROOT="${SCRIPT_DIR}/physical-attach"
readonly PHYSICAL_ATTACH_FIXTURE_ROOT="${REPOSITORY_ROOT}/test/ci/physical-attach"
readonly PERMIT_PREFLIGHT_UID=10002
readonly PERMIT_PREFLIGHT_GID=10002

# shellcheck source=physical-attach/devices.sh
# shellcheck disable=SC1091
source "${PHYSICAL_ATTACH_MODULE_ROOT}/devices.sh"
# shellcheck source=physical-attach/authorization.sh
# shellcheck disable=SC1091
source "${PHYSICAL_ATTACH_MODULE_ROOT}/authorization.sh"
# shellcheck source=physical-attach/observation.sh
# shellcheck disable=SC1091
source "${PHYSICAL_ATTACH_MODULE_ROOT}/observation.sh"

work_root=
project=
attach_project=
security_project=
attach_network=
can_unit=
denied_can_network=
serial_bridge_pid=
host_lock_fd=
security_dir=
scenario_manifest=
# These values are written or consumed by sourced physical-attach modules.
# shellcheck disable=SC2034
time_measured_at=
attach_network_created=0
can_compose_created=0
can_service_started=0
denied_can_network_created=0
real_compose_started=0
security_compose_used=0
systemd_template_created=0
vcan_created=0
systemd_template_sha256=
vcan_ifindex_owned=
vcan_interface=
# These two paths are populated and consumed by the sourced device module.
# shellcheck disable=SC2034
serial_host=
# shellcheck disable=SC2034
serial_target=
case_report=
report_output=
report_pending=

usage() {
  cat <<'EOF'
usage: physical-attach.sh [run|--list-cases|--check-prerequisites]
EOF
}

list_cases() {
  printf '%s\n' "${CASES[@]}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'required command is unavailable: %s\n' "$1" >&2
    return 1
  }
}

require_environment() {
  local name
  for name in \
    BENCHMARK_IMAGE \
    CAN_CLIENT_IMAGE \
    COSIGN_PASSWORD \
    OBSERVER_IMAGE \
    PERMIT_PREFLIGHT_IMAGE \
    ROBOTICS_COSIGN_IMAGE_DIGEST \
    ROBOTICS_TIME_EVIDENCE \
    ROBOTICS_TIME_EVIDENCE_RUN_ID \
    ROBOTICS_TIME_EVIDENCE_WINDOW; do
    test -n "${!name:-}" || {
      printf 'required environment variable is unset: %s\n' "${name}" >&2
      return 1
    }
  done
}

check_prerequisites() {
  local command_name
  local fixture

  require_environment
  for command_name in \
    awk \
    candump \
    cansend \
    date \
    docker \
    find \
    flock \
    git \
    grep \
    head \
    install \
    ip \
    jq \
    mktemp \
    openssl \
    readlink \
    sha256sum \
    socat \
    sort \
    ss \
    stat \
    sudo \
    systemctl \
    timeout \
    tr \
    wc; do
    require_command "${command_name}"
  done
  test -s "${ROBOTICS_TIME_EVIDENCE}" || {
    printf 'time evidence is absent or empty: %s\n' \
      "${ROBOTICS_TIME_EVIDENCE}" >&2
    return 1
  }
  test -s "${ROBOTICS_TIME_EVIDENCE_WINDOW}" || {
    printf 'time evidence window is absent or empty: %s\n' \
      "${ROBOTICS_TIME_EVIDENCE_WINDOW}" >&2
    return 1
  }
  for fixture in \
    authorization-template.json \
    policy-input.jq \
    report.json \
    runtime-manifest.jq \
    target-evidence.json \
    time-evidence-window.json \
    verify-time-evidence.jq \
    observer-command-denied.sh \
    observer-listen.sh \
    observer-unsecured-source-denied.sh; do
    test -r "${PHYSICAL_ATTACH_FIXTURE_ROOT}/${fixture}" || {
      printf 'physical-attach fixture is unreadable: %s\n' "${fixture}" >&2
      return 1
    }
  done
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

permit_run() {
  local mount_root="$1"
  shift
  docker run --rm \
    --volume "${mount_root}:/work" \
    --workdir /work \
    "${PERMIT_PREFLIGHT_IMAGE}" "$@"
}

cosign_run() {
  local mount_root="$1"
  shift
  docker run --rm \
    --env COSIGN_PASSWORD \
    --volume "${mount_root}:/work" \
    --workdir /work \
    --entrypoint /usr/local/bin/cosign \
    "${PERMIT_PREFLIGHT_IMAGE}" "$@"
}

permit_chmod() {
  local mount_root="$1"
  local mode="$2"
  local path="$3"
  docker run --rm \
    --user 0 \
    --volume "${mount_root}:/work" \
    --entrypoint /bin/chmod \
    "${PERMIT_PREFLIGHT_IMAGE}" "${mode}" "/work/${path}"
}

opa_eval() {
  local mount_root="$1"
  shift
  docker run --rm \
    --volume "${mount_root}:/work:ro" \
    --workdir /work \
    --entrypoint /usr/local/bin/opa \
    "${PERMIT_PREFLIGHT_IMAGE}" "$@"
}

can_compose() {
  docker compose \
    -p "${project}" \
    -f "${REPOSITORY_ROOT}/compose.yaml" \
    -f "${REPOSITORY_ROOT}/compose.can-observation.yaml" \
    --profile can-observation "$@"
}

security_compose() {
  docker compose \
    -p "${security_project}" \
    -f "${REPOSITORY_ROOT}/compose.yaml" \
    -f "${REPOSITORY_ROOT}/compose.security.yaml" "$@"
}

real_compose() {
  docker compose \
    -p "${attach_project}" \
    -f "${REPOSITORY_ROOT}/compose.yaml" \
    -f "${REPOSITORY_ROOT}/compose.edge-attach.yaml" \
    -f "${REPOSITORY_ROOT}/compose.real-observation.yaml" \
    -f "${REPOSITORY_ROOT}/compose.real-observation.test.yaml" "$@"
}

cleanup() {
  local status="${1:-0}"
  set +e
  if test "${real_compose_started}" -eq 1; then
    real_compose \
      --profile real-observation \
      --profile real-observation-test \
      --profile real-observation-test-negative \
      down --volumes --remove-orphans >/dev/null 2>&1 || status=70
  fi
  if test "${security_compose_used}" -eq 1; then
    security_compose --profile security-init \
      down --volumes --remove-orphans >/dev/null 2>&1 || status=70
  fi
  cleanup_owned_host_resources || status=70
  if test "${status}" -ne 0 && test -n "${work_root}"; then
    find "${work_root}" -maxdepth 2 -type f \
      ! -name '*.key' \
      ! -name '*.sigstore.json' \
      -print >&2
  fi
  if test -n "${work_root}"; then
    case "${work_root}" in
      "${RUNNER_TEMP:-${TMPDIR:-/tmp}}"/physical-attach.*)
        sudo chown -hR "$(id -u):$(id -g)" "${work_root}" ||
          status=70
        rm -rf -- "${work_root}" || status=70
        ;;
      *)
        printf 'refusing to remove unexpected work directory: %s\n' \
          "${work_root}" >&2
        status=70
        ;;
      esac
  fi
  return "${status}"
}

release_host_lock() {
  local status="$1"

  if test -n "${host_lock_fd}"; then
    flock --unlock "${host_lock_fd}" >/dev/null 2>&1 || status=70
    exec {host_lock_fd}>&-
    host_lock_fd=
  fi
  return "${status}"
}

exit_with_cleanup() {
  local status="$1"
  local cleanup_status

  trap - EXIT HUP INT TERM
  set +e
  cleanup "${status}"
  cleanup_status=$?
  if test "${cleanup_status}" -eq 0 &&
    test "${status}" -eq 0 &&
    test -n "${report_pending}" &&
    test -n "${report_output}"; then
    if test -e "${report_output}" || test -L "${report_output}"; then
      printf 'physical-attach report path changed before publication: %s\n' \
        "${report_output}" >&2
      cleanup_status=70
    elif mv -fT -- "${report_pending}" "${report_output}" &&
      test -f "${report_output}" &&
      test ! -L "${report_output}"; then
      report_pending=
    else
      cleanup_status=70
    fi
  elif test -n "${report_pending}"; then
    rm -f -- "${report_pending}" || cleanup_status=70
    report_pending=
  fi
  if test -n "${report_pending}"; then
    rm -f -- "${report_pending}" || cleanup_status=70
    report_pending=
  fi
  release_host_lock "${cleanup_status}"
  cleanup_status=$?
  exit "${cleanup_status}"
}

initialize_run() {
  local host_resource_token
  local run_token
  work_root="$(
    mktemp -d \
      "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/physical-attach.XXXXXXXX"
  )"
  run_token="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"
  host_resource_token="$(
    printf '%s' "${run_token}" | sha256sum | awk '{print substr($1, 1, 8)}'
  )"
  project="physical-attach-${run_token}"
  attach_project="${project}-sros2"
  security_project="${project}-security"
  attach_network="${project}-network"
  vcan_interface="vcan${host_resource_token}"
  can_unit="robotics-can-observation@${vcan_interface}.service"
  # These paths are consumed by sourced physical-attach modules.
  # shellcheck disable=SC2034
  security_dir="${work_root}/security"
  # shellcheck disable=SC2034
  scenario_manifest="${work_root}/scenario-inputs.manifest"
  case_report="${work_root}/physical-attach-report.json"
  chmod 1777 "${work_root}"
  cp "${PHYSICAL_ATTACH_FIXTURE_ROOT}/report.json" "${case_report}"
  trap 'exit_with_cleanup $?' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

prepare_report_destination() {
  report_output="${ROBOTICS_PHYSICAL_ATTACH_REPORT:-${REPOSITORY_ROOT}/artifacts/test-results/physical-attach.json}"
  mkdir -p "$(dirname "${report_output}")"
  if test -L "${report_output}" ||
    { test -e "${report_output}" && test ! -f "${report_output}"; }; then
    printf 'physical-attach report path is not a regular file: %s\n' \
      "${report_output}" >&2
    return 73
  fi
  rm -f -- "${report_output}"
}

record_case() {
  local name="$1"
  jq \
    --arg name "${name}" \
    '.cases += [{name: $name, status: "passed"}]' \
    "${case_report}" >"${case_report}.tmp"
  mv "${case_report}.tmp" "${case_report}"
}

run_setup() {
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
}

run_case_positive() {
  local issued_at="$1"
  local expires_at="$2"
  local target_identity="$3"
  local case_dir="${work_root}/positive"

  write_permit_case \
    "${case_dir}" "${issued_at}" "${expires_at}" "${target_identity}"
  authorize_equivalent_policy_case "${case_dir}"
  write_runtime_manifest_input
  start_sros2_observer "${case_dir}"
  prepare_preflight_directories \
    "${work_root}/preflight-positive/nonces" \
    "${work_root}/preflight-replay/output"
  expect_preflight_denial \
    "${case_dir}" \
    "permit nonce was already consumed" \
    "${work_root}/preflight-positive/nonces" \
    "${work_root}/preflight-replay/output/execution-verification.json" \
    77
  record_case positive
}

run_case_expired_permit() {
  local issued_at="$1"
  local expires_at="$2"
  local target_identity="$3"
  local case_dir="${work_root}/expired"
  local historical_evidence="${case_dir}/target-evidence.json"

  mkdir -p "${case_dir}"
  jq \
    --arg checked_at "${issued_at}" \
    '.checked_at = $checked_at' \
    "${work_root}/target-evidence.json" >"${historical_evidence}"
  write_permit_case \
    "${case_dir}" \
    "${issued_at}" \
    "${expires_at}" \
    "${target_identity}" \
    "${historical_evidence}"
  sign_and_verify_role "${case_dir}" operator
  sign_and_verify_role "${case_dir}" approver
  expect_policy_denial "${case_dir}" "permit has expired"
  prepare_preflight_directories \
    "${work_root}/preflight-expired/nonces" \
    "${work_root}/preflight-expired/output"
  expect_preflight_denial \
    "${case_dir}" \
    "permit has expired" \
    "${work_root}/preflight-expired/nonces" \
    "${work_root}/preflight-expired/output/execution-verification.json" \
    65
  require_empty_nonce_store "${work_root}/preflight-expired/nonces"
  record_case expired-permit
}

run_case_wrong_target() {
  local wrong_target_identity="$1"
  local case_dir="${work_root}/wrong-target"

  cp -a "${work_root}/positive" "${case_dir}"
  jq \
    --arg identity "${wrong_target_identity}" \
    '.target.identity_sha256 = $identity' \
    "${case_dir}/execution-request.json" \
    >"${case_dir}/execution-request.json.tmp"
  mv \
    "${case_dir}/execution-request.json.tmp" \
    "${case_dir}/execution-request.json"
  expect_policy_denial \
    "${case_dir}" \
    "observed target identity does not match the permit"
  prepare_preflight_directories \
    "${work_root}/preflight-wrong-target/nonces" \
    "${work_root}/preflight-wrong-target/output"
  expect_preflight_denial \
    "${case_dir}" \
    "observed target identity does not match the permit" \
    "${work_root}/preflight-wrong-target/nonces" \
    "${work_root}/preflight-wrong-target/output/execution-verification.json" \
    65
  require_empty_nonce_store "${work_root}/preflight-wrong-target/nonces"
  record_case wrong-target
}

run_case_wrong_signer() {
  local case_dir="${work_root}/wrong-signer"

  cp -a "${work_root}/positive" "${case_dir}"
  rm -f "${case_dir}/approver.sigstore.json"
  cp \
    "${case_dir}/operator.sigstore.json" \
    "${case_dir}/approver.sigstore.json"
  chmod 0444 "${case_dir}/approver.sigstore.json"
  verify_wrong_signer "${case_dir}"
  prepare_preflight_directories \
    "${work_root}/preflight-wrong-signer/nonces" \
    "${work_root}/preflight-wrong-signer/output"
  expect_preflight_denial \
    "${case_dir}" \
    "offline attestation signature verification failed" \
    "${work_root}/preflight-wrong-signer/nonces" \
    "${work_root}/preflight-wrong-signer/output/execution-verification.json" \
    65
  require_empty_nonce_store "${work_root}/preflight-wrong-signer/nonces"
  record_case wrong-signer
}

run_case_command_publish_denied() {
  verify_command_publish_denied
  verify_unsecured_source_denied
  record_case command-publish-denied
}

run_cases() {
  local target_identity="$1"
  local checked_epoch
  local now_epoch
  local issued_epoch
  local issued_at
  local expires_at
  local expired_issued_at
  local expired_at
  local wrong_target_identity

  now_epoch="$(date -u +%s)"
  checked_epoch="$(date -u -d "${time_measured_at}" +%s)"
  issued_epoch="$((now_epoch - 30))"
  if test "${issued_epoch}" -lt "${checked_epoch}"; then
    issued_epoch="${checked_epoch}"
  fi
  issued_at="$(date -u -d "@${issued_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
  expires_at="$(date -u -d "@$((now_epoch + 900))" +%Y-%m-%dT%H:%M:%SZ)"
  expired_issued_at="$(
    date -u -d "@$((now_epoch - 1200))" +%Y-%m-%dT%H:%M:%SZ
  )"
  expired_at="$(date -u -d "@$((now_epoch - 600))" +%Y-%m-%dT%H:%M:%SZ)"
  wrong_target_identity="$(
    printf 'wrong-target' | sha256sum | awk '{print $1}'
  )"

  run_case_positive "${issued_at}" "${expires_at}" "${target_identity}"
  run_case_expired_permit \
    "${expired_issued_at}" "${expired_at}" "${target_identity}"
  run_case_wrong_target "${wrong_target_identity}"
  run_case_wrong_signer
  run_case_command_publish_denied
}

finalize_run() {
  jq -e --argjson expected "$(printf '%s\n' "${CASES[@]}" | jq -R . | jq -s .)" '
    [.cases[].name] == $expected and
    all(.cases[]; .status == "passed")
  ' "${case_report}" >/dev/null
  test -n "${report_output}"
  test ! -e "${report_output}" && test ! -L "${report_output}" || {
    printf 'physical-attach report path changed during the run: %s\n' \
      "${report_output}" >&2
    return 73
  }
  report_pending="$(mktemp "${report_output}.pending.XXXXXXXX")"
  install -m 0644 "${case_report}" "${report_pending}"
}

run_scenario() {
  prepare_report_destination
  check_prerequisites
  cd "${REPOSITORY_ROOT}"
  initialize_run
  run_setup
  run_cases "$(<"${work_root}/target-identity.sha256")"
  finalize_run
}

main() {
  case "${1:-run}" in
    run)
      test "$#" -le 1 || {
        usage >&2
        return 64
      }
      run_scenario
      ;;
    --list-cases)
      test "$#" -eq 1 || {
        usage >&2
        return 64
      }
      list_cases
      ;;
    --check-prerequisites)
      test "$#" -eq 1 || {
        usage >&2
        return 64
      }
      check_prerequisites
      ;;
    *)
      usage >&2
      return 64
      ;;
  esac
}

if test "${PHYSICAL_ATTACH_LIBRARY_ONLY:-0}" != 1; then
  main "$@"
fi
