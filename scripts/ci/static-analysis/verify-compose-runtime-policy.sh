#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo
mkdir -p tmp
ci_set_compose_fixture_env
mkdir -p tmp
docker compose --profile test --profile acceptance \
  config --format json --output tmp/compose.json
test "$(ci_policy_deny_count policy/compose.rego compose tmp/compose.json)" -eq 0
jq -e '
  .services["acceptance-observer"] as $observer
  | any($observer.volumes[];
      .target == "/evidence" and .read_only == true
    )
    and ($observer.command | index("/evidence/evidence-index.json")) != null
    and ($observer.command | index("/evidence/metrics.otlp.json")) != null
' tmp/compose.json >/dev/null
docker compose \
  -f compose.yaml \
  -f compose.high-throughput.yaml \
  --profile acceptance \
  config --format json --output tmp/high-throughput-compose.json
jq -e '
  .services["runtime-manifest"].environment
  | .FASTRTPS_DEFAULT_PROFILES_FILE ==
      "/etc/robotics/fastdds/high-throughput.xml"
    and .RMW_FASTRTPS_USE_QOS_FROM_XML == "1"
    and .RMW_IMPLEMENTATION == "rmw_fastrtps_cpp"
    and .ROS_AUTOMATIC_DISCOVERY_RANGE == "LOCALHOST"
' tmp/high-throughput-compose.json >/dev/null
test "$(
  ci_policy_deny_count \
    policy/compose.rego compose tmp/high-throughput-compose.json
)" -eq 0
