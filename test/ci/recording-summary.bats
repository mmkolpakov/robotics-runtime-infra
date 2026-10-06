#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI with the mcap extra}"
  export ROBOTICS_CONTRACTS_CLI
  WRAPPER="${ROOT}/docker/evidence-sink/mcap-summary"
  SOURCE="${BATS_TEST_TMPDIR}/input.mcap"
  OUTPUT="${BATS_TEST_TMPDIR}/summary.json"
  cp "${ROOT}/test/fixtures/playback/golden/golden_0.mcap" "$SOURCE"
}

@test "recording summary uses the installed contracts producer on a real MCAP" {
  run bash "$WRAPPER" "$SOURCE" "$OUTPUT"
  [ "$status" -eq 0 ]
  run "$ROBOTICS_CONTRACTS_CLI" validate --schema recording-summary.v1 --quiet "$OUTPUT"
  [ "$status" -eq 0 ]
  run jq -e --arg digest "$(sha256sum "$SOURCE" | cut -d' ' -f1)" '
    .schema_version == "recording-summary.v1" and .source_sha256 == $digest and
    .statistics.message_count == 40 and
    ([.channels[].topic] == ["/playback_probe"])' "$OUTPUT"
  [ "$status" -eq 0 ]
  cp "$OUTPUT" "${BATS_TEST_TMPDIR}/first.json"
  run bash "$WRAPPER" "$SOURCE" "$OUTPUT"
  [ "$status" -eq 0 ]
  cmp "$OUTPUT" "${BATS_TEST_TMPDIR}/first.json"
  if [[ "$(uname -s)" == Linux ]]; then
    [ "$(stat -c '%a' "$OUTPUT")" = 444 ]
  fi
}

@test "recording summary preserves existing output and cleans staging on invalid MCAP" {
  printf 'not an MCAP recording\n' >"$SOURCE"
  printf 'previous\n' >"$OUTPUT"
  run bash "$WRAPPER" "$SOURCE" "$OUTPUT"
  [ "$status" -ne 0 ]
  [[ "$output" == *MCAP* ]]
  [ "$(cat "$OUTPUT")" = previous ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name '.recording-summary.*' -print -quit)" ]
}

@test "recording summary rejects an output alias of the source" {
  local before
  before="$(sha256sum "$SOURCE")"
  run bash "$WRAPPER" "$SOURCE" "$SOURCE"
  [ "$status" -eq 65 ]
  [[ "$output" == *'destination must not replace source'* ]]
  [ "$(sha256sum "$SOURCE")" = "$before" ]
}

@test "native recorder selects and stamps its actual storage clock without limiting public policy" {
  run "${ROBOTICS_FOUNDATION_PYTHON:-$(dirname "$ROBOTICS_CONTRACTS_CLI")/python}" - "$ROOT" "$BATS_TEST_TMPDIR" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

root, temporary = map(Path, sys.argv[1:])
(temporary / "base.yaml").write_text("services:\n  simulation:\n    image: fixture\n")
native = temporary / "ros2"
native.write_text(
    f"#!{sys.executable}\n"
    "import json, sys\nprint(json.dumps(sys.argv[1:]))\n"
)
native.chmod(0o755)
for requested in (None, "true", "false", "yes", "False", "0", ""):
    environment = dict(
        os.environ,
        ROBOTICS_RUN_ID="recorder-clock-unit",
        ROBOTICS_CAPTURE_CLOCK_POLICY="opaque-caller-policy",
    )
    if requested is None:
        environment.pop("ROBOTICS_RECORD_USE_SIM_TIME", None)
    else:
        environment["ROBOTICS_RECORD_USE_SIM_TIME"] = requested
    model = json.loads(subprocess.check_output([
        "docker", "compose", "--env-file", "/dev/null",
        "-f", str(temporary / "base.yaml"), "-f", str(root / "compose.record.yaml"),
        "--profile", "*", "config", "--format", "json",
    ], cwd=root, env=environment))
    service = model["services"]["recorder"]
    execution = dict(environment, **service.get("environment", {}))
    execution["PATH"] = str(temporary) + os.pathsep + os.environ["PATH"]
    # Config re-escapes literal dollars for serialization. Execute its runtime
    # argv with only the native ROS leaf replaced.
    command = [value.replace("$$", "$") for value in service["command"]]
    result = subprocess.run(command, cwd=root, env=execution, text=True, capture_output=True)
    assert "ROBOTICS_RECORD_USE_SIM_TIME" not in model["services"]["recorder-snapshot"]["environment"]
    assert "--use-sim-time" in model["services"]["recorder-snapshot"]["command"]
    if requested not in (None, "true", "false"):
        assert result.returncode == 64, result
        assert not result.stdout, result
        continue
    assert result.returncode == 0, result.stderr
    arguments = json.loads(result.stdout)
    actual = "true" if requested is None else requested
    assert ("--use-sim-time" in arguments) == (actual == "true")
    basis = "ros_time" if actual == "true" else "system_time"
    assert f"record_timestamp_basis={basis}" in arguments
    assert "capture_clock_policy=opaque-caller-policy" in arguments
PY
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
