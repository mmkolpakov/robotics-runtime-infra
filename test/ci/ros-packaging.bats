#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
}

@test "ament Python packages follow the ROS 2 package template" {
  package=ros_ws/src/robotics_observability/package.xml

  run grep -F '<build_type>ament_python</build_type>' "${package}"
  [ "${status}" -eq 0 ]

  run grep -F '<buildtool_depend>ament_python</buildtool_depend>' "${package}"
  [ "${status}" -eq 1 ]

  run grep -F 'extras_require={"test": ["pytest"]}' \
    ros_ws/src/robotics_observability/setup.py
  [ "${status}" -eq 0 ]
}

@test "locked OpenTelemetry dependencies are excluded once from rosdep" {
  local dependency

  for dependency in \
    opentelemetry-api \
    opentelemetry-exporter-otlp-proto-http \
    opentelemetry-sdk; do
    run grep -F \
      "<exec_depend>python3-${dependency}-pip</exec_depend>" \
      ros_ws/src/robotics_observability/package.xml
    [ "${status}" -eq 0 ]

    run grep -F "${dependency}==1.44.0" docker/python/observability.lock
    [ "${status}" -eq 0 ]

    [ "$(grep -Fc "python3-${dependency}-pip" Dockerfile)" -eq 1 ]
  done
}

@test "runtime image tests include the observability package" {
  run grep -F 'robotics_observability' compose.yaml

  [ "${status}" -eq 0 ]
}

@test "simulation conformance reuses the selected runtime image" {
  expected_image=example.invalid/robotics/simulation:test
  run env \
    ROBOTICS_DOMAIN_ID=0 \
    ROBOTICS_RUN_ID=run-compose-model-test \
    SIMULATION_IMAGE="${expected_image}" \
    docker compose \
    -f compose.yaml \
    -f compose.simulation-conformance.yaml \
    --profile simulation-conformance \
    config --format json
  [ "${status}" -eq 0 ]

  run jq -e --arg image "${expected_image}" '
    .services.simulation.image == $image and
    .services["simulation-conformance"].image == $image
  ' <<<"${output}"
  [ "${status}" -eq 0 ]
}

@test "edge runtime carries the typed trace context without build tooling" {
  run grep -F \
    'FROM edge-runtime-base AS edge-runtime-interfaces' \
    Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    'COPY --from=edge-runtime-interfaces /opt/robotics_ws/install /opt/robotics_ws/install' \
    Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    'robotics_observability_msgs/msg/TraceContext > /dev/null' \
    Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    '<exec_depend>rosidl_default_runtime</exec_depend>' \
    docker/rosdeps/edge/package.xml
  [ "${status}" -eq 0 ]
}

@test "Gazebo clock bridges configure queued reliable delivery for stepped observation" {
  local config=ros_ws/src/robotics_runtime_infra/config/clock_bridge.yaml
  # The live test_clock subscriber requests reliable delivery. Here retain the
  # packaging check that every launch selects its shared bridge configuration.
  run grep -F 'publisher_queue: 1000' "${config}"
  [ "${status}" -eq 0 ]
  run grep -E '^[[:space:]]*qos_profile: CLOCK' "${config}"
  [ "${status}" -eq 1 ]

  run grep -F 'clock_bridge.yaml' \
    ros_ws/src/robotics_runtime_infra/launch/headless.launch.py
  [ "${status}" -eq 0 ]
  run grep -F '/clock@rosgraph_msgs/msg/Clock' \
    ros_ws/src/robotics_runtime_infra/launch/headless.launch.py
  [ "${status}" -eq 1 ]

  run grep -F 'headless.launch.py' \
    ros_ws/src/robotics_runtime_infra/launch/joint_motion.launch.py
  [ "${status}" -eq 0 ]
  run grep -F 'clock_bridge.yaml' \
    ros_ws/src/robotics_runtime_infra/launch/joint_motion.launch.py
  [ "${status}" -eq 1 ]

  run grep -F 'headless.launch.py' \
    ros_ws/src/robotics_runtime_infra/launch/camera.launch.py
  [ "${status}" -eq 0 ]
  run grep -F 'clock_bridge.yaml' \
    ros_ws/src/robotics_runtime_infra/launch/camera.launch.py
  [ "${status}" -eq 1 ]

  # EGL rendering remains a Gazebo-specific adapter and owns its clock bridge.
  run grep -F 'headless.launch.py' \
    ros_ws/src/robotics_runtime_infra/launch/gpu_lidar.launch.py
  [ "${status}" -eq 1 ]
  run grep -F 'clock_bridge.yaml' \
    ros_ws/src/robotics_runtime_infra/launch/gpu_lidar.launch.py
  [ "${status}" -eq 0 ]

  run grep -F 'qos_profile=QoSProfile(depth=1000, reliability=ReliabilityPolicy.RELIABLE)' \
    ros_ws/src/robotics_runtime_infra/test/test_clock.py
  [ "${status}" -eq 0 ]
}

@test "launch tests use distinct ROS domains" {
  cmake=ros_ws/src/robotics_runtime_infra/CMakeLists.txt

  run python3 - "${cmake}" <<'PYTHON'
import ast
import re
import shlex
import sys
from pathlib import Path

cmake = Path(sys.argv[1])
blocks = re.findall(r"\badd_launch_test\s*\(([^)]*)\)", cmake.read_text())
assert blocks, "no launch tests registered"
registered, domains = [], []
for block in blocks:
    name = shlex.split(block)[0]
    registered.append(name)
    values = re.findall(r'\bENV\s+"ROS_DOMAIN_ID=([0-9]+)"', block)
    assert len(values) == 1, f"{name} requires exactly one explicit ROS domain"
    domains.append(int(values[0]))
launch_files = {
    path.relative_to(cmake.parent).as_posix()
    for path in (cmake.parent / "test").glob("test_*.py")
    if any(isinstance(node, ast.FunctionDef) and node.name == "generate_test_description"
           for node in ast.parse(path.read_text()).body)
}
assert set(registered) == launch_files, "launch test inventory differs from CMake registrations"
assert len(registered) == len(set(registered)), "duplicate launch test registration"
assert len(domains) == len(set(domains)), "launch tests share a ROS domain"
PYTHON
  [ "${status}" -eq 0 ]
}

prepare_playback_transport() {
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir "${bin}"
  export PLAYBACK_NATIVE_DOCKER
  PLAYBACK_NATIVE_DOCKER="$(command -v docker)"
  export PATH="${bin}:${PATH}"
  export PLAYBACK_REPO_ROOT="${REPO_ROOT}"
  export ROBOTICS_PLAYBACK_ARTIFACT_ROOT="${BATS_TEST_TMPDIR}/retained"
  export PLAYBACK_TRACE="${BATS_TEST_TMPDIR}/docker-trace"
  export PLAYBACK_LARGE_DOMAIN=87 PLAYBACK_NEGATIVE_DATA=0 PLAYBACK_LOG_FAILURE_DOMAIN=none
  export PLAYBACK_WRONG_IMAGE=0
  export ROBOTICS_FOUNDATION_LOCK="${REPO_ROOT}/foundation.repos" ROS_DISTRO=jazzy
  export GITHUB_SHA
  GITHUB_SHA="$(printf '%040d' 2)"
  : "${ROBOTICS_FOUNDATION_PYTHON:?use the installed foundation interpreter}"
  : "${ROBOTICS_CONTRACTS_CLI:?use the installed contracts CLI}"
  cat >"${bin}/ros2" <<'SH'
#!/usr/bin/env bash
[[ "$*" == 'pkg xml rmw_fastrtps_cpp --tag version' ]] || exit 64
printf '8.4.1-fixture-package\n'
SH
  cat >"${bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${PLAYBACK_TRACE}"
case "$1" in
  image)
    image_id="sha256:$(printf '%064d' 4)"
    [[ "${*: -1}" != *edge* ]] || image_id="sha256:$(printf '%064d' 5)"
    jq -n --arg id "${image_id}" '[{Id: $id, RepoDigests: []}]'
    ;;
  run) printf '0.26.9-fixture\n' ;;
  compose)
    original=("$@")
    while (($#)); do
      case "$1" in
        config) exec "${PLAYBACK_NATIVE_DOCKER}" "${original[@]}" ;;
        ps) printf '%s-%s\n' "${ROS_DOMAIN_ID}" "${@: -1}"; exit 0 ;;
        up | wait) exit 0 ;;
        down)
          if [[ -f "${ROBOTICS_RUN_DIR:-}/runtime-manifest.json" ]]; then
            printf 'retained-manifest-before-down\n' >>"${PLAYBACK_TRACE}"
          fi
          exit 0
          ;;
        run)
          # Exercise the native flag parser before mocking only daemon execution.
          native_prefix=()
          for value in "${original[@]}"; do
            [[ "${value}" != runtime-manifest ]] || break
            native_prefix+=("${value}")
          done
          "${PLAYBACK_NATIVE_DOCKER}" "${native_prefix[@]}" --help >/dev/null
          shift
          while [[ "$1" != runtime-manifest ]]; do
            if [[ "$1" == -e ]]; then
              export "${2//\/run\/robotics/${ROBOTICS_RUN_DIR}}"
              shift 2
            else
              shift
            fi
          done
          shift
          while IFS= read -r entry; do
            export "${entry//\/run\/robotics/${ROBOTICS_RUN_DIR}}"
          done < <(jq -r '.services["runtime-manifest"].environment |
            to_entries[] | "\(.key)=\(.value)"' "${ROBOTICS_RUN_DIR}/compose.json")
          if (($# == 0)); then
            exec bash "${PLAYBACK_REPO_ROOT}/docker/runtime/emit-runtime-manifest" \
              "${ROBOTICS_RUN_DIR}/runtime-manifest.json"
          fi
          argv=()
          for value in "$@"; do
            case "${value}" in
              /opt/contracts/bin/python) argv+=("${ROBOTICS_FOUNDATION_PYTHON}") ;;
              /tmp/create-playback-provider.py) argv+=("${PLAYBACK_REPO_ROOT}/scripts/ci/integration/create-playback-provider.py") ;;
              robotics-contracts) argv+=("${ROBOTICS_CONTRACTS_CLI}") ;;
              *) argv+=("${value//\/run\/robotics/${ROBOTICS_RUN_DIR}}") ;;
            esac
          done
          exec "${argv[@]}"
          ;;
      esac
      shift
    done
    exit 64
    ;;
  inspect)
    if [[ "$*" == *'{{.Image}}'* ]]; then
      image_id="sha256:$(printf '%064d' 4)"
      [[ "${@: -1}" != *playback-probe ]] || image_id="sha256:$(printf '%064d' 5)"
      [[ "${PLAYBACK_WRONG_IMAGE}" != 1 ]] || image_id="sha256:$(printf '%064d' 6)"
      printf '%s\n' "${image_id}"
    else
      case "${@: -1}" in
        86-playback-gate) printf '1\n' ;;
        86-playback-probe) printf '124\n' ;;
        *) printf '0\n' ;;
      esac
    fi
    ;;
  logs)
    if [[ "${@: -1}" == *playback-probe ]]; then
      if [[ "${ROS_DOMAIN_ID}" == 87 || "${PLAYBACK_NEGATIVE_DATA}" == 1 ]]; then
        printf 'data: 42\n'
      fi
      if [[ "${ROS_DOMAIN_ID}" == "${PLAYBACK_LARGE_DOMAIN}" ]]; then
        printf '%262144s\n' ''
      fi
      [[ "${ROS_DOMAIN_ID}" != "${PLAYBACK_LOG_FAILURE_DOMAIN}" ]] || exit 42
    else
      printf 'resume accepted\n'
    fi
    ;;
  *) exit 64 ;;
esac
SH
  chmod +x "${bin}/docker" "${bin}/ros2"
}

@test "MCAP playback accepts large logs and retains a byte-bound manifest before cleanup" {
  prepare_playback_transport
  run bash scripts/ci/integration/verify-mcap-playback.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'playback timeout fixture failed closed'* ]]
  [ "$(grep -c '^logs ' "${PLAYBACK_TRACE}")" -eq 4 ]
  [ "$(grep -c ' down --volumes --remove-orphans$' "${PLAYBACK_TRACE}")" -eq 2 ]
  [ "$(grep -c '^retained-manifest-before-down$' "${PLAYBACK_TRACE}")" -eq 1 ]
  local ready timeout
  ready="$(find "${ROBOTICS_PLAYBACK_ARTIFACT_ROOT}" -maxdepth 1 -name 'ready.*' -type d)"
  timeout="$(find "${ROBOTICS_PLAYBACK_ARTIFACT_ROOT}" -maxdepth 1 -name 'timeout.*' -type d)"
  run "${ROBOTICS_CONTRACTS_CLI}" validate --quiet "${ready}/runtime-manifest.json" \
    "${ready}/conformance-result.json"
  [ "${status}" -eq 0 ]
  [ "$(stat -c '%s' "${ready}/logs/playback-probe.log")" -gt 262144 ]
  [ -f "${timeout}/observation.json" ]
  [ ! -e "${timeout}/runtime-manifest.json" ]
  local moved="${BATS_TEST_TMPDIR}/downloaded-case"
  cp -R "${ready}" "${moved}"
  cmp "${ready}/runtime-manifest.json" "${moved}/runtime-manifest.json"
  cmp "${ready}/conformance-result.json" "${moved}/conformance-result.json"
  rm -rf -- "${ready}"
  run "${ROBOTICS_CONTRACTS_CLI}" validate --quiet "${moved}/runtime-manifest.json" \
    "${moved}/conformance-result.json" "${moved}/profile.json"
  [ "${status}" -eq 0 ]
  run "${ROBOTICS_FOUNDATION_PYTHON}" - "${ready}" "${moved}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

original, moved = map(Path, sys.argv[1:])
result = json.loads((moved / "conformance-result.json").read_bytes())
manifest = json.loads((moved / "runtime-manifest.json").read_bytes())
binding = manifest["provider_bindings"][0]
assert binding["conformance_result_sha256"] == hashlib.sha256(
    (moved / "conformance-result.json").read_bytes()).hexdigest()
assert binding["qualification_profile_sha256"] == hashlib.sha256(
    (moved / "profile.json").read_bytes()).hexdigest()
for ref in result["evidence"]:
    relative = Path(unquote(urlparse(ref["uri"]).path)).relative_to(original)
    raw = (moved / relative).read_bytes()
    assert len(raw) == ref["size_bytes"]
    assert hashlib.sha256(raw).hexdigest() == ref["sha256"]
PY
  [ "${status}" -eq 0 ]
}

@test "MCAP playback timeout rejects data before a log tail larger than the pipe buffer" {
  prepare_playback_transport
  run env PLAYBACK_LARGE_DOMAIN=86 PLAYBACK_NEGATIVE_DATA=1 \
    bash scripts/ci/integration/verify-mcap-playback.sh
  [ "${status}" -eq 1 ]
  [[ "${output}" != *'playback timeout fixture failed closed'* ]]
  [ "$(grep -c '^logs 86-playback-probe$' "${PLAYBACK_TRACE}")" -eq 1 ]
  [ "$(grep -c ' down --volumes --remove-orphans$' "${PLAYBACK_TRACE}")" -eq 2 ]
}

@test "MCAP playback preserves failed log retrieval even after matching data" {
  prepare_playback_transport
  run env PLAYBACK_LARGE_DOMAIN=86 PLAYBACK_NEGATIVE_DATA=1 PLAYBACK_LOG_FAILURE_DOMAIN=86 \
    bash scripts/ci/integration/verify-mcap-playback.sh
  [ "${status}" -eq 42 ]
  [[ "${output}" != *'playback timeout fixture failed closed'* ]]
  [ "$(grep -c '^logs 86-playback-probe$' "${PLAYBACK_TRACE}")" -eq 1 ]
  [ "$(grep -c ' down --volumes --remove-orphans$' "${PLAYBACK_TRACE}")" -eq 2 ]
}

@test "MCAP playback refuses an actual image mismatch without a passing binding" {
  prepare_playback_transport
  run env PLAYBACK_WRONG_IMAGE=1 bash scripts/ci/integration/verify-mcap-playback.sh
  [ "${status}" -ne 0 ]
  [ -z "$(find "${ROBOTICS_PLAYBACK_ARTIFACT_ROOT}" -name conformance-result.json)" ]
  [ -n "$(find "${ROBOTICS_PLAYBACK_ARTIFACT_ROOT}" -name observation.json)" ]
}

@test "MCAP playback binds configured bag QoS and options instead of golden defaults" {
  prepare_playback_transport
  mkdir "${BATS_TEST_TMPDIR}/dataset"
  cp -R test/fixtures/playback/golden "${BATS_TEST_TMPDIR}/dataset/selected"
  cp -R config/playback "${BATS_TEST_TMPDIR}/qos"
  mv "${BATS_TEST_TMPDIR}/dataset/selected/golden_0.mcap" \
    "${BATS_TEST_TMPDIR}/dataset/selected/selected-sequence.mcap"
  sed -i 's/golden_0.mcap/selected-sequence.mcap/g' "${BATS_TEST_TMPDIR}/dataset/selected/metadata.yaml"
  printf '\n# selected recording bytes\n' >>"${BATS_TEST_TMPDIR}/dataset/selected/metadata.yaml"
  printf '\n# selected QoS bytes\n' >>"${BATS_TEST_TMPDIR}/qos/qos-overrides.yaml"
  local selected="${BATS_TEST_TMPDIR}/dataset/selected"$'\n'
  mv "${BATS_TEST_TMPDIR}/dataset/selected" "${selected}"
  run env ROBOTICS_DATASET_DIR="${selected}" ROBOTICS_PLAYBACK_BAG=/datasets \
    ROBOTICS_PLAYBACK_CONFIG_DIR="${BATS_TEST_TMPDIR}/qos" ROBOTICS_PLAYBACK_RATE=2.0 \
    bash scripts/ci/integration/verify-mcap-playback.sh
  [ "${status}" -eq 0 ]
  local ready
  ready="$(find "${ROBOTICS_PLAYBACK_ARTIFACT_ROOT}" -maxdepth 1 -name 'ready.*' -type d)"
  cmp "${selected}/metadata.yaml" "${ready}/source/bag/metadata.yaml"
  cmp "${selected}/selected-sequence.mcap" \
    "${ready}/source/bag/selected-sequence.mcap"
  [ ! -e "${ready}/source/bag/golden_0.mcap" ]
  run jq -e --arg dataset "${ready}/source" --arg qos "${ready}/source/qos" '
    .services.playback.volumes |
    any(.[]; .target == "/datasets" and .source == $dataset and .read_only == true) and
    any(.[]; .target == "/etc/robotics/playback" and .source == $qos and .read_only == true)
  ' "${ready}/compose.json"
  [ "${status}" -eq 0 ]
  cmp "${BATS_TEST_TMPDIR}/qos/qos-overrides.yaml" "${ready}/source/qos/qos-overrides.yaml"
  run jq -e '.playback_command | .[index("--rate") + 1] == "2.0" and
    .[index("--input") + 1] == "/datasets/bag"' "${ready}/configuration/provider.json"
  [ "${status}" -eq 0 ]
}
