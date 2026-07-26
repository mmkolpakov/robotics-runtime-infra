#!/usr/bin/env bash

# This module is sourced by physical-attach.sh and uses its coordinator state.
# shellcheck disable=SC2034,SC2154

acquire_host_lock() {
  local lock_file="${ROBOTICS_PHYSICAL_ATTACH_LOCK_FILE:-/run/lock/robotics-runtime-infra-physical-attach.lock}"

  exec {host_lock_fd}>"${lock_file}"
  flock --exclusive --nonblock "${host_lock_fd}" || {
    printf 'physical attach host resources are locked: %s\n' \
      "${lock_file}" >&2
    return 75
  }
}

verify_permit_image_digest() {
  local actual
  actual="$(
    docker image inspect "${PERMIT_PREFLIGHT_IMAGE}" --format '{{.Id}}'
  )"
  test "${ROBOTICS_COSIGN_IMAGE_DIGEST}" = "${actual}" || {
    printf 'ROBOTICS_COSIGN_IMAGE_DIGEST does not identify %s\n' \
      "${PERMIT_PREFLIGHT_IMAGE}" >&2
    return 65
  }
}

validate_physical_compose_model() {
  real_compose \
    --profile real-observation \
    --profile real-observation-test \
    --profile real-observation-test-negative \
    config --quiet
}

remove_network_owned_by_run() {
  local network="$1"
  local label="$2"
  local owner

  if ! docker network inspect "${network}" >/dev/null 2>&1; then
    return 0
  fi
  owner="$(
    docker network inspect \
      --format "{{ index .Labels \"${label}\" }}" \
      "${network}"
  )"
  test "${owner}" = "${project}" || {
    printf 'refusing to remove a network not owned by this run: %s\n' \
      "${network}" >&2
    return 70
  }
  docker network rm "${network}" >/dev/null
}

cleanup_owned_host_resources() {
  local can_networks=
  local unsafe=0

  if test "${can_compose_created}" -eq 1; then
    if docker network inspect robotics-can-observation >/dev/null 2>&1 &&
      test "$(
        docker network inspect \
          --format '{{ index .Labels "com.docker.compose.project" }}' \
          robotics-can-observation
      )" != "${project}"; then
      printf 'refusing to remove a CAN network not owned by this run\n' >&2
      unsafe=1
    else
      can_compose down --volumes --remove-orphans >/dev/null 2>&1 ||
        unsafe=1
    fi
  fi
  if test "${denied_can_network_created}" -eq 1; then
    remove_network_owned_by_run \
      "${denied_can_network}" \
      org.robotics-runtime.owner || unsafe=1
  fi
  if test "${attach_network_created}" -eq 1; then
    remove_network_owned_by_run \
      "${attach_network}" \
      org.robotics-runtime.owner || unsafe=1
  fi
  if test "${can_service_started}" -eq 1; then
    sudo systemctl stop "${can_unit}" >/dev/null 2>&1 || unsafe=1
    sudo systemctl reset-failed "${can_unit}" >/dev/null 2>&1 || unsafe=1
  fi
  if test "${systemd_template_created}" -eq 1; then
    if test ! -e /etc/systemd/system/robotics-can-observation@.service; then
      :
    elif test "$(
      sha256_file /etc/systemd/system/robotics-can-observation@.service
    )" = "${systemd_template_sha256}"; then
      sudo rm -f /etc/systemd/system/robotics-can-observation@.service ||
        unsafe=1
      sudo systemctl daemon-reload || unsafe=1
    else
      printf 'refusing to remove a modified systemd template\n' >&2
      unsafe=1
    fi
  fi
  if test "${vcan_created}" -eq 1; then
    if test ! -e "/sys/class/net/${vcan_interface}"; then
      :
    elif test "$(< "/sys/class/net/${vcan_interface}/ifindex")" = \
      "${vcan_ifindex_owned}"; then
      sudo ip link del "${vcan_interface}" >/dev/null 2>&1 || unsafe=1
    else
      printf 'refusing to remove a replaced host interface: %s\n' \
        "${vcan_interface}" >&2
      unsafe=1
    fi
  fi
  if test -n "${serial_bridge_pid}"; then
    if kill -0 "${serial_bridge_pid}" >/dev/null 2>&1; then
      kill "${serial_bridge_pid}" >/dev/null 2>&1 || unsafe=1
      wait "${serial_bridge_pid}" >/dev/null 2>&1 || true
    fi
    kill -0 "${serial_bridge_pid}" >/dev/null 2>&1 && unsafe=1
  fi
  if test -n "${attach_network}" &&
    docker network inspect "${attach_network}" >/dev/null 2>&1; then
    printf 'owned attach network remains after cleanup: %s\n' \
      "${attach_network}" >&2
    unsafe=1
  fi
  if test -n "${denied_can_network}" &&
    docker network inspect "${denied_can_network}" >/dev/null 2>&1; then
    printf 'owned denied CAN network remains after cleanup: %s\n' \
      "${denied_can_network}" >&2
    unsafe=1
  fi
  if test "${can_compose_created}" -eq 1; then
    can_networks="$(
      docker network ls \
        --quiet \
        --filter 'name=^robotics-can-observation$'
    )" || unsafe=1
    if test -n "${can_networks}"; then
      printf 'CAN observation network remains after cleanup: %s\n' \
        "${can_networks}" >&2
      unsafe=1
    fi
    if test -e /sys/class/net/robotics-can; then
      printf 'CAN observation bridge remains after cleanup: robotics-can\n' \
        >&2
      unsafe=1
    fi
  fi
  if test -n "${vcan_interface}" &&
    test -e "/sys/class/net/${vcan_interface}"; then
    printf 'owned virtual CAN interface remains after cleanup: %s\n' \
      "${vcan_interface}" >&2
    unsafe=1
  fi
  if test -n "${can_unit}" &&
    sudo systemctl is-active --quiet "${can_unit}"; then
    printf 'owned CAN service remains active after cleanup: %s\n' \
      "${can_unit}" >&2
    unsafe=1
  fi
  if test "${systemd_template_created}" -eq 1 &&
    test -e /etc/systemd/system/robotics-can-observation@.service; then
    printf 'CAN systemd template remains after cleanup\n' >&2
    unsafe=1
  fi
  if test "${can_compose_created}" -eq 1 ||
    test "${denied_can_network_created}" -eq 1 ||
    test "${attach_network_created}" -eq 1; then
    docker info >/dev/null 2>&1 || {
      printf 'Docker daemon could not be queried after cleanup\n' >&2
      unsafe=1
    }
  fi
  test "${unsafe}" -eq 0
}

prepare_pty_pair() {
  local serial_log="${work_root}/serial-socat.log"
  local received="${work_root}/serial-received.txt"
  local reverse_received="${work_root}/serial-reverse-received.txt"
  local reader_pid

  socat \
    pty,raw,echo=0,link="${work_root}/serial-host" \
    pty,raw,echo=0,link="${work_root}/serial-target" \
    >"${serial_log}" 2>&1 &
  # Cleanup is owned by the coordinator.
  # shellcheck disable=SC2034
  serial_bridge_pid=$!

  for _ in {1..50}; do
    if test -L "${work_root}/serial-host" &&
      test -L "${work_root}/serial-target"; then
      break
    fi
    sleep 0.1
  done
  test -L "${work_root}/serial-host"
  test -L "${work_root}/serial-target"
  # The evidence stage consumes both paths.
  # shellcheck disable=SC2034
  serial_host="$(readlink -f "${work_root}/serial-host")"
  # shellcheck disable=SC2034
  serial_target="$(readlink -f "${work_root}/serial-target")"
  test -c "${serial_host}"
  test -c "${serial_target}"

  timeout 5 head -n 1 "${serial_host}" >"${received}" &
  reader_pid=$!
  sleep 0.2
  printf 'target-to-host\n' >"${serial_target}"
  wait "${reader_pid}"
  grep -Fxq 'target-to-host' "${received}"

  timeout 5 head -n 1 "${serial_target}" >"${reverse_received}" &
  reader_pid=$!
  sleep 0.2
  printf 'host-to-target\n' >"${serial_host}"
  wait "${reader_pid}"
  grep -Fxq 'host-to-target' "${reverse_received}"

  ROBOTICS_SERIAL_DEVICE="${serial_target}" \
    docker compose \
      -f "${REPOSITORY_ROOT}/compose.yaml" \
      -f "${REPOSITORY_ROOT}/compose.serial.yaml" \
      --profile serial-preflight \
      run --rm --no-deps serial-device-preflight
}

prepare_vcan_gateway() {
  local allowed_gateway=172.30.247.1
  local denied_gateway=172.30.248.1
  local denied_network_candidate="${project}-denied"
  local unexpected="${work_root}/unexpected-can-frame.log"
  local candump_pid

  test ! -e "/sys/class/net/${vcan_interface}" || {
    printf 'refusing to use pre-existing host interface: %s\n' \
      "${vcan_interface}" >&2
    return 73
  }
  test ! -e /sys/class/net/robotics-can || {
    printf 'refusing to use pre-existing host bridge: robotics-can\n' >&2
    return 73
  }
  test ! -e /etc/systemd/system/robotics-can-observation@.service || {
    printf 'refusing to replace an existing systemd template\n' >&2
    return 73
  }
  if sudo systemctl cat "${can_unit}" >/dev/null 2>&1; then
    printf 'refusing to reuse an existing systemd unit: %s\n' \
      "${can_unit}" >&2
    return 73
  fi
  if docker network inspect robotics-can-observation >/dev/null 2>&1; then
    printf 'refusing to reuse an existing Docker network: %s\n' \
      robotics-can-observation >&2
    return 73
  fi
  if docker network inspect "${denied_network_candidate}" >/dev/null 2>&1; then
    printf 'refusing to reuse an existing Docker network: %s\n' \
      "${denied_network_candidate}" >&2
    return 73
  fi

  sudo modprobe vcan
  sudo ip link add dev "${vcan_interface}" type vcan
  vcan_created=1
  vcan_ifindex_owned="$(< "/sys/class/net/${vcan_interface}/ifindex")"
  sudo ip link set dev "${vcan_interface}" up
  can_compose_created=1
  can_compose create can-observation-client
  sudo install -m 0644 \
    "${REPOSITORY_ROOT}/systemd/robotics-can-observation@.service" \
    /etc/systemd/system/robotics-can-observation@.service
  systemd_template_created=1
  systemd_template_sha256="$(
    sha256_file /etc/systemd/system/robotics-can-observation@.service
  )"
  sudo systemctl daemon-reload
  can_service_started=1
  sudo systemctl start "${can_unit}"
  sudo systemctl is-active --quiet "${can_unit}"

  docker run --rm \
    --network robotics-can-observation \
    "${CAN_CLIENT_IMAGE}" \
    nc -z -w 2 "${allowed_gateway}" 28700

  denied_can_network="${denied_network_candidate}"
  docker network create \
    --internal \
    --subnet 172.30.248.0/28 \
    --label "org.robotics-runtime.owner=${project}" \
    "${denied_can_network}" >/dev/null
  denied_can_network_created=1
  if docker run --rm \
    --network "${denied_can_network}" \
    "${CAN_CLIENT_IMAGE}" \
    nc -z -w 2 "${denied_gateway}" 28700; then
    printf 'CAN gateway accepted a client outside its allow-list\n' >&2
    return 1
  fi
  remove_network_owned_by_run \
    "${denied_can_network}" \
    org.robotics-runtime.owner
  denied_can_network=
  denied_can_network_created=0

  timeout 3 candump -L -n 1 "${vcan_interface}" >"${unexpected}" &
  candump_pid=$!
  sleep 1
  printf '123#01020304\n' | docker run --rm --interactive \
    --network robotics-can-observation \
    "${CAN_CLIENT_IMAGE}" \
    nc -w 1 "${allowed_gateway}" 28700 || true
  wait "${candump_pid}" || test "$?" -eq 124
  test ! -s "${unexpected}"

  can_compose up --detach can-observation-client
  for _ in {1..20}; do
    if sudo ss -Htn state established sport = :28700 | grep -q .; then
      break
    fi
    sleep 1
  done
  sudo ss -Htn state established sport = :28700 | grep -q .
  cansend "${vcan_interface}" 123#DEADBEEF
  for _ in {1..20}; do
    if can_compose logs --no-color can-observation-client |
      grep -q '123#DEADBEEF'; then
      break
    fi
    sleep 1
  done
  can_compose logs --no-color can-observation-client |
    grep -q '123#DEADBEEF'
}

verify_time_evidence() {
  local max_age_ns
  local max_window_ns
  local now_ns
  local replay_dir
  local replay_token
  local window_finished_ns

  now_ns="$(date -u +%s%N)"
  max_age_ns="$(( ${ROBOTICS_TIME_EVIDENCE_MAX_AGE_SEC:-300} * 1000000000 ))"
  max_window_ns="$(( ${ROBOTICS_TIME_EVIDENCE_MAX_WINDOW_SEC:-900} * 1000000000 ))"
  jq -s -e \
    --arg evidence_sha256 "$(sha256_file "${ROBOTICS_TIME_EVIDENCE}")" \
    --arg run_id "${ROBOTICS_TIME_EVIDENCE_RUN_ID}" \
    --arg source_revision "${GITHUB_SHA:-local}" \
    --arg workflow_run_attempt "${GITHUB_RUN_ATTEMPT:-1}" \
    --arg workflow_run_id "${GITHUB_RUN_ID:-local}" \
    --argjson future_tolerance_ns 0 \
    --argjson max_age_ns "${max_age_ns}" \
    --argjson max_window_ns "${max_window_ns}" \
    --argjson now_ns "${now_ns}" \
    --slurpfile window "${ROBOTICS_TIME_EVIDENCE_WINDOW}" \
    -f "${PHYSICAL_ATTACH_FIXTURE_ROOT}/verify-time-evidence.jq" \
    "${ROBOTICS_TIME_EVIDENCE}" >/dev/null

  replay_dir="${ROBOTICS_TIME_EVIDENCE_REPLAY_DIR:-${RUNNER_TEMP:-/run/lock}/robotics-runtime-infra-time-evidence}"
  install -d -m 0700 "${replay_dir}"
  replay_token="$(
    {
      sha256_file "${ROBOTICS_TIME_EVIDENCE}"
      sha256_file "${ROBOTICS_TIME_EVIDENCE_WINDOW}"
      printf '%s\n' "${ROBOTICS_TIME_EVIDENCE_RUN_ID}"
      printf '%s\n' \
        "${GITHUB_RUN_ID:-local}" \
        "${GITHUB_RUN_ATTEMPT:-1}" \
        "${GITHUB_SHA:-local}"
    } | sha256sum | awk '{print $1}'
  )"
  mkdir "${replay_dir}/${replay_token}" || {
    printf 'time evidence was already consumed: %s\n' "${replay_token}" >&2
    return 77
  }
  chmod 0500 "${replay_dir}/${replay_token}"

  window_finished_ns="$(
    jq -r '.finished_at_unix_nano' "${ROBOTICS_TIME_EVIDENCE_WINDOW}"
  )"
  time_measured_at="$(
    date -u -d "@$((window_finished_ns / 1000000000))" \
      +%Y-%m-%dT%H:%M:%SZ
  )"
}

x509_spki_sha256() {
  local certificate="$1"

  openssl x509 -in "${certificate}" -pubkey -noout |
    openssl pkey -pubin -outform DER |
    sha256sum |
    awk '{print $1}'
}

write_target_evidence() {
  local certificate="${security_dir}/keystore/enclaves/robotics/telemetry_source/cert.pem"
  local certificate_sha256
  local identity_sha256
  local time_sha256
  local time_window_sha256
  local serial_host_device
  local serial_target_device
  local vcan_ifindex

  test -s "${certificate}"
  certificate_sha256="$(sha256_file "${certificate}")"
  identity_sha256="$(x509_spki_sha256 "${certificate}")"
  time_sha256="$(sha256_file "${ROBOTICS_TIME_EVIDENCE}")"
  time_window_sha256="$(sha256_file "${ROBOTICS_TIME_EVIDENCE_WINDOW}")"
  serial_host_device="$(stat -Lc '%t:%T' "${serial_host}")"
  serial_target_device="$(stat -Lc '%t:%T' "${serial_target}")"
  vcan_ifindex="$(< "/sys/class/net/${vcan_interface}/ifindex")"
  jq \
    --arg certificate_sha256 "${certificate_sha256}" \
    --arg checked_at "${time_measured_at}" \
    --arg host_device "${serial_host_device}" \
    --arg identity_sha256 "${identity_sha256}" \
    --arg can_interface "${vcan_interface}" \
    --arg target_device "${serial_target_device}" \
    --arg time_sha256 "${time_sha256}" \
    --arg time_window_sha256 "${time_window_sha256}" \
    --arg time_window_run_id "${ROBOTICS_TIME_EVIDENCE_RUN_ID}" \
    --argjson vcan_ifindex "${vcan_ifindex}" '
      .checked_at = $checked_at |
      .identity.sha256 = $identity_sha256 |
      .identity.certificate_sha256 = $certificate_sha256 |
      .serial.host_device = $host_device |
      .serial.target_device = $target_device |
      .can.interface = $can_interface |
      .can.ifindex = $vcan_ifindex |
      .time.evidence_sha256 = $time_sha256 |
      .time.window_sha256 = $time_window_sha256 |
      .time.window_run_id = $time_window_run_id
    ' "${PHYSICAL_ATTACH_FIXTURE_ROOT}/target-evidence.json" \
    >"${work_root}/target-evidence.json"

  printf '%s\n' "${identity_sha256}" \
    >"${work_root}/target-identity.sha256"
}
