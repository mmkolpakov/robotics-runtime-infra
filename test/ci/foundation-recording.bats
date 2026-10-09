#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  : "${ROBOTICS_CONTRACTS_CLI:?install the pinned contracts CLI before these tests}"
  FOUNDATION_PYTHON="${ROBOTICS_FOUNDATION_PYTHON:-$(dirname "${ROBOTICS_CONTRACTS_CLI}")/python}"
  export FOUNDATION_PYTHON
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

write_orchestration_scenario() {
  "${FOUNDATION_PYTHON}" - \
    "${REPOSITORY_ROOT}/examples/minimal-consumer/scenario.yaml" "${SCENARIO}" "$1" <<'PYTHON'
import json
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping, validate_role

scenario = load_mapping(sys.argv[1])
for section, values in json.loads(sys.argv[3]).items():
    scenario[section].update(values)
assert "robot_description_sha256" not in scenario.get("workload", {})
validate_role(scenario, "acceptance_scenario")
Path(sys.argv[2]).write_text(json.dumps(scenario), encoding="utf-8")
PYTHON
}

prepare_orchestration_fixture() {
  FIXTURE="${BATS_TEST_TMPDIR}/orchestration"
  local scripts="${FIXTURE}/scripts/ci"
  local bin="${FIXTURE}/dependencies/robotics-runtime/.venv/bin"
  mkdir -p "${scripts}" "${bin}"
  # Keep production dependencies together; this fixture replaces only leaf I/O.
  cp -a "${REPOSITORY_ROOT}/scripts/ci/." "${scripts}/"
  mkdir -p "${FIXTURE}/docker/runtime"
  cp "${REPOSITORY_ROOT}/docker/runtime/admit-robot-description" \
    "${FIXTURE}/docker/runtime/"
  mkdir -p "${FIXTURE}/config/recording" "${FIXTURE}/config/qualification"
  cp -a "${REPOSITORY_ROOT}/config/recording/." "${FIXTURE}/config/recording/"
  cp "${REPOSITORY_ROOT}/config/qualification/recorded-playback.json" \
    "${FIXTURE}/config/qualification/"
  : >"${scripts}/image-identity.sh"
  # Keep the real orchestration and duration parser; stop at the first Compose
  # call. Image lookup and host inventory are leaf fixtures; role validation
  # and run creation use the installed public contracts and harness.
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
  printf '%s\n' "${ROBOTICS_METRICS_EXPORT_INTERVAL_MS:-unset}" >"${FOUNDATION_METRICS_ENV}"
  printf '%s\n' "${ROBOTICS_METRICS_TOPIC:-unset}" "${ROBOTICS_RECORD_REGEX:-unset}" \
    >"${FOUNDATION_TOPIC_ENV}"
  return 88
}
SH
  cat >"${bin}/python" <<'SH'
#!/usr/bin/env bash
exec "${FOUNDATION_REAL_PYTHON}" "$@"
SH
  cat >"${bin}/robotics-acceptance" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FOUNDATION_CREATE_RUN_ARGS}"
exec "${FOUNDATION_REAL_PYTHON}" -m robotics_acceptance_harness.cli "$@"
SH
  chmod +x "${bin}/python" "${bin}/robotics-acceptance"
  export FOUNDATION_REAL_PYTHON="${FOUNDATION_PYTHON}"
  export FOUNDATION_CREATE_RUN_ARGS="${BATS_TEST_TMPDIR}/create-run-arguments"
  export FOUNDATION_RECORDING_ENV="${BATS_TEST_TMPDIR}/compose-duration"
  export FOUNDATION_METRICS_ENV="${BATS_TEST_TMPDIR}/compose-metric-cadence"
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
  write_orchestration_scenario '{"evidence_policy":{"max_segment_duration_sec":7}}'
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -eq 88 ]
  jq -e '.evidence_policy.max_segment_duration_sec == 7' \
    "${FOUNDATION_SCENARIO_POLICY_INPUT}" >/dev/null
  [ "$(cat "${FOUNDATION_RECORDING_ENV}")" = 7 ]
}

@test "acceptance configures the declared UInt64 and exact recording topics before Compose" {
  prepare_orchestration_fixture
  write_orchestration_scenario '{"expected_ros_graph":{"topics":[{"name":"/custom/probe","type":"std_msgs/msg/UInt64","qos_profile":"system_default","min_publishers":1,"min_subscribers":0,"first_message_timeout_sec":10}]},"evidence_policy":{"max_segment_duration_sec":7,"topics":["/clock","/custom/probe","/sensor/a.b"]}}'
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

@test "acceptance resolves the product metric cadence and preserves a caller interval" {
  prepare_orchestration_fixture
  write_orchestration_scenario '{"evidence_policy":{"max_segment_duration_sec":7}}'
  local requested expected
  for requested in default 150; do
    if [[ "${requested}" == default ]]; then
      unset ROBOTICS_METRICS_EXPORT_INTERVAL_MS
      expected=100
    else
      export ROBOTICS_METRICS_EXPORT_INTERVAL_MS="${requested}"
      expected="${requested}"
    fi
    run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
    [ "${status}" -eq 88 ]
    source "${REPOSITORY_ROOT}/scripts/ci/lib.sh"
    ci_set_compose_fixture_env
    run "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" "${FOUNDATION_METRICS_ENV}" "${expected}" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

repository, captured, expected = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
environment = dict(os.environ)
cadence = captured.read_text().strip()
if cadence == "unset":
    environment.pop("ROBOTICS_METRICS_EXPORT_INTERVAL_MS", None)
else:
    environment["ROBOTICS_METRICS_EXPORT_INTERVAL_MS"] = cadence
model = json.loads(subprocess.check_output([
    "docker", "compose", "--env-file", "/dev/null",
    "-f", "compose.yaml", "-f", "compose.observability.yaml",
    "--profile", "*", "config", "--format", "json"],
    cwd=repository, env=environment))
assert int(model["services"]["runtime-metrics"]["environment"][
    "ROBOTICS_METRICS_EXPORT_INTERVAL_MS"]) == expected
PY
    printf '%s\n' "${output}"
    [ "${status}" -eq 0 ]
  done
}

@test "acceptance stops before Compose when the scenario policy rejects the run" {
  prepare_orchestration_fixture
  export FOUNDATION_SCENARIO_POLICY_STATUS=23
  write_orchestration_scenario '{"evidence_policy":{"max_segment_duration_sec":7}}'
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -eq 23 ]
  jq -e '.evidence_policy.max_segment_duration_sec == 7' \
    "${FOUNDATION_SCENARIO_POLICY_INPUT}" >/dev/null
  [ ! -e "${FOUNDATION_RECORDING_ENV}" ]
}

@test "acceptance stops before Compose if the scenario duration cannot be configured" {
  prepare_orchestration_fixture
  write_orchestration_scenario '{"evidence_policy":{"max_segment_duration_sec":0.5}}'
  run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -ne 0 ]
  [ "${status}" -ne 88 ]
  [[ "${output}" == *'finite segment duration of at least 1 second'* ]]
  [ ! -e "${FOUNDATION_RECORDING_ENV}" ]
}


prepare_playback_capture_fixture() {
  local execution_sec="${1:-10}" span_ns="${2:-1000000000}" suffix="${3:-}"
  local recording_mode="${4:-ros}"
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
  "${FOUNDATION_PYTHON}" - "${CAPTURE}" "${REPOSITORY_ROOT}" "${execution_sec}" "${span_ns}" "${recording_mode}" <<'PY'
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
execution_sec, span_ns = map(int, sys.argv[3:5])
recording_mode = sys.argv[5]
assert recording_mode in {"ros", "wall"}
record_start_ns = 1_791_310_000_000_000_000 if recording_mode == "wall" else 10**9
fixtures = repository / "test/qualification/fixtures"
scenario = dict(load_mapping(repository / "examples/minimal-consumer/scenario.yaml"))
scenario["timeouts"]["execution_sec"] = execution_sec
write_document(scenario, root / "scenario.yaml", schema="acceptance-scenario.v1")
shutil.copyfile(fixtures / "runtime-manifest.json", root / "runtime-manifest.json")
for name in ("qos-overrides.yaml", "mcap-writer.yaml"):
    shutil.copyfile(repository / "config/recording" / name, root / "configuration/capture" / name)
statement = dict(load_mapping(root / "results/qualification-statement.json"))
context = dict(load_mapping(fixtures / "acceptance-run.json"))
context.update(run_id=statement["predicate"]["run_id"], scenario_id=scenario["scenario_id"],
               scenario_sha256=hashlib.sha256((root / "scenario.yaml").read_bytes()).hexdigest())
write_document(context, root / "acceptance-run.json")
custom = {"captured_at": "2026-10-03T10:00:00Z", "dataset_license": "NOASSERTION",
          "data_classification": "public", "retention_class": "pull-request-7d",
          "run_id": context["run_id"], "capture_clock_policy": "ros-time-no-reset",
          "record_timestamp_basis": "ros_time"}
if recording_mode == "wall":
    custom.update(capture_clock_policy="system-time", record_timestamp_basis="system_time")
stamps = (range(record_start_ns, record_start_ns + span_ns + 1, 50_000_000)
          if recording_mode == "wall" else
          (range(10**9, 10**9 + span_ns + 1, 1_000_000) if span_ns < 10**9
           else (10**9, 10**9 + span_ns // 2, 10**9 + span_ns)))
groups = []
segment_limit_ns = scenario["evidence_policy"]["max_segment_duration_sec"] * 10**9
for number, stamp in enumerate(stamps):
    if not groups or stamp - groups[-1][0][1] > segment_limit_ns:
        groups.append([])
    groups[-1].append((number, stamp))
recordings, summaries = [], []
clock_count = message_count = 0
for ordinal, group in enumerate(groups):
    name = "selected.mcap" if ordinal == 0 else f"selected-{ordinal}.mcap"
    recording = root / "bags/recording" / name
    with recording.open("wb") as stream:
        writer = Writer(stream, compression=CompressionType.NONE)
        writer.start(profile="ros2")
        schema = writer.register_schema("std_msgs/msg/UInt64", "ros2msg", b"uint64 data\n")
        clock_schema = writer.register_schema("rosgraph_msgs/msg/Clock", "ros2msg", b"builtin_interfaces/Time clock\n")
        channel = writer.register_channel("/example/sequence", "cdr", schema)
        clock = writer.register_channel("/clock", "cdr", clock_schema)
        writer.add_metadata("rosbag2", {"serialized_metadata": json.dumps(
            {"custom_data": custom, "ros_distro": "jazzy", "message_count": 0})})
        for number, stamp in group:
            if recording_mode == "wall":
                clock_stamp = 10**9 + (stamp - record_start_ns) * 378_000_000 // span_ns
                clock_data = b"\x00\x01\x00\x00" + struct.pack("<ii", clock_stamp // 10**9, clock_stamp % 10**9)
                data = b"\x00\x01\x00\x00" + struct.pack("<Q", number)
                publish_stamp = stamp - 200_000
            else:
                clock_data = struct.pack("<Iii", 1, stamp // 10**9, stamp % 10**9)
                data = struct.pack("<IQ", 1, number)
                publish_stamp = stamp
            writer.add_message(clock, stamp, clock_data, publish_stamp)
            clock_count += 1
            if recording_mode == "ros" and span_ns < 10**9 and number == 76:
                continue
            writer.add_message(channel, stamp, data, publish_stamp)
            message_count += 1
        writer.add_metadata("rosbag2", {"serialized_metadata": json.dumps(
            {"custom_data": custom, "ros_distro": "jazzy",
             "message_count": message_count + clock_count})})
        writer.finish()
    summary = recording_summary_from_mcap(
        recording, max_raw_evidence_bytes=scenario["evidence_policy"]["max_segment_size_bytes"])
    summary_path = root / "evidence/summaries" / f"{recording.stem}.recording-summary.json"
    write_document(summary, summary_path)
    recordings.append(recording)
    summaries.append((summary_path, summary))
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
    relative_file_paths=[path.name for path in recordings], message_count=message_count + clock_count,
    starting_time={"nanoseconds_since_epoch": record_start_ns}, duration={"nanoseconds": span_ns},
    topics_with_message_count=[topic, clock_topic], custom_data=custom,
    files=[{"path": path.name,
            "starting_time": {"nanoseconds_since_epoch": summary["statistics"]["message_start_time_ns"]},
            "duration": {"nanoseconds": summary["statistics"]["message_end_time_ns"] - summary["statistics"]["message_start_time_ns"]},
            "message_count": summary["statistics"]["message_count"]}
           for path, (_, summary) in zip(recordings, summaries)])
(root / "bags/recording/metadata.yaml").write_text(json.dumps(metadata))
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
index = dict(load_mapping(fixtures / "evidence-index.json"))
prototype = index["artifacts"][0]
index["run_id"] = context["run_id"]
index["artifacts"] = []
for ordinal, (recording, (summary_path, _)) in enumerate(zip(recordings, summaries)):
    entry = json.loads(json.dumps(prototype))
    entry.update(artifact_id=f"artifact-{ordinal}", segment_index=ordinal,
                 sha256=digest(recording), size_bytes=recording.stat().st_size,
                 local_path=str(recording), uri=recording.as_uri(), storage_state="local",
                 retention_class=custom["retention_class"])
    entry["recording_summary"] = {
        "uri": summary_path.as_uri(), "sha256": digest(summary_path), "size_bytes": summary_path.stat().st_size}
    index["artifacts"].append(entry)
write_document(index, root / "evidence/evidence-index.json")
# Schema-valid source scaffold; this fixture does not claim completed live ROS.
removed = {item["subject_name"] for item in statement["predicate"]["artifacts"]
           if item["kind"] in ("recording", "recording_summary")}
statement["subject"] = [item for item in statement["subject"] if item["name"] not in removed]
statement["predicate"]["artifacts"] = [item for item in statement["predicate"]["artifacts"]
                                     if item["subject_name"] not in removed]
updates = {"scenario.json": root / "scenario.yaml", "acceptance-run.json": root / "acceptance-run.json",
           "runtime-manifests/primary.json": root / "runtime-manifest.json",
           "evidence-indexes/primary.json": root / "evidence/evidence-index.json"}
for subject in statement["subject"]:
    if subject["name"] in updates:
        subject["digest"]["sha256"] = digest(updates[subject["name"]])
retained = [("other_evidence", "capture/qos-overrides.yaml", root / "configuration/capture/qos-overrides.yaml"),
            ("other_evidence", "capture/mcap-writer.yaml", root / "configuration/capture/mcap-writer.yaml"),
            ("other_evidence", "capture/bags/recording/metadata.yaml", root / "bags/recording/metadata.yaml")]
for ordinal, (recording, (summary_path, _)) in enumerate(zip(recordings, summaries)):
    retained.extend([("recording", f"evidence/recording-{ordinal}.mcap", recording),
                     ("recording_summary", f"recording-summaries/control-{ordinal}.json", summary_path)])
for kind, subject, path in retained:
    statement["subject"].append({"name": subject, "digest": {"sha256": digest(path)}})
    statement["predicate"]["artifacts"].append({"kind": kind, "subject_name": subject})
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
# The coordinator consumes the existing locked MCAP extra for native identity.
from mcap.reader import SeekingReader
assert SeekingReader
# Only the absent ROS transport boundary is replaced; public writers are real.
module.scan_recording = lambda path, topic: {
    "first_ns": 10**9, "last_ns": 2 * 10**9, "message_count": 3, "clock_samples": 3, "total_message_count": 3 + 3}
module.prepare(source, output, output)
dataset = load_mapping(output / "dataset-manifest.json")
scenario = load_mapping(output / "scenario.json")
validate_document(dataset)
validate_document(scenario, schema="acceptance-scenario.v1")
assert dataset["bag"]["members"][0]["recording"]["sha256"] == module.sha256(output / "source/bag/selected.mcap")
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


@test "playback preparer accepts wall received chronology with separate source Clock bytes" {
  prepare_playback_capture_fixture 10 36000000000 -wall wall
  run "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" "${CAPTURE}" "${PREPARED}" <<'PY'
import hashlib
import importlib.util
import os
import struct
import sys
from pathlib import Path
from mcap.reader import make_reader
from robotics_runtime_contracts import load_mapping, validate_document

repository, source, output = map(Path, sys.argv[1:])
module_path = Path(os.environ.get("FOUNDATION_PLAYBACK_PREPARER", repository / "scripts/ci/integration/prepare-playback-inputs.py"))
spec = importlib.util.spec_from_file_location("prepare", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
names = load_mapping(source / "bags/recording/metadata.yaml")["rosbag2_bagfile_information"]["relative_file_paths"]
recordings = [source / "bags/recording" / name for name in names]
before = {path: path.read_bytes() for path in recordings}
rows = []
for recording in recordings:
    with recording.open("rb") as stream:
        rows.extend(make_reader(stream, validate_crcs=True).iter_messages())
data = [message for _, channel, message in rows if channel.topic == "/example/sequence"]
clocks = [message for _, channel, message in rows if channel.topic == "/clock"]
clock_bytes = [message.data for message in clocks]
clock_payloads = [struct.unpack_from("<ii", message.data, 4) for message in clocks]
assert min(message.log_time for message in data) >= 1_791_310_000_000_000_000
assert data[-1].log_time - data[0].log_time == 36_000_000_000
assert all(message.publish_time == message.log_time - 200_000 for message in data + clocks)
assert clock_payloads[0] == (1, 0) and clock_payloads[-1] == (1, 378_000_000)
assert load_mapping(source / "runtime-manifest.json")["clock"]["basis"] == "ros_time"
# Only the ROS SDK transport boundary is replaced; timestamps come from stock MCAP.
module.scan_recording = lambda path, topic: {
    "first_ns": data[0].log_time, "last_ns": data[-1].log_time,
    "message_count": len(data), "clock_samples": len(clocks), "total_message_count": len(data) + len(clocks)}
module.prepare(source, output, output)
dataset = load_mapping(output / "dataset-manifest.json")
scenario = load_mapping(output / "scenario.json")
parameters = load_mapping(output / "playback-inputs.json")
validate_document(dataset)
validate_document(scenario, schema="acceptance-scenario.v1")
assert dataset["time"]["basis"] == "system_time"
assert dataset["time"]["start_ns"] == data[0].log_time
assert dataset["time"]["end_ns"] == data[-1].log_time
assert parameters["rate"] == scenario["time_policy"]["playback_rate"] == 1.0
assert parameters["desired_playback_duration_sec"] == 30
assert len(dataset["bag"]["members"]) == len(recordings) == 2
retained_clocks = []
for member, recording in zip(dataset["bag"]["members"], recordings, strict=True):
    retained = output / "source/bag" / recording.relative_to(source / "bags/recording")
    assert before[recording] == recording.read_bytes() == retained.read_bytes()
    assert member["recording"]["sha256"] == hashlib.sha256(before[recording]).hexdigest()
    with retained.open("rb") as stream:
        retained_clocks.extend(message.data for _, channel, message
                               in make_reader(stream, validate_crcs=True).iter_messages()
                               if channel.topic == "/clock")
assert (source / "runtime-manifest.json").read_bytes() == (output / "source/capture/runtime-manifest.json").read_bytes()
assert retained_clocks == clock_bytes
print("wall received span 36 s; ROS Clock payload span 378 ms; rate 1; source bytes unchanged")
PY
  printf '%s\n' "${output}"
  [ "${status}" -eq 0 ]
}


update_capture_recording_metadata() {
  "${FOUNDATION_PYTHON}" - "${CAPTURE}" "$1" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
from robotics_runtime_contracts import load_mapping
from robotics_runtime_contracts.writers import write_document

source = Path(sys.argv[1])
metadata_path = source / "bags/recording/metadata.yaml"
metadata = dict(load_mapping(metadata_path))
for name, value in json.loads(sys.argv[2]).items():
    if value == "__absent__":
        metadata["rosbag2_bagfile_information"]["custom_data"].pop(name, None)
    else:
        metadata["rosbag2_bagfile_information"]["custom_data"][name] = value
metadata_path.write_text(json.dumps(metadata))
statement_path = source / "results/qualification-statement.json"
statement = dict(load_mapping(statement_path))
subject = next(item for item in statement["subject"]
               if item["name"] == "capture/bags/recording/metadata.yaml")
subject["digest"]["sha256"] = hashlib.sha256(metadata_path.read_bytes()).hexdigest()
write_document(statement, statement_path, schema="qualification-bundle.v1")
PY
}

@test "playback preparer keeps compressed ROS-time chronology with explicit timestamp basis" {
  local actual
  for actual in ros_time; do
    prepare_playback_capture_fixture 10 378000000 "-ros-${actual}" ros
    run "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" "${CAPTURE}" "${PREPARED}" <<'PY'
import importlib.util
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
    rows = list(make_reader(stream, validate_crcs=True).iter_messages())
times = sorted({message.log_time for _, channel, message in rows if channel.topic == "/example/sequence"})
clock_bytes = [message.data for _, channel, message in rows if channel.topic == "/clock"]
gaps = [following - previous for previous, following in zip(times, times[1:])]
assert times[-1] - times[0] == 378_000_000 and max(gaps) == 2_000_000
module.scan_recording = lambda path, topic: {
    "first_ns": times[0], "last_ns": times[-1], "message_count": len(times),
    "clock_samples": len(clock_bytes), "total_message_count": len(times) + len(clock_bytes)}
module.prepare(source, output, output)
dataset = load_mapping(output / "dataset-manifest.json")
parameters = load_mapping(output / "playback-inputs.json")
validate_document(dataset)
assert dataset["time"]["basis"] == "ros_time"
assert parameters["rate"] == 0.0126
assert max(gaps) / parameters["rate"] > 100_000_000
assert before == recording.read_bytes() == (output / "source/bag/selected.mcap").read_bytes()
with (output / "source/bag/selected.mcap").open("rb") as stream:
    retained = [message.data for _, channel, message in make_reader(stream, validate_crcs=True).iter_messages()
                if channel.topic == "/clock"]
assert retained == clock_bytes
print("ROS span 378 ms retained; rate 0.0126; Clock bytes unchanged")
PY
    printf '%s\n' "${output}"
    [ "${status}" -eq 0 ]
  done
}

@test "playback preparer refuses contradictory or unobserved qualification recording metadata" {
  local mode changes
  for setting in \
    'wall|{"record_timestamp_basis":"__absent__"}' \
    'wall|{"record_timestamp_basis":null}' \
    'wall|{"record_timestamp_basis":"ros_time"}' \
    'wall|{"record_timestamp_basis":"0"}' \
    'wall|{"record_timestamp_basis":false}' \
    'wall|{"record_timestamp_basis":0}' \
    'ros|{"record_timestamp_basis":null}' \
    'ros|{"record_timestamp_basis":"system_time"}' \
    'ros|{"record_timestamp_basis":"0"}'; do
    mode="${setting%%|*}"
    changes="${setting#*|}"
    prepare_playback_capture_fixture 10 36000000000 "" "${mode}"
    update_capture_recording_metadata "${changes}"
    run "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" "${CAPTURE}" "${PREPARED}" <<'PY'
import importlib.util
import sys
from pathlib import Path
from mcap.reader import make_reader

repository, source, output = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("prepare", repository / "scripts/ci/integration/prepare-playback-inputs.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
recording = source / "bags/recording/selected.mcap"
before = recording.read_bytes()
with recording.open("rb") as stream:
    rows = list(make_reader(stream, validate_crcs=True).iter_messages())
data = [message for _, channel, message in rows if channel.topic == "/example/sequence"]
clocks = [message for _, channel, message in rows if channel.topic == "/clock"]
module.scan_recording = lambda path, topic: {
    "first_ns": data[0].log_time, "last_ns": data[-1].log_time,
    "message_count": len(data), "clock_samples": len(clocks), "total_message_count": len(data) + len(clocks)}
try:
    module.prepare(source, output, output)
except ValueError as error:
    print(error)
else:
    raise AssertionError("contradictory recording metadata was accepted")
assert not (output / "dataset-manifest.json").exists()
assert not (output / "scenario.json").exists()
assert recording.read_bytes() == before
retained = output / "source/bag/selected.mcap"
if retained.exists():
    assert retained.read_bytes() == before
PY
    printf '%s\n' "${output}"
    [ "${status}" -eq 0 ]
    # Each case owns a fresh qualified snapshot; do not reuse partial preparation.
    rm -rf -- "${CAPTURE}" "${PREPARED}"
  done
}

@test "playback desired duration follows the inherited window without overstretching stock timestamp groups" {
  source "${REPOSITORY_ROOT}/scripts/ci/lib.sh"
  ci_set_compose_fixture_env
  # The recorded-playback runner uses this cadence for slowed native timestamp groups.
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
    "message_count": len(times), "clock_samples": clock_count, "total_message_count": len(times) + clock_count}
module.prepare(source, output, output)
parameters = load_mapping(output / "playback-inputs.json")
scenario = load_mapping(output / "scenario.json")
dataset = load_mapping(output / "dataset-manifest.json")
validate_document(scenario, schema="acceptance-scenario.v1")
validate_document(dataset)
window = load_mapping(source / "scenario.yaml")["timeouts"]["execution_sec"]
assert parameters["rate"] == scenario["time_policy"]["playback_rate"]
assert dataset["bag"]["members"][0]["recording"]["sha256"] == module.sha256(recording)
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
    assert interval_ms == 200
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
    prepare_orchestration_fixture
    cp "${PREPARED}/scenario.json" "${SCENARIO}"
    export ROBOTICS_FOUNDATION_PLAYBACK_INPUTS="${PREPARED}"
    unset ROBOTICS_METRICS_EXPORT_INTERVAL_MS
    run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
    [ "${status}" -eq 88 ]
    [ "$(cat "${FOUNDATION_METRICS_ENV}")" = 100 ]
    for requested in 150 200; do
      export ROBOTICS_METRICS_EXPORT_INTERVAL_MS="${requested}"
      run bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
      [ "${status}" -eq 88 ]
      [ "$(cat "${FOUNDATION_METRICS_ENV}")" = "${requested}" ]
    done
    export ROBOTICS_METRICS_EXPORT_INTERVAL_MS=200
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
    "first_ns": 10**9, "last_ns": 2 * 10**9, "message_count": 3, "clock_samples": 3, "total_message_count": 3 + 3}
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
    except (KeyError, ValueError, FileNotFoundError):
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
    "first_ns": 10**9, "last_ns": 2 * 10**9, "message_count": 3, "clock_samples": 3, "total_message_count": 3 + 3}
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
# The isolated renderer consumes the selected foundation image, not an ambient default.
export OBSERVER_IMAGE=local/robotics-runtime-infra/acceptance-observer:ci
source scripts/ci/foundation/lib.sh
foundation_load_artifact_arguments "${consumer_root}" ""
foundation_stage_extension_schemas "${run_dir}"
robot_selected="$("${FOUNDATION_PYTHON}" docker/runtime/admit-robot-description \
  --root "${root}" --scenario examples/minimal-consumer/scenario.yaml | jq -r '.selected')"
[[ "${robot_selected}" == false ]]
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

@test "source startup defers neutral readiness before stepping and keeps playback capture early" {
  local boundary="${BATS_TEST_TMPDIR}/capture-boundary.sh"
  {
    cat <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root="$1"; data_source="$2"; run_dir="$3"; robot_selected="$4"
script_dir="${root}/scripts/ci/foundation"
foundation_bin="${run_dir}/bin"
ROBOTICS_SIMULATION_OCI_DIGEST=fixture
ROBOTICS_ROBOT_DESCRIPTION_PATH=/fixture/neutral.urdf
FOUNDATION_NATIVE_READINESS_STATUS="${5:-0}"
artifact_dir="${run_dir}/artifacts"
mkdir -p "${run_dir}/configuration" "${artifact_dir}/provider" "${foundation_bin}"
events="${run_dir}/events"
compose=(docker compose)
extra_services=()
startup_extra_services=()
if [[ "${robot_selected}" == false ]]; then
  [[ "$("${FOUNDATION_PYTHON}" "${root}/docker/runtime/admit-robot-description" \
    --root "${root}" --scenario "${root}/examples/minimal-consumer/scenario.yaml" | jq -r '.selected')" == false ]]
fi
# Harness explanation is a leaf invocation here; role binding is tested separately.
cat >"${foundation_bin}/python" <<'PYTHON'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == -I && "$2" == -m && "$3" == robotics_acceptance_harness.cli && "$4" == explain ]]
printf '{}\n'
PYTHON
chmod +x "${foundation_bin}/python"
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
bash() {
  if [[ "$1" == *"/wait-ready.sh" ]]; then
    publish readiness
    # A paused periodic writer must not own the clock during native readiness.
    [[ ! -e "${run_dir}/stepper-started" ]] || return 61
    return "${FOUNDATION_NATIVE_READINESS_STATUS}"
  fi
  provider_fixture
}
docker() {
  if [[ "$1" == inspect ]]; then
    printf '[{"HostConfig":{}}]\n'
  elif [[ " $* " == *' up '* ]]; then
    if [[ "${@: -1}" == simulation-stepper ]]; then
      publish stepper
      : >"${run_dir}/stepper-started"
    fi
    [[ "${@: -1}" != neutral-robot ]] || publish robot
    [[ " $* " != *' recorder '* ]] || publish recorder
    [[ " $* " != *' runtime-probe-publisher '* ]] || publish publisher
  elif [[ " $* " == *' run '* ]]; then
    if [[ " $* " == *' check_urdf '* ]]; then
      publish parse
      printf 'parse-check-executed\n'
    elif [[ " $* " == *' -name unreadable_neutral_robot '* ]]; then
      printf 'Entity creation successful.\n'
    else
      publish manifest
      jq -n --arg digest "$(sha256sum "${root}/config/fastdds/udp-only.xml" | cut -d' ' -f1)" \
        '{schema_version:"runtime-manifest.v1",
          data_plane:{middleware_configuration_sha256:$digest},
          configuration_artifacts:[{kind:"host_topology"},{kind:"runtime_resources"}]}' \
        >"${run_dir}/runtime-manifest.json"
    fi
  elif [[ " $* " == *' exec '* ]]; then
    if [[ "${@: -1}" == /run/robotics/product/.readiness-missing.urdf ]]; then
      return 0
    fi
    cat >/dev/null
    if [[ " $* " == *' --entity unreadable_neutral_robot '* ]]; then
      printf '{"status":"entity_absent","result":{"result":1},"entity":"unreadable_neutral_robot","expected":"present","exists":false}\n'
      return 70
    fi
    printf '{"status":"passed","result":{"result":1},"exists":false}\n'
  elif [[ " $* " == *' port '* ]]; then
    printf '127.0.0.1:13133\n'
  elif [[ " $* " == *' ps '* ]]; then
    printf 'fixture-container\n'
  else
    return 90
  fi
}
# The production deadline runs a child Bash; export only these leaf I/O spies.
export root run_dir artifact_dir events FOUNDATION_NATIVE_READINESS_STATUS
export -f docker bash publish provider_fixture
SH
    # Execute contiguous production startup through publication. Leaf transports
    # expose ordering and failure propagation, not native ROS observation.
    awk '
      /^sudo chown -R 1000:1000/ { emit = 1 }
      emit && /^observer_compose=/ { exit }
      emit { print }
    ' "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
  } >"${boundary}"
  local source
  for source in simulator recording_playback; do
    run bash "${boundary}" "${REPOSITORY_ROOT}" "${source}" \
      "${BATS_TEST_TMPDIR}/${source}" false
    printf '%s\n' "${output}"
    [ "${status}" -eq 0 ]
    local expected="${BATS_TEST_TMPDIR}/expected-${source}"
    if [[ "${source}" == simulator ]]; then
      printf 'provider\nstepper\nmanifest\npublisher\nrecorder\n' >"${expected}"
    else
      printf 'recorder\nprovider\nmanifest\n' >"${expected}"
    fi
    run diff -u "${expected}" "${BATS_TEST_TMPDIR}/${source}/events"
    printf '%s\n' "${output}"
    [ "${status}" -eq 0 ]
  done

  run bash "${boundary}" "${REPOSITORY_ROOT}" simulator \
    "${BATS_TEST_TMPDIR}/neutral" true
  printf '%s\n' "${output}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/neutral/events")" = $'provider\nmanifest\nparse\nrobot\nreadiness\nstepper\npublisher\nrecorder' ]

  run bash "${boundary}" "${REPOSITORY_ROOT}" simulator \
    "${BATS_TEST_TMPDIR}/failed-readiness" true 77
  [ "${status}" -eq 77 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/failed-readiness/events")" = $'provider\nmanifest\nparse\nrobot\nreadiness' ]
  [ ! -e "${BATS_TEST_TMPDIR}/failed-readiness/stepper-started" ]

  # The old early stepper order must fail this fixture before capture starts.
  local early_stepper="${BATS_TEST_TMPDIR}/early-stepper.sh"
  sed 's/ && "${robot_selected}" != true//' "${boundary}" >"${early_stepper}"
  run bash "${early_stepper}" "${REPOSITORY_ROOT}" simulator \
    "${BATS_TEST_TMPDIR}/early-stepper" true
  [ "${status}" -eq 61 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/early-stepper/events")" = $'provider\nstepper\nmanifest\nparse\nrobot\nreadiness' ]
}


@test "neutral startup preserves its shell input through the native parse check" {
  local fixture="${BATS_TEST_TMPDIR}/neutral-lifecycle"
  local context="${fixture}/context.sh" old_context="${fixture}/old-context.sh"
  local missing_flag_context="${fixture}/missing-flag-context.sh"
  mkdir -p "${fixture}/examples/neutral-robot"
  : >"${fixture}/examples/neutral-robot/check-entity.py"
  export FOUNDATION_LIFECYCLE_TRACE="${fixture}/events"
  cat >"${fixture}/compose" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  run)
    if [[ "${@: -2:1}" == check_urdf && "${@: -1}" == /fixture/neutral.urdf ]]; then
      printf 'check_urdf\n' >>"${FOUNDATION_LIFECYCLE_TRACE}"
      printf 'parse-check-executed\n'
      # Model only Compose run's stdin forwarding, never URDF/ROS behavior.
      [[ " $* " == *' --interactive=false '* ]] || cat >/dev/null
      exit "${FOUNDATION_PARSE_STATUS:-0}"
    fi
    [[ " $* " == *' -name unreadable_neutral_robot '* ]]
    printf 'unreadable-create\n' >>"${FOUNDATION_LIFECYCLE_TRACE}"
    printf 'Entity creation successful.\n'
    ;;
  exec)
    if [[ "${@: -1}" == /run/robotics/product/.readiness-missing.urdf ]]; then
      printf 'missing-file\n' >>"${FOUNDATION_LIFECYCLE_TRACE}"
      [[ " $* " == *' --interactive=false '* ]] || cat >/dev/null
    elif [[ " $* " == *' --entity unreadable_neutral_robot '* ]]; then
      [[ " $* " == *' --no-wait '* ]]
      cat >/dev/null
      printf 'unreadable-entity\n' >>"${FOUNDATION_LIFECYCLE_TRACE}"
      if [[ "${FOUNDATION_ENTITY_SERVICE_ERROR:-0}" == 1 ]]; then
        printf '{"status":"service_failed","result":{"result":1},"exists":false}\n'
        exit 69
      fi
      printf '{"status":"entity_absent","result":{"result":1},"entity":"unreadable_neutral_robot","expected":"present","exists":false}\n'
      exit 70
    else
      cat >/dev/null
      printf 'absent-entity\n' >>"${FOUNDATION_LIFECYCLE_TRACE}"
      printf '{"status":"passed","result":{"result":1},"exists":false}\n'
    fi
    ;;
  up)
    printf 'fresh-fixture-container\n' >"${FOUNDATION_LIFECYCLE_TRACE}.container"
    printf 'up\n' >>"${FOUNDATION_LIFECYCLE_TRACE}"
    ;;
  ps)
    printf 'ps\n' >>"${FOUNDATION_LIFECYCLE_TRACE}"
    cat "${FOUNDATION_LIFECYCLE_TRACE}.container"
    ;;
  *) exit 64 ;;
esac
SH
  cat >"${fixture}/examples/neutral-robot/wait-ready.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "$(cat "${FOUNDATION_LIFECYCLE_TRACE}.container")" ]]
printf 'wait-ready\n' >>"${FOUNDATION_LIFECYCLE_TRACE}"
SH
  chmod +x "${fixture}/compose"
  {
    cat <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root="$1"; artifact_dir="$2"
mkdir -p "${artifact_dir}"
ROBOTICS_ROBOT_DESCRIPTION_PATH=/fixture/neutral.urdf
compose=("${root}/compose")
SH
    # Execute the production deadline/heredoc; leaf scripts above expose only
    # shell-input ownership and call order, not native ROS readiness.
    awk '
      /^  timeout --signal=TERM --kill-after=2s 90s bash -s --/ { emit = 1 }
      emit { print }
      emit && /^SH$/ { exit }
    ' "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
  } >"${context}"
  run bash "${context}" "${fixture}" "${fixture}/current"
  [ "${status}" -eq 0 ]
  [ "$(cat "${FOUNDATION_LIFECYCLE_TRACE}")" = $'check_urdf\nabsent-entity\nmissing-file\nunreadable-create\nunreadable-entity\nup\nps\nwait-ready' ]
  [ "$(cat "${fixture}/current/robot-description-check-urdf.log")" = parse-check-executed ]

  : >"${FOUNDATION_LIFECYCLE_TRACE}"
  rm -- "${FOUNDATION_LIFECYCLE_TRACE}.container"
  run env FOUNDATION_PARSE_STATUS=17 bash "${context}" "${fixture}" "${fixture}/parse-failure"
  [ "${status}" -eq 17 ]
  [ "$(cat "${FOUNDATION_LIFECYCLE_TRACE}")" = check_urdf ]
  [ ! -e "${FOUNDATION_LIFECYCLE_TRACE}.container" ]

  : >"${FOUNDATION_LIFECYCLE_TRACE}"
  run env FOUNDATION_ENTITY_SERVICE_ERROR=1 bash "${context}" "${fixture}" "${fixture}/service-failure"
  [ "${status}" -ne 0 ]
  [ ! -e "${FOUNDATION_LIFECYCLE_TRACE}.container" ]
  [ "$(jq -r '.status' "${fixture}/service-failure/robot-readiness/unreadable-entity.json")" = service_failed ]

  sed 's/ --no-wait//' "${context}" >"${missing_flag_context}"
  : >"${FOUNDATION_LIFECYCLE_TRACE}"
  run bash "${missing_flag_context}" "${fixture}" "${fixture}/missing-flag"
  [ "${status}" -ne 0 ]
  [ ! -e "${FOUNDATION_LIFECYCLE_TRACE}.container" ]

  sed 's/ --interactive=false//' "${context}" >"${old_context}"
  : >"${FOUNDATION_LIFECYCLE_TRACE}"
  run bash "${old_context}" "${fixture}" "${fixture}/old"
  [ "${status}" -eq 0 ]
  [ "$(cat "${FOUNDATION_LIFECYCLE_TRACE}")" = check_urdf ]
  [ ! -e "${FOUNDATION_LIFECYCLE_TRACE}.container" ]
}

@test "native recorder sealing precedes publisher shutdown and preserves failure exits" {
  local boundary="${BATS_TEST_TMPDIR}/seal-boundary.sh"
  {
    cat <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
data_source="$1"
simulation_container=fixture-playback
trace="$2"
sealed_marker="${trace}.sealed"
run_dir="${trace}.run"
artifact_dir="${trace}.artifacts"
project=fixture-seal
playback_completion="${EOF_ROUTE:-controlled-stop}"
playback_eof_deadline=75
ROBOTICS_SIMULATION_LOCAL_IMAGE_ID=fixture-image
root=fixture-tooling
foundation_observe_player_exit() {
  [[ "$1" == fixture-playback && "$3" == fixture-seal && "$4" == fixture-image && "$5" == 75 ]]
  [[ -f "${sealed_marker}" ]]
  printf 'natural-eof\n' >>"${trace}"
  return "${EOF_WAIT_STATUS:-0}"
}
mkdir -p "${run_dir}" "${artifact_dir}"
export trace sealed_marker
compose_leaf() {
  if [[ " $* " == *' run '* ]]; then
    [[ "${playback_completion}" == natural-eof && -f "${sealed_marker}" ]]
    printf 'terminal-validation\n' >>"${trace}"
    return "${EOF_VALIDATION_STATUS:-0}"
  fi
  if [[ "$*" == 'ps --all --quiet runtime-metrics' ]]; then
    return 0
  fi
  [[ " $* " == *' stop '* ]]
  if [[ "${@: -1}" == recorder ]]; then
    printf 'recorder\n' >>"${trace}"
    [[ "${SEAL_FAILURE:-0}" != 1 ]] || return 31
    touch "${sealed_marker}"
  else
    [[ -f "${sealed_marker}" ]] || return 87
    printf '%s\n' "${@: -1}" >>"${trace}"
  fi
}
docker() {
  [[ "$1" == inspect ]]
  printf '%s\n' "${PLAYBACK_RUNNING:-true}"
}
export -f compose_leaf
compose=(bash -c 'compose_leaf "$@"' compose_leaf)
SH
    # Reuse the production helper; its bounded read runs the fixture CLI with
    # no metrics containers. Native closure and rollover remain separate gates.
    awk '
      /^capture_runtime_metrics_diagnostics\(\) {/ { emit = 1 }
      emit && /^publish_failure_evidence\(\) {/ { exit }
      emit { print }
    ' "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
    # Exercise production ordering; native closure and rollover are separate gates.
    awk '
      /^# Seal native capture while observed publishers remain active\./ { emit = 1 }
      emit && /^sleep 2$/ { exit }
      emit { print }
    ' "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance.sh"
  } >"${boundary}"
  local source trace
  for source in simulator recording_playback; do
    trace="${BATS_TEST_TMPDIR}/${source}.events"
    run bash "${boundary}" "${source}" "${trace}"
    [ "${status}" -eq 0 ]
    [ "$(head -n 1 "${trace}")" = recorder ]
    if [[ "${source}" == simulator ]]; then
      [ "$(cat "${trace}")" = $'recorder\nruntime-probe-publisher' ]
    else
      [ "$(cat "${trace}")" = $'recorder\nruntime-metrics\nplayback' ]
    fi
    trace="${BATS_TEST_TMPDIR}/${source}-seal-failed.events"
    run env SEAL_FAILURE=1 bash "${boundary}" "${source}" "${trace}"
    [ "${status}" -eq 31 ]
    [ "$(cat "${trace}")" = recorder ]
  done
  trace="${BATS_TEST_TMPDIR}/natural-eof.events"
  run env EOF_ROUTE=natural-eof bash "${boundary}" recording_playback "${trace}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${trace}")" = $'recorder\nruntime-metrics\nnatural-eof\nterminal-validation' ]
  trace="${BATS_TEST_TMPDIR}/natural-timeout.events"
  run env EOF_ROUTE=natural-eof EOF_WAIT_STATUS=124 bash "${boundary}" recording_playback "${trace}"
  [ "${status}" -eq 124 ]
  [ "$(cat "${trace}")" = $'recorder\nruntime-metrics\nnatural-eof' ]
  trace="${BATS_TEST_TMPDIR}/natural-invalid.events"
  run env EOF_ROUTE=natural-eof EOF_VALIDATION_STATUS=62 bash "${boundary}" recording_playback "${trace}"
  [ "${status}" -eq 62 ]
  [ "$(cat "${trace}")" = $'recorder\nruntime-metrics\nnatural-eof\nterminal-validation' ]
  trace="${BATS_TEST_TMPDIR}/ended-playback.events"
  run env PLAYBACK_RUNNING=false bash "${boundary}" recording_playback "${trace}"
  [ "${status}" -eq 70 ]
  [ ! -e "${trace}" ]
}

@test "replay preserves declared schema bytes and payload with retained-only public validation" {
  prepare_playback_capture_fixture
  run "${FOUNDATION_PYTHON}" - "${REPOSITORY_ROOT}" "${CAPTURE}" "${PREPARED}" <<'PY'
import hashlib
import importlib.util
import json
import shutil
import sys
from pathlib import Path
from robotics_acceptance_harness.extension_schemas import load_extension_schemas
from robotics_runtime_contracts import load_mapping, validate_document
from robotics_runtime_contracts.writers import write_document

repository, source, output = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("prepare", repository / "scripts/ci/integration/prepare-playback-inputs.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
uri = "https://example.org/robotics/generic-consumer.schema.json"
schema = source / "caller-schema.json"
raw = (repository / "examples/generic-consumer/inputs/extension.schema.json").read_bytes()
schema.write_bytes(raw)
registry = [uri + "=" + str(schema)]
schemas = load_extension_schemas(registry)
scenario = dict(load_mapping(source / "scenario.yaml"))
generic = load_mapping(repository / "examples/generic-consumer/scenario.yaml")
scenario["extension_schemas"] = generic["extension_schemas"]
scenario["extensions"] = generic["extensions"]
write_document(scenario, source / "scenario.yaml", schema="acceptance-scenario.v1", extension_schemas=schemas)
context = dict(load_mapping(source / "acceptance-run.json"))
context["scenario_sha256"] = module.sha256(source / "scenario.yaml")
write_document(context, source / "acceptance-run.json")
statement = dict(load_mapping(source / "results/qualification-statement.json"))
for subject in statement["subject"]:
    if subject["name"] == "scenario.json":
        subject["digest"]["sha256"] = module.sha256(source / "scenario.yaml")
    if subject["name"] == "acceptance-run.json":
        subject["digest"]["sha256"] = module.sha256(source / "acceptance-run.json")
write_document(statement, source / "results/qualification-statement.json", schema="qualification-bundle.v1")
originals = {path: path.read_bytes() for path in [schema, source / "scenario.yaml", source / "acceptance-run.json",
                                                  source / "results/qualification-statement.json"]}
# Existing absent ROS transport boundary only; all byte/MCAP/public role guards are real.
module.scan_recording = lambda path, topic: {
    "first_ns": 10**9, "last_ns": 2 * 10**9, "message_count": 3,
    "clock_samples": 3, "total_message_count": 6}
for options, reason in [
    ([], "supplied"),
    ([uri + "=" + str(schema)] * 2, "more than once"),
]:
    target = output.with_name(output.name + "-refused-" + str(len(options)))
    try:
        module.prepare(source, target, target, extension_schema_options=options)
    except ValueError:
        pass
    else:
        raise AssertionError("invalid registry was admitted")
    assert not target.exists()
    assert originals == {path: path.read_bytes() for path in originals}
schema.write_bytes(raw + b"\n")
target = output.with_name(output.name + "-wrong")
try:
    module.prepare(source, target, target, extension_schema_options=registry)
except ValueError as error:
    assert "digest does not match" in str(error)
else:
    raise AssertionError("changed schema was admitted")
assert not target.exists()
schema.write_bytes(raw)
authenticated_sha = module.sha256(source / "results/qualification-statement.json")
# A coherent unsigned replacement passes old self-consistency, but not the
# statement SHA authenticated by the parent from the real signed package.
scenario["scenario_id"] = "org.example.changed-source"
write_document(scenario, source / "scenario.yaml", schema="acceptance-scenario.v1", extension_schemas=schemas)
context["scenario_sha256"] = module.sha256(source / "scenario.yaml")
write_document(context, source / "acceptance-run.json")
for subject in statement["subject"]:
    if subject["name"] == "scenario.json":
        subject["digest"]["sha256"] = module.sha256(source / "scenario.yaml")
    if subject["name"] == "acceptance-run.json":
        subject["digest"]["sha256"] = module.sha256(source / "acceptance-run.json")
write_document(statement, source / "results/qualification-statement.json", schema="qualification-bundle.v1")
module.source_capture(source, extension_schemas=schemas)
target = output.with_name(output.name + "-unsigned-replacement")
try:
    module.prepare(source, target, target, extension_schema_options=registry, statement_sha256=authenticated_sha)
except ValueError as error:
    assert "authenticated source package" in str(error)
else:
    raise AssertionError("coherent unsigned source replacement was admitted")
assert not target.exists()
for path, original in originals.items():
    path.write_bytes(original)
original_copy = module.copy_input
statement_path = source / "results/qualification-statement.json"
def late_changed_statement(a, b):
    # The native source capture has returned; change only its unsigned statement.
    statement_path.write_bytes(originals[statement_path] + b" ")
    return original_copy(a, b)
module.copy_input = late_changed_statement
target = output.with_name(output.name + "-late-statement")
try:
    module.prepare(source, target, target, extension_schema_options=registry, statement_sha256=authenticated_sha)
except ValueError as error:
    assert "retained capture differs" in str(error)
else:
    raise AssertionError("late statement replacement was admitted")
finally:
    module.copy_input = original_copy
    statement_path.write_bytes(originals[statement_path])
assert not (target / "dataset-manifest.json").exists()
assert not (target / "scenario.json").exists()
assert originals == {path: path.read_bytes() for path in originals}
module.prepare(source, output, output, extension_schema_options=registry, statement_sha256=authenticated_sha)
assert originals == {path: path.read_bytes() for path in originals}
replay = load_mapping(output / "scenario.json")
assert replay["extensions"] == scenario["extensions"]
assert replay["extension_schemas"] == scenario["extension_schemas"]
paths = (output / "extension-schema-arguments.txt").read_text().splitlines()
assert paths[::2] == ["--extension-schema"]
retained_option = paths[1]
retained = Path(retained_option.partition("=")[2])
assert retained.read_bytes() == raw
assert retained.stat().st_mode & 0o777 == 0o444
shutil.rmtree(source)
retained_map = load_extension_schemas([retained_option])
validate_document(replay, schema="acceptance-scenario.v1", extension_schemas=retained_map)
validate_document(load_mapping(output / "source/capture/scenario.yaml"),
                  schema="acceptance-scenario.v1", extension_schemas=retained_map)
assert replay["dataset_manifest_sha256"] == module.sha256(output / "dataset-manifest.json")
PY
  [ "${status}" -eq 0 ]
}

prepare_player_terminal_fixture() {
  TERMINAL_ROOT="${BATS_TEST_TMPDIR}/terminal"
  TERMINAL_CID="$(printf '%064d' 1)"
  TERMINAL_IMAGE="sha256:$(printf '%064d' 2)"
  export TERMINAL_ROOT TERMINAL_CID TERMINAL_IMAGE
  mkdir -p "${TERMINAL_ROOT}/bin" "${TERMINAL_ROOT}/facts/logs"
  "${FOUNDATION_PYTHON}" - <<'PY'
import copy
import json
import os
from pathlib import Path
root = Path(os.environ["TERMINAL_ROOT"])
before = {"Id": os.environ["TERMINAL_CID"], "Image": os.environ["TERMINAL_IMAGE"],
          "Config": {"Cmd": ["ros2", "bag", "play"], "Labels": {
              "com.docker.compose.project": "owned",
              "com.docker.compose.service": "playback"}},
          "RestartCount": 0, "State": {"Status": "running", "Running": True, "OOMKilled": False}}
after = copy.deepcopy(before)
after["State"].update(Status="exited", Running=False, ExitCode=0, Dead=False)
for name, value in (("before.json", before), ("after.json", after)):
    (root / name).write_text(json.dumps([value]))
PY
  cat >"${TERMINAL_ROOT}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${*: -1}" == "${TERMINAL_CID}" ]]
printf '%s\n' "$1" >>"${TERMINAL_ROOT}/events"
case "$1" in
  inspect)
    if [[ -e "${TERMINAL_ROOT}/waited" ]]; then
      cat "${TERMINAL_ROOT}/after.json"
    else
      cat "${TERMINAL_ROOT}/before.json"
    fi ;;
  wait)
    touch "${TERMINAL_ROOT}/waited"
    if [[ "${NATIVE_WAIT_OUTPUT+x}" == x ]]; then
      printf '%s' "${NATIVE_WAIT_OUTPUT}"
    else
      printf '0\n'
    fi
    exit "${NATIVE_WAIT_STATUS:-0}" ;;
  logs) printf 'natural player end\n' ;;
  *) exit 89 ;;
esac
SH
  chmod +x "${TERMINAL_ROOT}/bin/docker"
  export PATH="${TERMINAL_ROOT}/bin:${PATH}"
}

@test "shared native EOF wait retains exact originals and rejects timed out client" {
  prepare_player_terminal_fixture
  run foundation_observe_player_exit "${TERMINAL_CID}" "${TERMINAL_ROOT}/facts" owned "${TERMINAL_IMAGE}" 75
  [ "${status}" -eq 0 ]
  [ "$(cat "${TERMINAL_ROOT}/events")" = $'inspect\nwait\ninspect\nlogs' ]
  cmp "${TERMINAL_ROOT}/before.json" "${TERMINAL_ROOT}/facts/player-before-wait.json"
  cmp "${TERMINAL_ROOT}/after.json" "${TERMINAL_ROOT}/facts/player-after-wait.json"
  rm "${TERMINAL_ROOT}/events" "${TERMINAL_ROOT}/waited"
  export NATIVE_WAIT_STATUS=124
  run foundation_observe_player_exit "${TERMINAL_CID}" "${TERMINAL_ROOT}/facts" owned "${TERMINAL_IMAGE}" 75
  [ "${status}" -eq 124 ]
  jq -e '.wait_client_exit_code == 124 and .stop_requested_before_wait == false' \
    "${TERMINAL_ROOT}/facts/player-terminal.json"
}

@test "shared native EOF wait refuses foreign or looping player before wait" {
  prepare_player_terminal_fixture
  for change in foreign loop; do
    cp "${TERMINAL_ROOT}/before.json" "${TERMINAL_ROOT}/original.json"
    if [[ "${change}" == foreign ]]; then
      jq '.[0].Config.Labels["com.docker.compose.project"] = "foreign"' \
        "${TERMINAL_ROOT}/original.json" >"${TERMINAL_ROOT}/before.json"
    else
      jq '.[0].Config.Cmd += ["--loop"]' \
        "${TERMINAL_ROOT}/original.json" >"${TERMINAL_ROOT}/before.json"
    fi
    : >"${TERMINAL_ROOT}/events"
    run foundation_observe_player_exit "${TERMINAL_CID}" "${TERMINAL_ROOT}/facts" owned "${TERMINAL_IMAGE}" 75
    [ "${status}" -ne 0 ]
    [ "$(cat "${TERMINAL_ROOT}/events")" = inspect ]
    mv "${TERMINAL_ROOT}/original.json" "${TERMINAL_ROOT}/before.json"
  done
}

@test "natural EOF policy refuses non-playback and missing isolation replay before effects" {
  prepare_orchestration_fixture
  write_orchestration_scenario '{"evidence_policy":{"max_segment_duration_sec":7}}'
  run env ROBOTICS_FOUNDATION_PLAYBACK_COMPLETION=natural-eof \
    bash "${FIXTURE}/scripts/ci/foundation/run-acceptance.sh"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *'natural EOF requires declared recorded playback'* ]]
  [ ! -e "${FOUNDATION_RECORDING_ENV}" ]

  run env ROBOTICS_FOUNDATION_PLAYBACK_COMPLETION=unknown \
    bash "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance-isolation.sh"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *'playback completion must be controlled-stop or natural-eof'* ]]
  run env ROBOTICS_FOUNDATION_PLAYBACK_COMPLETION=natural-eof \
    ROBOTICS_FOUNDATION_QUALIFY_PLAYBACK=0 \
    bash "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance-isolation.sh"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *'natural EOF requires the recorded-playback qualification route'* ]]
}

@test "isolation actual callsites issue controlled LIVE and caller-selected replay completion" {
  local fixture="${BATS_TEST_TMPDIR}/isolation-wire"
  mkdir -p "${fixture}/child" "${fixture}/observed"
  cat >"${fixture}/child/run-acceptance.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "${ROBOTICS_FOUNDATION_PLAYBACK_COMPLETION}" \
  >"${WIRE_OUTPUT}/${ROBOTICS_FOUNDATION_RUN_ID}"
SH
  {
    cat <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$1/child"
export WIRE_OUTPUT="$1/observed"
ROBOTICS_FOUNDATION_PLAYBACK_COMPLETION="$2"
playback_completion="$2"
base_run_id=wire
run_a=wire-a run_b=wire-b
artifact_a=unused-a artifact_b=unused-b
project_a=owned-a project_b=owned-b
root=unused-root prepared=unused-prepared
replay_argument_file=unused-arguments
SH
    # Run the real function and BOTH real LIVE callsites; only their child I/O is replaced.
    awk '
      /^run_acceptance\(\) \(/ { emit = 1 }
      emit { print }
      /^pid_b=\$!/ { exit }
    ' "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance-isolation.sh"
    printf 'wait "$pid_a"; wait "$pid_b"\n'
    # The final call uses the untouched parent caller selection.
    awk '
      /^  ROBOTICS_FOUNDATION_ARTIFACT_ARGUMENTS_FILE=/ { emit = 1 }
      emit && /^fi$/ { exit }
      emit { print }
    ' "${REPOSITORY_ROOT}/scripts/ci/foundation/run-acceptance-isolation.sh"
    printf '[[ "$ROBOTICS_FOUNDATION_PLAYBACK_COMPLETION" == "$2" ]]\n'
  } >"${fixture}/wire.sh"
  local selected
  for selected in controlled-stop natural-eof; do
    run bash "${fixture}/wire.sh" "${fixture}" "${selected}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${fixture}/observed/wire-a")" = controlled-stop ]
    [ "$(cat "${fixture}/observed/wire-b")" = controlled-stop ]
    [ "$(cat "${fixture}/observed/wire-recorded-playback")" = "${selected}" ]
  done
}
