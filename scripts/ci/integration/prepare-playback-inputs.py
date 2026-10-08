"""Prepare a complete finalized stock UInt64 bag for the existing live playback runner."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import shutil
import sys
from pathlib import Path, PurePosixPath
from typing import Any

from robotics_runtime_contracts import (
    loads_mapping,
    validate_bag_metadata,
    validate_bag_summaries,
    validate_document,
)
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


def scan_recording(path: Path, topic: str) -> dict[str, Any]:
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
    count = clocks = total = 0
    try:
        while reader.has_next():
            name, raw, timestamp = reader.read_next()
            total += 1
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
        "total_message_count": total,
    }


def source_capture(
    root: Path,
) -> tuple[dict[str, Any], list[tuple[Path, Path]], Path, str, dict[Path, str]]:
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
    members, metadata, raw_expected = finalized_recording(
        root, subjects, statement, scenario, runtime
    )
    expected.update(raw_expected)
    context, context_raw = captured_document(root / "acceptance-run.json")
    validate_document(context)
    if (
        subjects["acceptance-run.json"] != hashlib.sha256(context_raw).hexdigest()
        or context["run_id"] != statement["predicate"]["run_id"]
        or context["scenario_sha256"] != hashlib.sha256(scenario_raw).hexdigest()
    ):
        raise ValueError("capture run context differs from its signed source identity")
    expected[root / "acceptance-run.json"] = hashlib.sha256(context_raw).hexdigest()
    return scenario, members, metadata, topics[0], expected


def member_path(bag: Path, name: str) -> Path:
    relative = PurePosixPath(name)
    if (
        relative.is_absolute()
        or relative.as_posix() != name
        or any(part in ("", ".", "..") for part in name.split("/"))
        or "\\" in name
        or any(ord(char) < 32 for char in name)
        or not name.endswith(".mcap")
    ):
        raise ValueError("bag member path must be a confined relative MCAP path")
    path = bag / name
    path.resolve(strict=True).relative_to(bag.resolve(strict=True))
    if path.is_symlink() or not path.is_file():
        raise ValueError("bag members must be regular files")
    return path


def summary_sources(directory: Path) -> dict[str, tuple[Path, dict[str, Any], str]]:
    result = {}
    for path in sorted(directory.glob("*.recording-summary.json")):
        document, raw = captured_document(path)
        validate_document(document)
        digest = document["source_sha256"]
        if digest in result:
            raise ValueError("capture has duplicate summaries for one recording")
        result[digest] = (path, document, hashlib.sha256(raw).hexdigest())
    return result


def recording_identity(
    path: Path, custom: dict[str, Any], distro: str, limit: int
) -> None:
    from mcap.reader import SeekingReader

    if path.stat().st_size > limit:
        raise ValueError("source recording exceeds its declared segment byte limit")
    identities = []
    with path.open("rb") as stream:
        for entry in SeekingReader(
            stream, validate_crcs=True, record_size_limit=limit
        ).iter_metadata():
            if entry.name == "rosbag2":
                document = loads_mapping(entry.metadata["serialized_metadata"])
                identities.append(document)
    if not identities:
        raise ValueError("source recording lacks native rosbag2 capture identity")
    fields = (
        "run_id",
        "captured_at",
        "record_timestamp_basis",
        "capture_clock_policy",
        "retention_class",
        "dataset_license",
        "data_classification",
    )
    for document in identities:
        if document["ros_distro"] != distro or any(
            document["custom_data"].get(field) != custom.get(field) for field in fields
        ):
            raise ValueError(
                "MCAP capture run/governance/time identity differs from bag metadata"
            )


def signed_digests(
    statement: dict[str, Any], subjects: dict[str, str], kind: str
) -> set[str]:
    return {
        subjects[item["subject_name"]]
        for item in statement["predicate"]["artifacts"]
        if item["kind"] == kind
    }


def checked_member_index(
    index: dict[str, Any],
    members: list[tuple[Path, Path]],
    summaries: dict[str, Any],
    custom: dict[str, Any],
    policy: dict[str, Any],
) -> None:
    recorded = sorted(
        (item for item in index["artifacts"] if item["kind"] == "recording"),
        key=lambda item: item["segment_index"],
    )
    expected = []
    for ordinal, (recording, summary) in enumerate(members):
        digest = sha256(recording)
        stats = summaries[digest][1]["statistics"]
        if (
            stats["message_end_time_ns"] - stats["message_start_time_ns"]
            > policy["max_segment_duration_sec"] * 1e9
        ):
            raise ValueError("source recording exceeds its declared segment duration")
        expected.append(
            (
                ordinal,
                digest,
                recording.stat().st_size,
                sha256(summary),
                summary.stat().st_size,
                custom["retention_class"],
            )
        )
    actual = [
        (
            item["segment_index"],
            item["sha256"],
            item["size_bytes"],
            item["recording_summary"]["sha256"],
            item["recording_summary"]["size_bytes"],
            item["retention_class"],
        )
        for item in recorded
    ]
    if (
        actual != expected
        or index["run_id"] != custom["run_id"]
        or not index["finalized"]
    ):
        raise ValueError(
            "source evidence index differs from the complete finalized bag"
        )


def finalized_recording(
    root: Path,
    subjects: dict[str, str],
    statement: dict[str, Any],
    scenario: dict[str, Any],
    runtime: dict[str, Any],
) -> tuple[list[tuple[Path, Path]], Path, dict[Path, str]]:
    metadata_files = list((root / "bags").rglob("metadata.yaml"))
    if len(metadata_files) != 1:
        raise ValueError(
            "stock playback requires one complete native bag metadata file"
        )
    metadata = metadata_files[0]
    metadata.resolve(strict=True).relative_to(root.resolve(strict=True))
    document, metadata_raw = captured_document(metadata)
    info = document["rosbag2_bagfile_information"]
    names = info["relative_file_paths"]
    if (
        info["storage_identifier"] != "mcap"
        or not names
        or len(set(names)) != len(names)
    ):
        raise ValueError("selected bag metadata must bind ordered unique MCAP members")
    files = [member_path(metadata.parent, name) for name in names]
    if set(files) != set((root / "bags").rglob("*.mcap")):
        raise ValueError("capture contains missing or surplus MCAP members")
    summaries = summary_sources(root / "evidence/summaries")
    digests = [sha256(path) for path in files]
    if len(set(digests)) != len(files) or set(digests) != set(summaries):
        raise ValueError(
            "capture recordings and summaries must be a complete bijection"
        )
    members = [
        (path, summaries[digest][0])
        for path, digest in zip(files, digests, strict=True)
    ]
    if (
        signed_digests(statement, subjects, "recording") != set(digests)
        or signed_digests(statement, subjects, "recording_summary")
        != {v[2] for v in summaries.values()}
        or subjects["capture/bags/" + metadata.relative_to(root / "bags").as_posix()]
        != hashlib.sha256(metadata_raw).hexdigest()
        or info["custom_data"]["run_id"] != statement["predicate"]["run_id"]
    ):
        raise ValueError("complete bag differs from the completed source statement")
    index, index_raw = captured_document(root / "evidence/evidence-index.json")
    validate_document(index)
    if (
        subjects["evidence-indexes/primary.json"]
        != hashlib.sha256(index_raw).hexdigest()
    ):
        raise ValueError("capture evidence index differs from the source statement")
    policy = scenario["evidence_policy"]
    checked_member_index(index, members, summaries, info["custom_data"], policy)
    for recording in files:
        recording_identity(
            recording,
            info["custom_data"],
            runtime["ros"]["distribution"],
            policy["max_segment_size_bytes"],
        )
    expected = {path: sha256(path) for pair in members for path in pair}
    expected.update(
        {
            metadata: hashlib.sha256(metadata_raw).hexdigest(),
            root / "evidence/evidence-index.json": hashlib.sha256(
                index_raw
            ).hexdigest(),
        }
    )
    return members, metadata, expected


def capture_time_basis(custom: dict[str, Any]) -> str:
    policy = custom.get("capture_clock_policy")
    actual = custom.get("record_timestamp_basis")
    if policy == "ros-time-no-reset" and actual == "ros_time":
        return "ros_time"
    if policy == "system-time" and actual == "system_time":
        return "system_time"
    raise ValueError("qualified capture clock policy does not match its recorded mode")


def artifact_reference(path: Path, host_path: Path, media_type: str) -> dict[str, Any]:
    digest = sha256(path)
    return {
        "uri": host_path.as_uri(),
        "immutable_revision": digest,
        "sha256": digest,
        "size_bytes": path.stat().st_size,
        "media_type": media_type,
    }


def dataset_document(output: Path, host: Path) -> dict[str, Any]:
    metadata_path = output / "source/bag/metadata.yaml"
    metadata, _ = captured_document(metadata_path)
    info = metadata["rosbag2_bagfile_information"]
    custom = info["custom_data"]
    runtime, _ = captured_document(output / "source/capture/runtime-manifest.json")
    summaries = summary_sources(output / "source/capture/summaries")
    members, documents = [], []
    for ordinal, filename in enumerate(info["relative_file_paths"]):
        recording = member_path(output / "source/bag", filename)
        summary, document, _ = summaries[sha256(recording)]
        members.append(
            {
                "segment_index": ordinal,
                "relative_path": filename,
                "recording": artifact_reference(
                    recording, host / "source/bag" / filename, "application/x-mcap"
                ),
                "recording_summary": artifact_reference(
                    summary, host / summary.relative_to(output), "application/json"
                ),
            }
        )
        documents.append(document)
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
                "message_count": item["message_count"],
                "qos_profile": "custom",
                "qos_profile_sha256": sha256(metadata_path),
            }
        )
    nonempty = [
        document["statistics"]
        for document in documents
        if document["statistics"]["message_count"]
    ]
    dataset = {
        "schema_version": "dataset-manifest.v2",
        "dataset_id": "org.example.foundation.stock-capture",
        "version": "0.0.0+" + sha256(metadata_path)[:16],
        "bag": {
            "storage_id": "mcap",
            "metadata": artifact_reference(
                metadata_path, host / "source/bag/metadata.yaml", "application/yaml"
            ),
            "members": members,
            "message_count": info["message_count"],
        },
        "channels": channels,
        "time": {
            "basis": capture_time_basis(custom),
            "start_ns": min(stats["message_start_time_ns"] for stats in nonempty),
            "end_ns": max(stats["message_end_time_ns"] for stats in nonempty),
            "clock_jumps": [],
            "qos_overrides_sha256": sha256(
                output / "source/capture/qos-overrides.yaml"
            ),
        },
        "source": "simulation",
        "provenance": {
            "producer": "rosbag2_recorder",
            "captured_at": custom["captured_at"],
            "capture_run_id": custom["run_id"],
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
    validate_document(dataset)
    validate_bag_summaries(dataset, documents)
    validate_bag_metadata(
        dataset, metadata, documents, expected_run_id=custom["run_id"]
    )
    return dataset


def prepare(root: Path, output: Path, host: Path) -> None:
    _, members, metadata, topic, expected = source_capture(root)
    output.mkdir(mode=0o700)
    selected = {
        metadata: Path("source/bag/metadata.yaml"),
        root / "acceptance-run.json": Path("source/capture/acceptance-run.json"),
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
    for recording, summary in members:
        selected[recording] = Path("source/bag") / recording.relative_to(
            metadata.parent
        )
        selected[summary] = Path("source/capture/summaries") / summary.name
    for source, relative in selected.items():
        copy_input(source, output / relative)
        if source in expected and sha256(output / relative) != expected[source]:
            raise ValueError("retained capture differs from the validated source bytes")
    before = {relative: sha256(output / relative) for relative in selected.values()}
    dataset = dataset_document(output, host)
    scan = scan_recording(output / "source/bag", topic)
    if any(sha256(output / relative) != digest for relative, digest in before.items()):
        raise ValueError("selected capture bytes changed during native decoding")
    counts = {
        channel["topic"]: channel["message_count"] for channel in dataset["channels"]
    }
    if (
        scan["total_message_count"] != dataset["bag"]["message_count"]
        or scan["message_count"] != counts[topic]
        or scan["clock_samples"] != counts["/clock"]
    ):
        raise ValueError("native directory scan differs from the complete bag counts")
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
    write_document(dataset, output / "dataset-manifest.json")
    replay = copy.deepcopy(retained_scenario)
    # The native rosbag2-generated Clock offers BEST_EFFORT, unlike the source bridge.
    for declared_topic in replay["expected_ros_graph"]["topics"]:
        if declared_topic["name"] == "/clock":
            declared_topic["qos_profile"] = "sensor_data"
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
    start_offset = (scan["first_ns"] - dataset["time"]["start_ns"]) / 1e9
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
                "selected_recordings": [
                    str(recording.relative_to(metadata.parent))
                    for recording, _ in members
                ],
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
