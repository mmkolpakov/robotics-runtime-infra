"""Prepare one finalized stock UInt64 capture for the existing live playback runner."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import shutil
import sys
from pathlib import Path
from typing import Any

from robotics_runtime_contracts import loads_mapping, validate_document
from robotics_runtime_contracts.serialization import read_document_bytes
from robotics_runtime_contracts.writers import write_document

MESSAGE_TYPE = "std_msgs/msg/UInt64"


def captured_document(path: Path) -> tuple[dict[str, Any], bytes]:
    raw = read_document_bytes(path)
    return dict(loads_mapping(raw, source_name=str(path))), raw


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def copy_input(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_file():
        raise ValueError("capture inputs must be regular files")
    destination.parent.mkdir(parents=True, exist_ok=True)
    before = source.stat()
    digest = sha256(source)
    shutil.copyfile(source, destination)
    after = source.stat()
    if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    ) or sha256(destination) != digest:
        raise ValueError("capture input changed during retention")


def scan_recording(path: Path, topic: str) -> dict[str, int]:
    # Only the preparer needs native ROS; the conformance writer stays portable.
    import rosbag2_py
    from rclpy.serialization import deserialize_message
    from rosgraph_msgs.msg import Clock
    from std_msgs.msg import UInt64

    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=str(path), storage_id="mcap"),
        rosbag2_py.ConverterOptions("", ""),
    )
    if not reader.set_read_order(
        rosbag2_py.ReadOrder(rosbag2_py.ReadOrderSortBy.File, False)
    ):
        reader.close()
        raise ValueError(
            "MCAP reader must support native file order for the no-reset scan"
        )
    first = last = first_clock = previous_clock = None
    count = clocks = 0
    try:
        while reader.has_next():
            name, raw, timestamp = reader.read_next()
            if name == "/clock":
                stamp = deserialize_message(raw, Clock).clock
                value = stamp.sec * 1_000_000_000 + stamp.nanosec
                if previous_clock is not None and value < previous_clock:
                    raise ValueError(
                        "stock capture contains a reset or backward ROS clock"
                    )
                first_clock = value if first_clock is None else first_clock
                previous_clock = value
                clocks += 1
            elif name == topic:
                deserialize_message(raw, UInt64)
                if last is not None and timestamp < last:
                    raise ValueError("stock UInt64 recording time is not monotonic")
                first = timestamp if first is None else first
                last = timestamp
                count += 1
    finally:
        reader.close()
    if (
        first is None
        or last is None
        or last <= first
        or count < 2
        or clocks < 2
        or first_clock is None
        or previous_clock is None
        or previous_clock <= first_clock
    ):
        raise ValueError("stock capture needs advancing Clock and UInt64 samples")
    return {
        "first_ns": first,
        "last_ns": last,
        "message_count": count,
        "clock_samples": clocks,
    }


def source_capture(
    root: Path,
) -> tuple[dict[str, Any], Path, Path, Path, str, dict[Path, str]]:
    scenario, scenario_raw = captured_document(root / "scenario.yaml")
    runtime, runtime_raw = captured_document(root / "runtime-manifest.json")
    statement, statement_raw = captured_document(
        root / "results/qualification-statement.json"
    )
    validate_document(statement, schema="qualification-bundle.v1")
    subjects = {item["name"]: item["digest"]["sha256"] for item in statement["subject"]}
    if (
        subjects["scenario.json"] != hashlib.sha256(scenario_raw).hexdigest()
        or subjects["runtime-manifests/primary.json"]
        != hashlib.sha256(runtime_raw).hexdigest()
    ):
        raise ValueError(
            "capture scenario/runtime differs from the completed source statement"
        )
    expected = {
        root / "scenario.yaml": hashlib.sha256(scenario_raw).hexdigest(),
        root / "runtime-manifest.json": hashlib.sha256(runtime_raw).hexdigest(),
        root / "results/qualification-statement.json": hashlib.sha256(
            statement_raw
        ).hexdigest(),
        root / "configuration/capture/qos-overrides.yaml": subjects[
            "capture/qos-overrides.yaml"
        ],
        root / "configuration/capture/mcap-writer.yaml": subjects[
            "capture/mcap-writer.yaml"
        ],
    }
    validate_document(scenario, schema="acceptance-scenario.v1")
    validate_document(runtime)
    if (
        scenario["execution"]["data_source"] != "simulator"
        or runtime["execution"]["data_source"] != "simulator"
    ):
        raise ValueError(
            "playback origin must be the completed stock simulator capture"
        )
    topics = [
        item["name"]
        for item in scenario["expected_ros_graph"]["topics"]
        if item["type"] == MESSAGE_TYPE
    ]
    if len(topics) != 1:
        raise ValueError("stock capture must declare exactly one UInt64 topic")
    recording, summary, metadata, raw_expected = finalized_recording(
        root, subjects, statement
    )
    expected.update(raw_expected)
    return scenario, recording, summary, metadata, topics[0], expected


def finalized_recording(
    root: Path, subjects: dict[str, str], statement: dict[str, Any]
) -> tuple[Path, Path, Path, dict[Path, str]]:
    files = sorted((root / "bags").rglob("*.mcap"))
    summaries = sorted((root / "evidence/summaries").glob("*.recording-summary.json"))
    if len(files) != 1 or len(summaries) != 1:
        raise ValueError(
            "stock playback requires exactly one finalized MCAP and summary"
        )
    recording, summary = files[0], summaries[0]
    declared, summary_raw = captured_document(summary)
    validate_document(declared)
    artifacts = statement["predicate"]["artifacts"]
    summary_subjects = [
        item["subject_name"]
        for item in artifacts
        if item["kind"] == "recording_summary"
    ]
    digest = sha256(recording)
    if (
        len(summary_subjects) != 1
        or subjects[summary_subjects[0]] != hashlib.sha256(summary_raw).hexdigest()
        or declared["source_sha256"] != digest
        or not any(
            item["kind"] == "recording" and subjects[item["subject_name"]] == digest
            for item in artifacts
        )
    ):
        raise ValueError(
            "capture summary/raw MCAP differs from the completed source statement"
        )
    metadata = recording.parent / "metadata.yaml"
    info, metadata_raw = captured_document(metadata)
    if (
        subjects["capture/bags/" + str(metadata.relative_to(root / "bags"))]
        != hashlib.sha256(metadata_raw).hexdigest()
    ):
        raise ValueError("capture metadata differs from the completed source statement")
    bag = info["rosbag2_bagfile_information"]
    if bag["storage_identifier"] != "mcap" or bag["relative_file_paths"] != [
        recording.name
    ]:
        raise ValueError("selected bag metadata must bind the one played MCAP")
    index, index_raw = captured_document(root / "evidence/evidence-index.json")
    validate_document(index)
    if (
        subjects["evidence-indexes/primary.json"]
        != hashlib.sha256(index_raw).hexdigest()
    ):
        raise ValueError(
            "capture evidence index differs from the completed source statement"
        )
    if not any(
        item.get("kind") == "recording"
        and item.get("sha256") == digest
        and item.get("size_bytes") == recording.stat().st_size
        and item["recording_summary"]["sha256"]
        == hashlib.sha256(summary_raw).hexdigest()
        and item["recording_summary"]["size_bytes"] == len(summary_raw)
        for item in index["artifacts"]
    ):
        raise ValueError(
            "source evidence index does not retain the selected recording/summary"
        )
    return (
        recording,
        summary,
        metadata,
        {
            recording: digest,
            summary: hashlib.sha256(summary_raw).hexdigest(),
            metadata: hashlib.sha256(metadata_raw).hexdigest(),
            root / "evidence/evidence-index.json": hashlib.sha256(
                index_raw
            ).hexdigest(),
        },
    )


def dataset_document(output: Path, host: Path) -> dict[str, Any]:
    metadata, _ = captured_document(output / "source/bag/metadata.yaml")
    info = metadata["rosbag2_bagfile_information"]
    custom = info["custom_data"]
    if custom["capture_clock_policy"] != "ros-time-no-reset":
        raise ValueError("capture must declare its ROS time no-reset policy")
    runtime, _ = captured_document(output / "source/capture/runtime-manifest.json")
    summary, _ = captured_document(output / "source/capture/recording-summary.json")
    filename = info["relative_file_paths"][0]
    recording = output / "source/bag" / filename
    channels = []
    for item in info["topics_with_message_count"]:
        topic = item["topic_metadata"]
        if not topic["offered_qos_profiles"]:
            raise ValueError("capture must retain actual offered QoS")
        channels.append(
            {
                "topic": topic["name"],
                "type": topic["type"],
                "type_hash": topic["type_description_hash"],
                "qos_profile": "custom",
                "qos_profile_sha256": sha256(output / "source/bag/metadata.yaml"),
            }
        )
    stats = summary["statistics"]
    digest = sha256(recording)
    return {
        "schema_version": "dataset-manifest.v1",
        "dataset_id": "org.example.foundation.stock-capture",
        "version": "0.0.0+" + digest[:16],
        "artifact": {
            "uri": (host / "source/bag" / filename).as_uri(),
            "immutable_revision": digest,
            "sha256": digest,
            "size_bytes": recording.stat().st_size,
            "media_type": "application/x-mcap",
            "storage_id": "mcap",
        },
        "channels": channels,
        "time": {
            "basis": "ros_time",
            "start_ns": stats["message_start_time_ns"],
            "end_ns": stats["message_end_time_ns"],
            "clock_jumps": [],
            "qos_overrides_sha256": sha256(
                output / "source/capture/qos-overrides.yaml"
            ),
        },
        "source": "simulation",
        "provenance": {
            "producer": "rosbag2_recorder",
            "captured_at": custom["captured_at"],
            "scenario_sha256": sha256(output / "source/capture/scenario.yaml"),
            "runtime_manifest_sha256": sha256(
                output / "source/capture/runtime-manifest.json"
            ),
            "source_revisions": runtime["components"],
        },
        "governance": {
            "license": custom["dataset_license"],
            "data_classification": custom["data_classification"],
            "retention_class": custom["retention_class"],
        },
        "topic_remaps": [],
    }


def prepare(root: Path, output: Path, host: Path) -> None:
    _, recording, summary, metadata, topic, expected = source_capture(root)
    output.mkdir(mode=0o700)
    selected = {
        recording: Path("source/bag") / recording.name,
        metadata: Path("source/bag/metadata.yaml"),
        summary: Path("source/capture/recording-summary.json"),
        root / "scenario.yaml": Path("source/capture/scenario.yaml"),
        root / "runtime-manifest.json": Path("source/capture/runtime-manifest.json"),
        root / "evidence/evidence-index.json": Path(
            "source/capture/evidence-index.json"
        ),
        root / "results/qualification-statement.json": Path(
            "source/capture/qualification-statement.json"
        ),
        root / "configuration/capture/qos-overrides.yaml": Path(
            "source/capture/qos-overrides.yaml"
        ),
        root / "configuration/capture/mcap-writer.yaml": Path(
            "source/capture/mcap-writer.yaml"
        ),
    }
    for source, relative in selected.items():
        copy_input(source, output / relative)
        if source in expected and sha256(output / relative) != expected[source]:
            raise ValueError("retained capture differs from the validated source bytes")
    before = sha256(output / "source/bag" / recording.name)
    scan = scan_recording(output / "source/bag" / recording.name, topic)
    if sha256(output / "source/bag" / recording.name) != before:
        raise ValueError("selected recording changed during native decoding")
    retained_scenario, _ = captured_document(output / "source/capture/scenario.yaml")
    desired_playback_duration_sec = 3 * retained_scenario["timeouts"]["execution_sec"]
    rate = min(
        1.0,
        (scan["last_ns"] - scan["first_ns"]) / 1e9 / desired_playback_duration_sec,
    )
    replay_qos = output / "source/qos/qos-overrides.yaml"
    replay_qos.parent.mkdir()
    replay_qos.write_text(
        json.dumps(
            {
                topic: {
                    "reliability": "reliable",
                    "durability": "volatile",
                    "history": "keep_last",
                    "depth": 100,
                },
                "/clock": {
                    "reliability": "best_effort",
                    "durability": "volatile",
                    "history": "keep_last",
                    "depth": 100,
                },
            },
            sort_keys=True,
        )
        + "\n"
    )
    write_document(dataset_document(output, host), output / "dataset-manifest.json")
    replay = copy.deepcopy(retained_scenario)
    replay["scenario_id"] = "org.example.foundation.recorded-playback"
    replay["execution"].update(
        data_source="recording_playback",
        plant_backend="recorded_data",
        time_mode="playback_clocked",
    )
    replay["provider_requirements"] = {"capabilities": ["playback_probe_delivery"]}
    replay["time_policy"] = {
        key: value
        for key, value in replay["time_policy"].items()
        if key not in ("step_size_sec", "max_skipped_steps")
    }
    replay["time_policy"].update(
        playback_rate=rate,
        min_clock_hz=100,
        message_order="received",
        qos_overrides_sha256=sha256(replay_qos),
    )
    replay["dataset_manifest_sha256"] = sha256(output / "dataset-manifest.json")
    write_document(replay, output / "scenario.json", schema="acceptance-scenario.v1")
    summary_document, _ = captured_document(
        output / "source/capture/recording-summary.json"
    )
    start_offset = (
        scan["first_ns"] - summary_document["statistics"]["message_start_time_ns"]
    ) / 1e9
    if start_offset < 0:
        raise ValueError("selected UInt64 begins before the finalized capture interval")
    (output / "playback-inputs.json").write_text(
        json.dumps(
            {
                "topic": topic,
                "message_type": MESSAGE_TYPE,
                "rate": rate,
                "clock_hz": 200,
                "desired_playback_duration_sec": desired_playback_duration_sec,
                "start_offset_sec": start_offset,
                "selected_recording": recording.name,
                "native_scan": scan,
            },
            sort_keys=True,
        )
        + "\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-run-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--host-output", required=True, type=Path)
    args = parser.parse_args()
    try:
        prepare(args.source_run_dir, args.output, args.host_output)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"prepare playback inputs: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
