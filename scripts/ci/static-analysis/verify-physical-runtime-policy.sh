#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo
mkdir -p tmp
ci_set_compose_fixture_env
docker compose \
  -f compose.yaml \
  -f compose.edge-attach.yaml \
  --profile edge-attach \
  config --format json --output tmp/edge-attach-compose.json
docker compose \
  -f compose.yaml \
  -f compose.edge-attach.yaml \
  --profile hil \
  config --format json --output tmp/hil-compose.json
docker compose \
  -f compose.yaml \
  -f compose.edge-attach.yaml \
  -f compose.real-observation.yaml \
  --profile real-observation \
  config --format json --output tmp/real-observation-compose.json
docker compose \
  -f compose.yaml \
  -f compose.edge-attach.yaml \
  -f compose.real-observation.yaml \
  -f compose.real-observation.test.yaml \
  --profile real-observation \
  --profile real-observation-test \
  config --format json --output tmp/real-observation-test-compose.json
jq -e '
  (.services | keys | sort) == [
    "edge-attach-data-plane",
    "edge-attach-observer"
  ] and
  .networks["robotics-attach"].external == true and
  .services["edge-attach-observer"].network_mode ==
    "service:edge-attach-data-plane" and
  (.services["edge-attach-observer"].command |
    index("--otel-metrics")) == null
' tmp/edge-attach-compose.json >/dev/null
jq -e '
  (.services | keys | sort) == [
    "edge-attach-data-plane",
    "hil-observer",
    "physical-permit-preflight",
    "physical-runtime-manifest"
  ] and
  .networks["robotics-attach"].external == true and
  .services["physical-permit-preflight"].network_mode == "none" and
  .services["physical-runtime-manifest"].network_mode == "none" and
  .services["hil-observer"].network_mode ==
    "service:edge-attach-data-plane" and
  .services["hil-observer"].environment.ROS_SECURITY_STRATEGY ==
    "Enforce" and
  (.services["hil-observer"].command |
    index("--otel-metrics")) != null and
  (.services["hil-observer"].command |
    index("/evidence/hardware-time.otlp.json")) != null and
  any(.services["hil-observer"].volumes[];
    .target == "/evidence" and .read_only == true
  ) and
  .services["hil-observer"].depends_on["physical-permit-preflight"].condition ==
    "service_completed_successfully" and
  .services["hil-observer"].depends_on["physical-runtime-manifest"].condition ==
    "service_completed_successfully" and
  all(.services[];
    (.devices // []) == [] and
    (.device_cgroup_rules // []) == []
  )
' tmp/hil-compose.json >/dev/null
jq -e '
  (.services | keys | sort) == [
    "edge-attach-data-plane",
    "physical-permit-preflight",
    "physical-runtime-manifest",
    "real-observation-observer"
  ] and
  (.services | has("simulation") | not) and
  .networks["robotics-attach"].external == true and
  .services["physical-permit-preflight"].network_mode == "none" and
  .services["physical-runtime-manifest"].network_mode == "none" and
  (.services["real-observation-observer"].profiles |
    index("real-observation")) != null and
  (.services["real-observation-observer"].profiles |
    index("hil")) == null and
  .services["real-observation-observer"].network_mode ==
    "service:edge-attach-data-plane" and
  .services["real-observation-observer"].labels[
    "org.robotics-runtime.execution.environment"
  ] == "real_robot" and
  .services["real-observation-observer"].labels[
    "org.robotics-runtime.execution.physical-effect"
  ] == "observation" and
  .services["real-observation-observer"].depends_on[
    "physical-permit-preflight"
  ].condition == "service_completed_successfully" and
  .services["real-observation-observer"].depends_on[
    "physical-runtime-manifest"
  ].condition == "service_completed_successfully"
' tmp/real-observation-compose.json >/dev/null
jq -e --arg ci_image "${PERMIT_PREFLIGHT_CI_IMAGE}" '
  .services["physical-permit-preflight"].image == $ci_image and
  .services["physical-runtime-manifest"].image != $ci_image
' tmp/real-observation-test-compose.json >/dev/null
test "$(
  ci_policy_deny_count \
    policy/compose.rego compose tmp/edge-attach-compose.json
)" -eq 0
test "$(
  ci_policy_deny_count policy/compose.rego compose tmp/hil-compose.json
)" -eq 0
test "$(
  ci_policy_deny_count \
    policy/compose.rego compose tmp/real-observation-compose.json
)" -eq 0
test "$(
  ci_policy_deny_count \
    policy/compose.rego compose tmp/real-observation-test-compose.json
)" -eq 0
