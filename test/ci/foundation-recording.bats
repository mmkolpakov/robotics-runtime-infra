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
  CAPTURE="${BATS_TEST_TMPDIR}/capture"
  PREPARED="${BATS_TEST_TMPDIR}/prepared"
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
  "${FOUNDATION_PYTHON}" - "${CAPTURE}" "${REPOSITORY_ROOT}" <<'PY'
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

root, repository = map(Path, sys.argv[1:])
fixtures = repository / "test/qualification/fixtures"
shutil.copyfile(repository / "examples/minimal-consumer/scenario.yaml", root / "scenario.yaml")
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
    for index in range(3):
        stamp = 1_000_000_000 + index * 500_000_000
        writer.add_message(clock, stamp, struct.pack("<Iii", 1, stamp // 10**9, stamp % 10**9), stamp)
        writer.add_message(channel, stamp, struct.pack("<IQ", 1, index), stamp)
    writer.finish()
summary = recording_summary_from_mcap(recording)
summary_path = root / "evidence/summaries/selected.recording-summary.json"
write_document(summary, summary_path)
metadata = dict(load_mapping(repository / "test/fixtures/playback/golden/metadata.yaml"))
info = metadata["rosbag2_bagfile_information"]
topic = info["topics_with_message_count"][0]
topic["topic_metadata"].update(
    name="/example/sequence", type="std_msgs/msg/UInt64", type_description_hash="RIHS01_" + "a" * 64)
topic["message_count"] = 3
clock_topic = json.loads(json.dumps(topic))
clock_topic["topic_metadata"].update(name="/clock", type="rosgraph_msgs/msg/Clock")
info.update(
    relative_file_paths=["selected.mcap"], message_count=6,
    topics_with_message_count=[topic, clock_topic],
    files=[{"path": "selected.mcap", "starting_time": {"nanoseconds_since_epoch": 10**9},
            "duration": {"nanoseconds": 10**9}, "message_count": 6}],
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
assert scenario["time_policy"]["playback_rate"] == 1 / 120
PY
  [ "${status}" -eq 0 ]
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
