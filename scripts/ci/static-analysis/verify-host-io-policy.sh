#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo
mkdir -p tmp
ci_set_compose_fixture_env
docker compose \
  -f compose.yaml \
  -f compose.serial.yaml \
  --profile serial-preflight \
  config --format json --output tmp/serial-compose.json
docker compose \
  -f compose.yaml \
  -f compose.time.yaml \
  --profile time-chrony \
  --profile time-ptp \
  config --format json --output tmp/time-compose.json
docker compose \
  -f compose.yaml \
  -f compose.can-observation.yaml \
  --profile can-observation \
  config --format json --output tmp/can-observation-compose.json
jq -e '
  (.services | keys) == ["serial-device-preflight"] and
  .services["serial-device-preflight"].network_mode == "none" and
  .services["serial-device-preflight"].devices == [{
    "source": "/dev/robotics/controller-alpha",
    "target": "/dev/robotics/target",
    "permissions": "r"
  }]
' tmp/serial-compose.json >/dev/null
jq -e '
  (.services | keys | sort) == [
    "time-evidence-chrony",
    "time-evidence-ptp"
  ] and
  all(.services[];
    .network_mode == "none" and
    .read_only == true
  )
' tmp/time-compose.json >/dev/null
jq -e '
  (.services | keys) == ["can-observation-client"] and
  .services["can-observation-client"].stdin_open == true and
  .services["can-observation-client"].read_only == true and
  .services["can-observation-client"].user == "65534:65534" and
  .services["can-observation-client"].networks == {
    "robotics-can-observation": null
  } and
  (.services["can-observation-client"].extra_hosts // []) == [] and
  (.services["can-observation-client"].command | index("nc")) == 0 and
  (.services["can-observation-client"].command | index("172.30.247.1")) == 3 and
  (.services["can-observation-client"].command | index("cansend")) == null and
  .networks["robotics-can-observation"].internal == true and
  .networks["robotics-can-observation"].ipam.config == [{
    "subnet": "172.30.247.0/28",
    "gateway": "172.30.247.1"
  }] and
  .networks["robotics-can-observation"].driver_opts[
    "com.docker.network.bridge.name"
  ] == "robotics-can"
' tmp/can-observation-compose.json >/dev/null
test "$(
  ci_policy_deny_count policy/compose.rego compose tmp/serial-compose.json
)" -eq 0
test "$(
  ci_policy_deny_count policy/compose.rego compose tmp/time-compose.json
)" -eq 0
test "$(
  ci_policy_deny_count \
    policy/compose.rego compose tmp/can-observation-compose.json
)" -eq 0
