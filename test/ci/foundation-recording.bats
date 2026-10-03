#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI before these tests}"
  FOUNDATION_PYTHON="${ROBOTICS_FOUNDATION_PYTHON:-$(dirname "${ROBOTICS_CONTRACTS_CLI}")/python}"
  # shellcheck source=scripts/ci/foundation/lib.sh
  source "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh"
  SCENARIO="${BATS_TEST_TMPDIR}/scenario.json"
}

@test "foundation recording uses the smoke scenario's 30-second limit" {
  run foundation_recording_duration "${FOUNDATION_PYTHON}" \
    "${REPOSITORY_ROOT}/examples/minimal-consumer/scenario.yaml"
  [ "${status}" -eq 0 ]
  [ "${output}" = 30 ]
}

@test "foundation recording honors a consumer's shorter segment limit" {
  printf '{"evidence_policy":{"max_segment_duration_sec":7,"topics":["/clock"]}}\n' >"${SCENARIO}"
  run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
  [ "${status}" -eq 0 ]
  [ "${output}" = 7 ]
}

@test "foundation recording rounds fractional limits down to whole seconds" {
  printf '{"evidence_policy":{"max_segment_duration_sec":7.9}}\n' >"${SCENARIO}"
  run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
  [ "${status}" -eq 0 ]
  [ "${output}" = 7 ]
}

@test "foundation recording keeps the one-second boundary bounded" {
  printf '{"evidence_policy":{"max_segment_duration_sec":1}}\n' >"${SCENARIO}"
  run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
  [ "${status}" -eq 0 ]
  [ "${output}" = 1 ]
}

@test "foundation recording rejects durations that cannot produce a bounded segment" {
  local duration
  for duration in 0.5 0 -1 true '"30"' null; do
    printf '{"evidence_policy":{"max_segment_duration_sec":%s}}\n' \
      "${duration}" >"${SCENARIO}"
    run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'finite segment duration of at least 1 second'* ]]
  done
}

@test "foundation recording rejects a missing duration instead of using Compose's default" {
  printf '{"evidence_policy":{}}\n' >"${SCENARIO}"
  run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
  [ "${status}" -ne 0 ]
}

@test "foundation recording uses the contracts parser to reject duplicate policy keys" {
  printf 'evidence_policy:\n  max_segment_duration_sec: 30\n  max_segment_duration_sec: 60\n' \
    >"${SCENARIO}"
  run foundation_recording_duration "${FOUNDATION_PYTHON}" "${SCENARIO}"
  [ "${status}" -ne 0 ]
}

prepare_orchestration_fixture() {
  FIXTURE="${BATS_TEST_TMPDIR}/orchestration"
  local scripts="${FIXTURE}/scripts/ci"
  local bin="${FIXTURE}/dependencies/robotics-runtime/.venv/bin"
  mkdir -p "${scripts}" "${bin}"
  # Keep production dependencies together; this fixture replaces only leaf I/O.
  cp -a "${REPOSITORY_ROOT}/scripts/ci/." "${scripts}/"
  mkdir -p "${FIXTURE}/config/recording" "${FIXTURE}/config/qualification"
  cp -a "${REPOSITORY_ROOT}/config/recording/." "${FIXTURE}/config/recording/"
  cp "${REPOSITORY_ROOT}/config/qualification/recorded-playback.json" \
    "${FIXTURE}/config/qualification/"
  : >"${scripts}/image-identity.sh"
  # Keep the real orchestration and duration parser; stop at the first Compose
  # call. Image lookup, host inventory and run creation are unit fixtures.
  # The policy spy retains the actual parsed input and can reject the run.
  cat >"${scripts}/lib.sh" <<'SH'
cosign() { :; }
lscpu() { printf '{}\n'; }
ci_image_identity() { printf '{"digest":"fixture","reference":"fixture","local_image_id":"fixture"}\n'; }
ci_require_policy_allows() {
  [[ "$1" == policy/scenario.rego && "$2" == scenario ]] || return 65
  cp -- "$3" "${FOUNDATION_SCENARIO_POLICY_INPUT}"
  return "${FOUNDATION_SCENARIO_POLICY_STATUS}"
}
docker() {
  printf '%s\n' "${ROBOTICS_MAX_BAG_DURATION:-unset}" >"${FOUNDATION_RECORDING_ENV}"
  printf '%s\n' "${ROBOTICS_METRICS_TOPIC:-unset}" "${ROBOTICS_RECORD_REGEX:-unset}" \
    >"${FOUNDATION_TOPIC_ENV}"
  return 88
}
SH
  cat >"${bin}/python" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == -c ]]; then
  printf '{}\n'
else
  exec "${FOUNDATION_REAL_PYTHON}" "$@"
fi
SH
  cat >"${bin}/robotics-acceptance" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FOUNDATION_CREATE_RUN_ARGS}"
printf 'run-fixture\n'
SH
  chmod +x "${bin}/python" "${bin}/robotics-acceptance"
  export FOUNDATION_REAL_PYTHON="${FOUNDATION_PYTHON}"
  export FOUNDATION_CREATE_RUN_ARGS="${BATS_TEST_TMPDIR}/create-run-arguments"
  export FOUNDATION_RECORDING_ENV="${BATS_TEST_TMPDIR}/compose-duration"
  export FOUNDATION_TOPIC_ENV="${BATS_TEST_TMPDIR}/compose-topics"
  export FOUNDATION_SCENARIO_POLICY_INPUT="${BATS_TEST_TMPDIR}/scenario-policy-input.json"
  export FOUNDATION_SCENARIO_POLICY_STATUS=0
  export ROBOTICS_FOUNDATION_SCENARIO="${SCENARIO}"
  export ROBOTICS_FOUNDATION_RUN_ID=recording-unit
  export ROBOTICS_FOUNDATION_ARTIFACT_DIR="${FIXTURE}/artifacts"
  export SIMULATION_IMAGE=fixture EVIDENCE_IMAGE=fixture
  export ROBOTICS_MAX_BAG_DURATION=60
}

@test "acceptance exports the scenario duration before Compose resolves recorder and sink" {
  prepare_orchestration_fixture
  printf '{"evidence_policy":{"max_segment_duration_sec":7,"topics":["/clock"]}}\n' >"${SCENARIO}"
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -eq 88 ]
  jq -e '.evidence_policy.max_segment_duration_sec == 7' \
    "${FOUNDATION_SCENARIO_POLICY_INPUT}" >/dev/null
  [ "$(cat "${FOUNDATION_RECORDING_ENV}")" = 7 ]
}

@test "acceptance configures the declared UInt64 and exact recording topics before Compose" {
  prepare_orchestration_fixture
  printf '%s\n' '{"expected_ros_graph":{"topics":[{"name":"/custom/probe","type":"std_msgs/msg/UInt64"}]},"evidence_policy":{"max_segment_duration_sec":7,"topics":["/clock","/custom/probe","/sensor/a.b"]}}' >"${SCENARIO}"
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -eq 88 ]
  local configured
  mapfile -t configured <"${FOUNDATION_TOPIC_ENV}"
  [ "${configured[0]}" = /custom/probe ]
  local regex="${configured[1]}"
  [[ /sensor/a.b =~ ${regex} ]]
  [[ ! /sensor/axb =~ ${regex} ]]
  [[ ! /robotics/runtime_probe =~ ${regex} ]]
  [[ /custom/probe =~ ${regex} ]]
}

@test "acceptance stops before Compose when the scenario policy rejects the run" {
  prepare_orchestration_fixture
  export FOUNDATION_SCENARIO_POLICY_STATUS=23
  printf '{"evidence_policy":{"max_segment_duration_sec":7,"topics":["/clock"]}}\n' >"${SCENARIO}"
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -eq 23 ]
  jq -e '.evidence_policy.max_segment_duration_sec == 7' \
    "${FOUNDATION_SCENARIO_POLICY_INPUT}" >/dev/null
  [ ! -e "${FOUNDATION_RECORDING_ENV}" ]
}

@test "acceptance stops before Compose if the scenario duration cannot be configured" {
  prepare_orchestration_fixture
  printf '{"evidence_policy":{"max_segment_duration_sec":0.5}}\n' >"${SCENARIO}"
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -ne 0 ]
  [ "${status}" -ne 88 ]
  [[ "${output}" == *'finite segment duration of at least 1 second'* ]]
  [ ! -e "${FOUNDATION_RECORDING_ENV}" ]
}


prepare_playback_capture_fixture() {
  local execution_sec="${1:-10}" span_ns="${2:-1000000000}" suffix="${3:-}"
  CAPTURE="${BATS_TEST_TMPDIR}/capture${suffix}"
  PREPARED="${BATS_TEST_TMPDIR}/prepared${suffix}"
  mkdir -p "${CAPTURE}/results" "${CAPTURE}/bags/recording" \
    "${CAPTURE}/configuration/capture" "${CAPTURE}/evidence/summaries"
  local -a args=()
  local kind subject file
  while IFS=$'\t' read -r kind subject file; do
    args+=(--artifact "${kind}:${subject}=${REPOSITORY_ROOT}/test/qualification/fixtures/${file}")
  done < <(jq -r '.artifacts[]|[.kind,.subject_name,.file]|@tsv' \
    "${REPOSITORY_ROOT}/test/qualification/fixtures/single-artifacts.json")
  "${REPOSITORY_ROOT}/scripts/qualification/create-statement" "${args[@]}" \
    --output "${CAPTURE}/results/qualification-statement.json"
  "${FOUNDATION_PYTHON}" - "${CAPTURE}" "${REPOSITORY_ROOT}" "${execution_sec}" "${span_ns}" <<'PY'
import hashlib
import json
import shutil
import struct
import sys
from pathlib import Path
from mcap.writer import CompressionType, Writer
from robotics_runtime_contracts import load_mapping
from robotics_runtime_contracts.recordings import recording_summary_from_mcap
from robotics_runtime_contracts.writers import write_document

root, repository = map(Path, sys.argv[1:3])
execution_sec, span_ns = map(int, sys.argv[3:])
fixtures = repository / "test/qualification/fixtures"
scenario = dict(load_mapping(repository / "examples/minimal-consumer/scenario.yaml"))
scenario["timeouts"]["execution_sec"] = execution_sec
write_document(scenario, root / "scenario.yaml", schema="acceptance-scenario.v1")
shutil.copyfile(fixtures / "runtime-manifest.json", root / "runtime-manifest.json")
for name in ("qos-overrides.yaml", "mcap-writer.yaml"):
    shutil.copyfile(repository / "config/recording" / name, root / "configuration/capture" / name)
recording = root / "bags/recording/selected.mcap"
with recording.open("wb") as stream:
    writer = Writer(stream, compression=CompressionType.NONE)
    writer.start(profile="ros2")
    schema = writer.register_schema("std_msgs/msg/UInt64", "ros2msg", b"uint64 data\n")
    clock_schema = writer.register_schema("rosgraph_msgs/msg/Clock", "ros2msg", b"builtin_interfaces/Time clock\n")
    channel = writer.register_channel("/example/sequence", "cdr", schema)
    clock = writer.register_channel("/clock", "cdr", clock_schema)
    # Synthetic typed raw records; native CDR replay belongs to real ROS CI.
    # The short density fixture retains the actual stock's 1 ms / 2 ms groups.
    stamps = (range(10**9, 10**9 + span_ns + 1, 1_000_000)
              if span_ns < 10**9 else (10**9, 10**9 + span_ns // 2, 10**9 + span_ns))
    clock_count = message_count = 0
    for index, stamp in enumerate(stamps):
        writer.add_message(clock, stamp, struct.pack("<Iii", 1, stamp // 10**9, stamp % 10**9), stamp)
        clock_count += 1
        if span_ns < 10**9 and index == 76:
            continue
        writer.add_message(channel, stamp, struct.pack("<IQ", 1, index), stamp)
        message_count += 1
    writer.finish()
summary = recording_summary_from_mcap(recording)
summary_path = root / "evidence/summaries/selected.recording-summary.json"
write_document(summary, summary_path)
metadata = dict(load_mapping(repository / "test/fixtures/playback/golden/metadata.yaml"))
info = metadata["rosbag2_bagfile_information"]
topic = info["topics_with_message_count"][0]
topic["topic_metadata"].update(
    name="/example/sequence", type="std_msgs/msg/UInt64", type_description_hash="RIHS01_" + "a" * 64)
topic["message_count"] = message_count
clock_topic = json.loads(json.dumps(topic))
clock_topic["topic_metadata"].update(name="/clock", type="rosgraph_msgs/msg/Clock")
clock_topic["message_count"] = clock_count
info.update(
    relative_file_paths=["selected.mcap"], message_count=message_count + clock_count,
    topics_with_message_count=[topic, clock_topic],
    files=[{"path": "selected.mcap", "starting_time": {"nanoseconds_since_epoch": 10**9},
            "duration": {"nanoseconds": span_ns}, "message_count": message_count + clock_count}],
    custom_data={"captured_at": "2026-10-03T10:00:00Z", "dataset_license": "NOASSERTION",
                 "data_classification": "public", "retention_class": "pull-request-7d",
                 "capture_clock_policy": "ros-time-no-reset"})
(root / "bags/recording/metadata.yaml").write_text(json.dumps(metadata))
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
index = dict(load_mapping(fixtures / "evidence-index.json"))
entry = index["artifacts"][0]
entry.update(sha256=digest(recording), size_bytes=recording.stat().st_size,
             local_path=str(recording), uri=recording.as_uri())
entry["recording_summary"] = {
    "uri": summary_path.as_uri(), "sha256": digest(summary_path), "size_bytes": summary_path.stat().st_size}
index["artifacts"] = [entry]
write_document(index, root / "evidence/evidence-index.json")
# Schema-valid origin scaffold, not a synthetic claim of completed live ROS.
statement = dict(load_mapping(root / "results/qualification-statement.json"))
updates = {
    "scenario.json": root / "scenario.yaml",
    "runtime-manifests/primary.json": root / "runtime-manifest.json",
    "evidence-indexes/primary.json": root / "evidence/evidence-index.json",
    "recording-summaries/control-0.json": summary_path,
    "evidence/recording-0.mcap": recording,
}
for subject in statement["subject"]:
    if subject["name"] in updates:
        subject["digest"]["sha256"] = digest(updates[subject["name"]])
for subject, path in [
    ("capture/qos-overrides.yaml", root / "configuration/capture/qos-overrides.yaml"),
    ("capture/mcap-writer.yaml", root / "configuration/capture/mcap-writer.yaml"),
    ("capture/bags/recording/metadata.yaml", root / "bags/recording/metadata.yaml"),
]:
    statement["subject"].append({
        "name": subject, "digest": {"sha256": digest(path)}})
    statement["predicate"]["artifacts"].append({"kind": "other_evidence", "subject_name": subject})
write_document(statement, root / "results/qualification-statement.json", schema="qualification-bundle.v1")
PY
}


@test "playback preparer writes native dataset and scenario bound to retained origin bytes" {
  prepare_playback_capture_fixture
  run "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" "${CAPTURE}" "${PREPARED}" <<'PY'
import importlib.util
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping, validate_document
repository, source, output = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("prepare", repository / "scripts/ci/integration/prepare-playback-inputs.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
# Original source summary is native-generated in fixture setup. Production
# preparation must work without the evidence sink's optional MCAP Python extra.
import builtins
original_import = builtins.__import__
def minimal_production_import(name, *args, **kwargs):
    if name.split(".")[0] in ("mcap", "lz4", "zstandard"):
        raise ModuleNotFoundError("MCAP extra is absent from the selected production interpreter")
    return original_import(name, *args, **kwargs)
builtins.__import__ = minimal_production_import
# Only the absent ROS transport boundary is replaced; public writers are real.
module.scan_recording = lambda path, topic: {
    "first_ns": 10**9, "last_ns": 2 * 10**9, "message_count": 3, "clock_samples": 3}
module.prepare(source, output, output)
dataset = load_mapping(output / "dataset-manifest.json")
scenario = load_mapping(output / "scenario.json")
validate_document(dataset)
validate_document(scenario, schema="acceptance-scenario.v1")
assert dataset["artifact"]["sha256"] == module.sha256(output / "source/bag/selected.mcap")
assert dataset["provenance"]["scenario_sha256"] == module.sha256(source / "scenario.yaml")
assert dataset["provenance"]["runtime_manifest_sha256"] == module.sha256(source / "runtime-manifest.json")
assert dataset["governance"]["license"] == "NOASSERTION"
assert dataset["time"]["qos_overrides_sha256"] == module.sha256(output / "source/capture/qos-overrides.yaml")
assert scenario["dataset_manifest_sha256"] == module.sha256(output / "dataset-manifest.json")
assert scenario["execution"]["data_source"] == "recording_playback"
source_scenario = load_mapping(source / "scenario.yaml")
source_clock = next(topic for topic in source_scenario["expected_ros_graph"]["topics"] if topic["name"] == "/clock")
replay_clock = next(topic for topic in scenario["expected_ros_graph"]["topics"] if topic["name"] == "/clock")
assert source_clock["qos_profile"] == "system_default"
assert replay_clock["qos_profile"] == "sensor_data"
assert module.sha256(source / "scenario.yaml") == module.sha256(output / "source/capture/scenario.yaml")
assert scenario["time_policy"]["playback_rate"] == 1 / 30
PY
  [ "${status}" -eq 0 ]
}

@test "playback desired duration follows the inherited window without overstretching stock timestamp groups" {
  source "${REPOSITORY_ROOT}/scripts/ci/lib.sh"
  ci_set_compose_fixture_env
  # The canonical runner sets this interval before resolving the same model.
  export ROBOTICS_METRICS_EXPORT_INTERVAL_MS=200
  local window span
  for setting in "10 382000000" "4 382000000" "4 20000000000"; do
    read -r window span <<<"${setting}"
    prepare_playback_capture_fixture "${window}" "${span}" "-${window}-${span}"
    run "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" "${CAPTURE}" "${PREPARED}" <<'PY'
import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from mcap.reader import make_reader
from robotics_runtime_contracts import load_mapping, validate_document

repository, source, output = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("prepare", repository / "scripts/ci/integration/prepare-playback-inputs.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
recording = source / "bags/recording/selected.mcap"
before = recording.read_bytes()
with recording.open("rb") as stream:
    rows = list(make_reader(stream).iter_messages())
times = sorted({message.log_time for _, channel, message in rows if channel.topic == "/example/sequence"})
clock_count = sum(channel.topic == "/clock" for _, channel, _ in rows)
# Native MCAP records supply the timing fixture; only the ROS SDK boundary is replaced.
module.scan_recording = lambda path, topic: {
    "first_ns": times[0], "last_ns": times[-1],
    "message_count": len(times), "clock_samples": clock_count}
module.prepare(source, output, output)
parameters = load_mapping(output / "playback-inputs.json")
scenario = load_mapping(output / "scenario.json")
dataset = load_mapping(output / "dataset-manifest.json")
validate_document(scenario, schema="acceptance-scenario.v1")
validate_document(dataset)
window = load_mapping(source / "scenario.yaml")["timeouts"]["execution_sec"]
assert parameters["rate"] == scenario["time_policy"]["playback_rate"]
assert dataset["artifact"]["sha256"] == module.sha256(recording)
assert dataset["provenance"]["scenario_sha256"] == module.sha256(source / "scenario.yaml")
assert dataset["provenance"]["runtime_manifest_sha256"] == module.sha256(source / "runtime-manifest.json")
assert recording.read_bytes() == before == (output / "source/bag/selected.mcap").read_bytes()
if window == 4 and times[-1] - times[0] == 20 * 10**9:
    assert parameters["rate"] == 1.0
else:
    model = json.loads(subprocess.check_output([
        "docker", "compose", "--env-file", "/dev/null",
        "-f", "compose.yaml", "-f", "compose.observability.yaml",
        "--profile", "*", "config", "--format", "json"], cwd=repository))
    interval_ms = int(model["services"]["runtime-metrics"]["environment"]["ROBOTICS_METRICS_EXPORT_INTERVAL_MS"])
    gaps = [following - previous for previous, following in zip(times, times[1:])]
    assert min(gaps) == 1_000_000 and max(gaps) == 2_000_000
    old_rate = (times[-1] - times[0]) / 10**9 / 120
    assert max(gaps) / old_rate / 10**6 > interval_ms
    replay_gap_ms = max(gaps) / parameters["rate"] / 10**6
    print(f"window={window}s recorded_max_gap={max(gaps)}ns rate={parameters['rate']} replay_max_gap={replay_gap_ms}ms export={interval_ms}ms")
    assert replay_gap_ms < interval_ms, "selected native rate overstretches stock timestamp groups beyond the metric export interval"
assert parameters["desired_playback_duration_sec"] == 3 * window
assert "replay_budget_sec" not in parameters
PY
    printf '%s\n' "${output}"
    [ "${status}" -eq 0 ]
  done
}

@test "playback preparer refuses a different original runtime and a changed validated snapshot" {
  prepare_playback_capture_fixture
  run "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" "${CAPTURE}" "${PREPARED}" <<'PY'
import importlib.util
import sys
from pathlib import Path
repository, source, output = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("prepare", repository / "scripts/ci/integration/prepare-playback-inputs.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
runtime = source / "runtime-manifest.json"
previous = runtime.read_bytes()
runtime.write_bytes(previous + b"\n")
try:
    module.prepare(source, output, output)
except ValueError as error:
    assert "completed source statement" in str(error)
else:
    raise AssertionError("different original runtime was accepted")
assert not output.exists()
runtime.write_bytes(previous)
original_copy = module.copy_input
def replace_metadata(source_file, destination):
    if source_file.name == "metadata.yaml":
        source_file.write_bytes(source_file.read_bytes() + b"\n")
    original_copy(source_file, destination)
module.copy_input = replace_metadata
try:
    module.prepare(source, output, output)
except ValueError as error:
    assert "validated source bytes" in str(error)
else:
    raise AssertionError("stable replacement after validation was accepted")
assert not (output / "dataset-manifest.json").exists()
assert not (output / "scenario.json").exists()
PY
  [ "${status}" -eq 0 ]
}

@test "native playback composition replaces simulator dependencies and keeps explicit player options" {
  export SIMULATION_IMAGE=local/simulation:fixture ROBOTICS_RUN_ID=run-fixture ROBOTICS_DOMAIN_ID=primary
  export ROBOTICS_METRICS_TOPIC=/example/sequence ROBOTICS_PLAYBACK_RATE=0.001
  export ROBOTICS_PLAYBACK_CLOCK_HZ=100 ROBOTICS_PLAYBACK_START_OFFSET=0.01
  docker compose --project-directory "${REPOSITORY_ROOT}" \
    -f "${REPOSITORY_ROOT}/compose.yaml" -f "${REPOSITORY_ROOT}/compose.foundation.yaml" \
    -f "${REPOSITORY_ROOT}/compose.record.yaml" -f "${REPOSITORY_ROOT}/compose.evidence.yaml" \
    -f "${REPOSITORY_ROOT}/compose.observability.yaml" -f "${REPOSITORY_ROOT}/compose.playback.yaml" \
    -f "${REPOSITORY_ROOT}/compose.foundation-playback.yaml" \
    --profile '*' config --format json >"${BATS_TEST_TMPDIR}/model.json"
  jq -e '
    (.services.recorder.depends_on|keys) == ["playback"] and
    (.services["runtime-metrics"].depends_on|keys) == ["otel-collector","playback"] and
    (.services["acceptance-observer"].command|index("--dataset")) != null and
    (.services.playback.command|index("--clock")) != null and
    (.services.playback.command|index("--topics")) != null and
    (.services.playback.command|index("--start-offset")) != null and
    .services["playback-probe"].command[5:7] == ["/example/sequence","std_msgs/msg/UInt64"]
  ' "${BATS_TEST_TMPDIR}/model.json"
}

@test "native scan requires file order and refuses reset or stalled Clock samples" {
  run "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" <<'PY'
import importlib.util
import sys
import types
from pathlib import Path

repository = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("prepare", repository / "scripts/ci/integration/prepare-playback-inputs.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
# Replace only the absent native transport SDK; execute the production scan.
Clock, UInt64 = type("Clock", (), {}), type("UInt64", (), {})
state = {"supported": True, "clocks": [1, 2], "closed": 0}
class Reader:
    def __init__(self):
        self.items = iter([("/clock", value, index) for index, value in enumerate(state["clocks"])] +
                          [("/example/sequence", 0, 10**9), ("/example/sequence", 1, 2 * 10**9)])
        self.pending = None
    def open(self, *_):
        pass
    def set_read_order(self, order):
        assert order == ("file", False)
        return state["supported"]
    def has_next(self):
        self.pending = next(self.items, None)
        return self.pending is not None
    def read_next(self):
        return self.pending
    def close(self):
        state["closed"] += 1
sys.modules["rosbag2_py"] = types.SimpleNamespace(
    SequentialReader=Reader, StorageOptions=lambda **kw: kw,
    ConverterOptions=lambda *args: args, ReadOrder=lambda *args: args,
    ReadOrderSortBy=types.SimpleNamespace(File="file"))
sys.modules["rclpy.serialization"] = types.SimpleNamespace(
    deserialize_message=lambda raw, kind: types.SimpleNamespace(
        clock=types.SimpleNamespace(sec=raw, nanosec=0)) if kind is Clock else UInt64())
sys.modules["rosgraph_msgs.msg"] = types.SimpleNamespace(Clock=Clock)
sys.modules["std_msgs.msg"] = types.SimpleNamespace(UInt64=UInt64)
assert module.scan_recording(Path("transport-fixture.mcap"), "/example/sequence")["message_count"] == 2
for supported, clocks, error_text in [
    (False, [1, 2], "native file order"),
    (True, [2, 1], "backward ROS clock"),
    (True, [1, 1], "advancing Clock"),
]:
    state.update(supported=supported, clocks=clocks)
    try:
        module.scan_recording(Path("transport-fixture.mcap"), "/example/sequence")
    except ValueError as error:
        assert error_text in str(error)
    else:
        raise AssertionError("unsupported or contradictory native observations passed")
assert state["closed"] == 4
PY
  [ "${status}" -eq 0 ]
}

@test "preparer refuses a wrong selected segment and missing explicit capture governance" {
  prepare_playback_capture_fixture
  run "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" "${CAPTURE}" "${PREPARED}" <<'PY'
import hashlib
import importlib.util
import json
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping
from robotics_runtime_contracts.writers import write_document

repository, source, output = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("prepare", repository / "scripts/ci/integration/prepare-playback-inputs.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.scan_recording = lambda *_: {
    "first_ns": 10**9, "last_ns": 2 * 10**9, "message_count": 3, "clock_samples": 3}
metadata = source / "bags/recording/metadata.yaml"
original = load_mapping(metadata)
statement_path = source / "results/qualification-statement.json"
for case in ("segment", "license"):
    data = json.loads(json.dumps(original))
    bag = data["rosbag2_bagfile_information"]
    if case == "segment":
        bag["relative_file_paths"] = ["unplayed.mcap"]
    else:
        del bag["custom_data"]["dataset_license"]
    metadata.write_text(json.dumps(data))
    statement = dict(load_mapping(statement_path))
    next(item for item in statement["subject"]
         if item["name"] == "capture/bags/recording/metadata.yaml")["digest"]["sha256"] = \
        hashlib.sha256(metadata.read_bytes()).hexdigest()
    write_document(statement, statement_path, schema="qualification-bundle.v1")
    destination = output.with_name(case)
    try:
        module.prepare(source, destination, destination)
    except (KeyError, ValueError):
        pass
    else:
        raise AssertionError(f"{case} was accepted")
    assert not (destination / "dataset-manifest.json").exists()
    assert not (destination / "scenario.json").exists()
PY
  [ "${status}" -eq 0 ]
}

@test "existing acceptance runner creates a separate native playback run context" {
  prepare_playback_capture_fixture
  "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" "${CAPTURE}" "${PREPARED}" <<'PY'
import importlib.util
import sys
from pathlib import Path
repository, source, output = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("prepare", repository / "scripts/ci/integration/prepare-playback-inputs.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.scan_recording = lambda *_: {
    "first_ns": 10**9, "last_ns": 2 * 10**9, "message_count": 3, "clock_samples": 3}
module.prepare(source, output, output)
PY
  prepare_orchestration_fixture
  export ROBOTICS_FOUNDATION_SCENARIO="${PREPARED}/scenario.json"
  export ROBOTICS_FOUNDATION_PLAYBACK_INPUTS="${PREPARED}"
  cat >"${FIXTURE}/dependencies/robotics-runtime/.venv/bin/robotics-acceptance" <<'SH'
#!/usr/bin/env bash
exec "${FOUNDATION_REAL_PYTHON}" -m robotics_acceptance_harness.cli "$@"
SH
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -eq 88 ]
  local context="${FIXTURE}/runs/foundation-e2e-recording-unit-1/acceptance-run.json"
  "${FOUNDATION_PYTHON}" - "${context}" "${PREPARED}/scenario.json" <<'PY'
import hashlib
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping, validate_document
path, scenario = map(Path, sys.argv[1:])
run = load_mapping(path)
validate_document(run)
assert run["time_authority"] == {"kind": "playback_clock", "source_id": "rosbag2-player-clock"}
assert run["scenario_sha256"] == hashlib.sha256(scenario.read_bytes()).hexdigest()
assert run["domains"][0]["domain_id"] == "primary"
PY
}

@test "finalized runner composition keeps playback dependencies enabled for metrics and queries" {
  local context="${BATS_TEST_TMPDIR}/compose-context.sh"
  {
    cat <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
data_source="$2"
ROBOTICS_RUNTIME_MODE="$3"
consumer_root="${root}"
CI_REPO_ROOT="${root}"
project=profile-regression
run_dir="${4}"
artifact_dir="${run_dir}/artifacts"
mkdir -p "${artifact_dir}"
cd "${root}"
source scripts/ci/lib.sh
ci_set_compose_fixture_env
compose_environment=(--env-file /dev/null)
if [[ "$5" == consumer ]]; then
  export ROBOTICS_FOUNDATION_COMPOSE_PROJECT="${root}/examples/minimal-consumer/compose.yaml"
fi
# This regression validates composition, not admission/provenance or daemon I/O.
# Native Compose and the actual production selection/normalization remain real.
ci_yq_from_root() { printf '{"services":{}}\n'; }
ci_require_policy_allows() { :; }
ci_require_source_paths_within_root() { :; }
ci_require_model_paths_within_root() { :; }
foundation_require_release_images_policy() {
  printf '{}\n' >"${run_dir}/release-images-policy-input.json"
}
SH
    # Run the existing branch selection through its final source/include/released
    # rebind. Do not rebuild a parallel profile/file table in this fixture.
    awk '
      /^profiles=\(/ { emit = 1 }
      emit && /^observer=""$/ { exit }
      emit { print }
    ' "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
    cat <<'SH'
# Same global argv/profile/env as the failed metrics up; config needs no daemon.
"${compose[@]}" --profile observability config --format json >"${run_dir}/metrics-model.json"
"${compose[@]}" config --quiet
if [[ "${data_source}" == recording_playback ]]; then
  jq -e '
    (.services | has("playback") and has("playback-gate") and has("playback-probe")) and
    (.services["runtime-metrics"].depends_on | has("playback")) and
    (.services | has("recorder") and has("runtime-manifest") and has("acceptance-observer") and has("evidence-sink"))
  ' "${run_dir}/metrics-model.json"
fi
SH
  } >"${context}"
  local mode layout cadence
  unset ROBOTICS_STEP_INTERVAL_SEC ROBOTICS_STEPS_PER_TICK
  run bash "${context}" "${REPOSITORY_ROOT}" simulator source \
    "${BATS_TEST_TMPDIR}/stock" default
  printf '%s\n' "${output}"
  [ "${status}" -eq 0 ]
  jq -e '.services["simulation-stepper"].command[-1] == "0.2"' \
    "${BATS_TEST_TMPDIR}/stock/metrics-model.json"
  cadence="$("${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" <<'PY'
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping
workflow = load_mapping(Path(sys.argv[1]) / ".github/workflows/foundation-integration.yml")
job = workflow["jobs"]["foundation"]
capture = next(step for step in job["steps"]
               if step.get("run") == "bash scripts/ci/foundation/run-acceptance-isolation.sh")
assert "ROBOTICS_STEP_INTERVAL_SEC" not in job["env"]
assert all("ROBOTICS_STEP_INTERVAL_SEC" not in step.get("env", {})
           for step in job["steps"] if step is not capture)
print(capture.get("env", {}).get("ROBOTICS_STEP_INTERVAL_SEC", "0.2"))
PY
  )"
  run env ROBOTICS_STEP_INTERVAL_SEC="${cadence}" \
    bash "${context}" "${REPOSITORY_ROOT}" simulator source \
    "${BATS_TEST_TMPDIR}/stock-capture" consumer
  printf '%s\n' "${output}"
  [ "${status}" -eq 0 ]
  jq -c '.services["simulation-stepper"].command' \
    "${BATS_TEST_TMPDIR}/stock-capture/metrics-model.json"
  jq -e '.services["simulation-stepper"].command as $command |
    $command[-1] == "0.01" and $command[($command | index("--steps")) + 1] == "1"' \
    "${BATS_TEST_TMPDIR}/stock-capture/metrics-model.json"
  run env ROBOTICS_STEP_INTERVAL_SEC=0.05 ROBOTICS_STEPS_PER_TICK=3 \
    bash "${context}" "${REPOSITORY_ROOT}" simulator source \
    "${BATS_TEST_TMPDIR}/custom-cadence" consumer
  printf '%s\n' "${output}"
  [ "${status}" -eq 0 ]
  jq -e '.services["simulation-stepper"].command as $command |
    $command[-1] == "0.05" and $command[($command | index("--steps")) + 1] == "3"' \
    "${BATS_TEST_TMPDIR}/custom-cadence/metrics-model.json"
  for mode in source released; do
    for layout in default consumer; do
      run bash "${context}" "${REPOSITORY_ROOT}" recording_playback "${mode}" \
        "${BATS_TEST_TMPDIR}/${mode}-${layout}" "${layout}"
      printf '%s\n' "${output}"
      [ "${status}" -eq 0 ]
    done
  done
}

@test "source recorder starts after provider manifest and publisher while playback keeps early capture" {
  local boundary="${BATS_TEST_TMPDIR}/capture-boundary.sh"
  {
    cat <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root="$1"; data_source="$2"; run_dir="$3"
script_dir="${root}/scripts/ci/foundation"
foundation_bin="${root}/dependencies/robotics-runtime/.venv/bin"
ROBOTICS_SIMULATION_OCI_DIGEST=fixture-digest
artifact_dir="${run_dir}/artifacts"
mkdir -p "${run_dir}/configuration" "${artifact_dir}/provider"
events="${run_dir}/events"
compose=(docker compose)
extra_services=()
publish() { printf '%s\n' "$1" >>"${events}"; }
sudo() {
  if [[ "$1" == install ]]; then
    cp -- "${@: -2:1}" "${@: -1}"
  fi
}
curl() { :; }
foundation_validate_document() { :; }
provider_fixture() {
  publish provider
  printf '{}\n' >"${artifact_dir}/provider/bindings.json"
}
collect_playback_provider() { provider_fixture; }
bash() { provider_fixture; }
docker() {
  if [[ "$1" == inspect ]]; then
    printf '[{"HostConfig":{}}]\n'
  elif [[ " $* " == *' up '* ]]; then
    [[ " $* " != *' recorder '* ]] || publish recorder
    [[ " $* " != *' runtime-probe-publisher '* ]] || publish publisher
  elif [[ " $* " == *' run '* ]]; then
    publish manifest
    jq -n --arg digest "$(sha256sum "${root}/config/fastdds/udp-only.xml" | cut -d' ' -f1)" \
      '{schema_version:"runtime-manifest.v1",
        data_plane:{middleware_configuration_sha256:$digest},
        configuration_artifacts:[{kind:"host_topology"},{kind:"runtime_resources"}]}' \
      >"${run_dir}/runtime-manifest.json"
  elif [[ " $* " == *' port '* ]]; then
    printf '127.0.0.1:13133\n'
  elif [[ " $* " == *' ps '* ]]; then
    printf 'fixture-container\n'
  else
    return 90
  fi
}
SH
    # Execute the contiguous production startup through publication. Only leaf
    # transports above are fixtures; this does not claim native ROS observation.
    awk '
      /^sudo chown -R 1000:1000/ { emit = 1 }
      emit && /^observer_compose=/ { exit }
      emit { print }
    ' "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
  } >"${boundary}"
  local source
  for source in simulator recording_playback; do
    run bash "${boundary}" "${REPOSITORY_ROOT}" "${source}" \
      "${BATS_TEST_TMPDIR}/${source}"
    printf '%s\n' "${output}"
    [ "${status}" -eq 0 ]
    local expected="${BATS_TEST_TMPDIR}/expected-${source}"
    if [[ "${source}" == simulator ]]; then
      printf 'provider\nmanifest\npublisher\nrecorder\n' >"${expected}"
    else
      printf 'recorder\nprovider\nmanifest\n' >"${expected}"
    fi
    run diff -u "${expected}" "${BATS_TEST_TMPDIR}/${source}/events"
    printf '%s\n' "${output}"
    [ "${status}" -eq 0 ]
  done
}
