#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  # shellcheck source=scripts/ci/foundation/lib.sh
  source "${ROOT}/scripts/ci/foundation/lib.sh"
  REAL_DOCKER="$(command -v docker)"
  # Local project tooling may supply the same pinned standalone Compose binary.
  REAL_COMPOSE="${ROBOTICS_COMPOSE_TEST_BIN:-}"
  if [[ -n "${REAL_COMPOSE}" ]]; then
    run "${REAL_COMPOSE}" version --short
  else
    run "${REAL_DOCKER}" compose version --short
  fi
  [ "${status}" -eq 0 ]
  [ "${output}" = 5.3.1 ]
  export CI_REPO_ROOT="${ROOT}" OBSERVER_IMAGE=local/selected-observer:foundation
  export ROBOTICS_RUN_ID=issued-wire-run ROBOTICS_DOMAIN_ID=primary
  # The fixed library nameref resolves this trusted array.
  # shellcheck disable=SC2034
  compose_environment=()
  MODEL="${BATS_TEST_TMPDIR}/foundation.json"
  printf '%s\n' '{"services":{"simulation":{"environment":{"ROS_DOMAIN_ID":"88","RMW_IMPLEMENTATION":"rmw_fastrtps_cpp"}}}}' >"${MODEL}"
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  CAPTURE="${BATS_TEST_TMPDIR}/renderer-environment.json"
  python3 - "${BIN}/docker" "${REAL_DOCKER}" "${REAL_COMPOSE}" "${CAPTURE}" <<'PY'
import json
import sys
from pathlib import Path

output, docker, compose, capture = sys.argv[1:]
command = [compose] if compose else [docker, "compose"]
Path(output).write_text(
    "#!/usr/bin/env python3\n"
    "import json,os,sys\nfrom pathlib import Path\n"
    f"Path({capture!r}).write_text(json.dumps(dict(os.environ)))\n"
    f"command={command!r}+sys.argv[2:]\n"
    "assert sys.argv[1]=='compose'\nos.execv(command[0],command)\n"
)
PY
  chmod +x "${BIN}/docker"
  export PATH="${BIN}:${PATH}"
}

render_runner() {
  local snippet="${BATS_TEST_TMPDIR}/runner-caller-config.sh"
  local consumer_root="${ROOT}" consumer_file="${ROOT}/examples/generic-consumer/compose.yaml"
  # The extracted production call site consumes these exact local variables.
  # shellcheck disable=SC2034
  local foundation_model="${MODEL}" data_source=simulator consumer_model="$1"
  awk '
    /^  consumer_provider=simulation$/ {capture=1}
    /^  ci_require_model_paths_within_root/ {if(capture) exit}
    capture {print}
  ' "${ROOT}/scripts/ci/foundation/run-acceptance.sh" >"${snippet}"
  [[ -s "${snippet}" ]] || return 65
  # Execute the actual production call site with its required real helper context.
  # shellcheck source=/dev/null
  source "${snippet}"
}

@test "actual pinned caller renderer binds issued public values and repository-root read-only inputs" {
  local output_model="${BATS_TEST_TMPDIR}/consumer.json"
  export GH_TOKEN=PRIVATE_GH_SENTINEL GITHUB_TOKEN=PRIVATE_GITHUB_SENTINEL
  export AWS_ACCESS_KEY_ID=PRIVATE_AWS_ID_SENTINEL AWS_SECRET_ACCESS_KEY=PRIVATE_AWS_SECRET_SENTINEL
  export AWS_SESSION_TOKEN=PRIVATE_AWS_SESSION_SENTINEL AUTHORIZATION=PRIVATE_BEARER_SENTINEL
  export DOCKER_HOST=tcp://foreign.invalid:2375 DOCKER_CONTEXT=foreign
  export DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH=/foreign DOCKER_CONFIG=/foreign
  export ROS_DOMAIN_ID=999 RMW_IMPLEMENTATION=foreign
  run render_runner "${output_model}"
  [ "${status}" -eq 0 ]
  [ -s "${output_model}" ]
  python3 - "${ROOT}" "${output_model}" "${CAPTURE}" <<'PY'
import json
import sys
from pathlib import Path

root, model, capture = map(Path, sys.argv[1:])
service = json.loads(model.read_text())["services"]["caller-probe"]
expected = {
    "ROBOTICS_RUN_ID": "issued-wire-run", "ROBOTICS_DOMAIN_ID": "primary",
    "ROS_DOMAIN_ID": "88", "RMW_IMPLEMENTATION": "rmw_fastrtps_cpp",
}
assert service["image"] == "local/selected-observer:foundation"
assert service["environment"] == expected
assert service["volumes"] == [
    {"type": "bind", "source": str(root / "examples/generic-consumer/probe.py"),
     "target": "/consumer/probe.py", "read_only": True},
    {"type": "bind", "source": str(root / "examples/generic-consumer/inputs/opaque.bin"),
     "target": "/consumer/opaque.bin", "read_only": True},
]
environment = json.loads(capture.read_text())
assert environment["OBSERVER_IMAGE"] == service["image"]
assert all(environment[key] == value for key, value in expected.items())
assert not any(key.startswith(("AWS_", "DOCKER_")) or key in {
    "GH_TOKEN", "GITHUB_TOKEN", "AUTHORIZATION"
} for key in environment)
assert "PRIVATE_" not in capture.read_text()
assert environment["COMPOSE_DISABLE_ENV_FILE"] == "1"
PY
}
