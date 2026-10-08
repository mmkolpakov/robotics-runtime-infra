"""Regressions for complete finalized stock-bag source selection and retention."""

from __future__ import annotations

import copy
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mcap.writer import CompressionType, Writer
from robotics_runtime_contracts.recordings import recording_summary_from_mcap

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "prepare_playback", ROOT / "scripts/ci/integration/prepare-playback-inputs.py"
)
assert SPEC and SPEC.loader
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)
RUN_ID = "run-00000000-0000-4000-8000-000000000001"
CUSTOM = {
    "run_id": RUN_ID,
    "captured_at": "2026-10-07T00:00:00Z",
    "record_timestamp_basis": "system_time",
    "capture_clock_policy": "system-time",
    "retention_class": "regression-30d",
    "dataset_license": "NOASSERTION",
    "data_classification": "public",
}
QOS = {
    "history": "unknown",
    "depth": 0,
    "reliability": "reliable",
    "durability": "volatile",
    "deadline": {"sec": 9223372036, "nsec": 854775807},
    "lifespan": {"sec": 9223372036, "nsec": 854775807},
    "liveliness": "automatic",
    "liveliness_lease_duration": {"sec": 9223372036, "nsec": 854775807},
    "avoid_ros_namespace_conventions": False,
}
TOPICS = [
    ("/clock", "rosgraph_msgs/msg/Clock", "RIHS01_" + "a" * 64),
    ("/example/sequence", "std_msgs/msg/UInt64", "RIHS01_" + "b" * 64),
]
try:
    from rclpy.serialization import serialize_message
    from rosgraph_msgs.msg import Clock
    from std_msgs.msg import UInt64
except ImportError:
    NATIVE_ROS = False
else:
    NATIVE_ROS = True


def payload(topic: str, value: int) -> bytes:
    if not NATIVE_ROS:
        return str(value).encode()
    if topic == "/clock":
        message = Clock()
        message.clock.sec = value
    else:
        message = UInt64()
        message.data = value
    return serialize_message(message)


def document(path: Path, data: dict) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, sort_keys=True) + "\n")
    return PREPARE.sha256(path)


class Capture:
    def __init__(
        self,
        root: Path,
        names: tuple[str, ...],
        *,
        mixed: dict | None = None,
        reset: bool = False,
    ):
        self.root = root
        self.bag = root / "bags/recording"
        self.names = names
        self.policy = {
            "max_segment_size_bytes": 2 * 1024**2,
            "max_segment_duration_sec": 30,
        }
        self.summaries = []
        for ordinal, name in enumerate(names):
            path = self.bag / name
            path.parent.mkdir(parents=True, exist_ok=True)
            identity = CUSTOM | (mixed if mixed and ordinal else {})
            with path.open("wb") as stream:
                writer = Writer(stream, compression=CompressionType.NONE)
                writer.start(profile="ros2")
                channels = []
                for topic, kind, _ in TOPICS:
                    schema = writer.register_schema(kind, "ros2msg", b"")
                    channels.append(writer.register_channel(topic, "cdr", schema))
                writer.add_metadata(
                    "rosbag2",
                    {
                        "serialized_metadata": json.dumps(
                            {
                                "ros_distro": identity.get("ros_distro", "jazzy"),
                                "custom_data": identity,
                                "message_count": 0,
                                "topics_with_message_count": [],
                                "relative_file_paths": [name],
                            }
                        )
                    },
                )
                for offset in (1, 2):
                    received = (ordinal * 4 + offset) * 1_000_000_000
                    clock = offset if reset and ordinal else ordinal * 4 + offset
                    for channel, (topic, _, _) in zip(channels, TOPICS, strict=True):
                        writer.add_message(
                            channel, received, payload(topic, clock), received
                        )
                writer.add_metadata(
                    "rosbag2",
                    {
                        "serialized_metadata": json.dumps(
                            {
                                "ros_distro": identity.get("ros_distro", "jazzy"),
                                "custom_data": identity,
                                "message_count": (ordinal + 1) * 4,
                                "relative_file_paths": [name],
                            }
                        )
                    },
                )
                writer.finish()
            summary = dict(
                recording_summary_from_mcap(path, max_raw_evidence_bytes=2 * 1024**2)
            )
            summary_path = root / f"evidence/summaries/{ordinal}.recording-summary.json"
            document(summary_path, summary)
            self.summaries.append((summary_path, summary))
        self.info = {
            "version": 9,
            "storage_identifier": "mcap",
            "relative_file_paths": list(names),
            "starting_time": {"nanoseconds_since_epoch": 1_000_000_000},
            "duration": {"nanoseconds": (len(names) * 4 - 3) * 1_000_000_000},
            "message_count": len(names) * 4,
            "topics_with_message_count": [
                {
                    "topic_metadata": {
                        "name": topic,
                        "type": kind,
                        "serialization_format": "cdr",
                        "type_description_hash": digest,
                        "offered_qos_profiles": [copy.deepcopy(QOS)],
                    },
                    "message_count": len(names) * 2,
                }
                for topic, kind, digest in TOPICS
            ],
            "files": [
                {
                    "path": name,
                    "starting_time": {
                        "nanoseconds_since_epoch": (i * 4 + 1) * 1_000_000_000
                    },
                    "duration": {"nanoseconds": 1_000_000_000},
                    "message_count": 4,
                }
                for i, name in enumerate(names)
            ],
            "custom_data": copy.deepcopy(CUSTOM),
            "ros_distro": "jazzy",
            "compression_format": "",
            "compression_mode": "",
        }
        self.index = json.loads(
            (ROOT / "test/qualification/fixtures/evidence-index.json").read_text()
        )
        self.index["run_id"] = RUN_ID
        self.index["artifacts"] = [
            {
                "artifact_id": f"artifact-{i}",
                "kind": "recording",
                "segment_index": i,
                "media_type": "application/mcap",
                "sha256": PREPARE.sha256(self.bag / name),
                "size_bytes": (self.bag / name).stat().st_size,
                "uri": (self.bag / name).as_uri(),
                "local_path": str(self.bag / name),
                "storage_state": "local",
                "retention_class": CUSTOM["retention_class"],
                "recording_summary": {
                    "uri": path.as_uri(),
                    "sha256": PREPARE.sha256(path),
                    "size_bytes": path.stat().st_size,
                },
            }
            for i, (name, (path, _)) in enumerate(
                zip(names, self.summaries, strict=True)
            )
        ]
        self.bind()

    def bind(self) -> None:
        self.subjects = {
            "capture/bags/recording/metadata.yaml": document(
                self.bag / "metadata.yaml", {"rosbag2_bagfile_information": self.info}
            ),
            "evidence-indexes/primary.json": document(
                self.root / "evidence/evidence-index.json", self.index
            ),
        }
        artifacts = []
        for i, (name, (path, _)) in enumerate(
            zip(self.names, self.summaries, strict=True)
        ):
            for kind, subject, source in (
                ("recording", f"recordings/{i}.mcap", self.bag / name),
                ("recording_summary", f"summaries/{i}.json", path),
            ):
                self.subjects[subject] = PREPARE.sha256(source)
                artifacts.append({"kind": kind, "subject_name": subject})
        self.statement = {"predicate": {"run_id": RUN_ID, "artifacts": artifacts}}

    def select(self):
        return PREPARE.finalized_recording(
            self.root,
            self.subjects,
            self.statement,
            {"evidence_policy": self.policy},
            {"ros": {"distribution": "jazzy"}},
        )

    def retain(self, output: Path) -> dict:
        members, metadata, _ = self.select()
        for recording, summary in members:
            PREPARE.copy_input(
                recording, output / "source/bag" / recording.relative_to(self.bag)
            )
            PREPARE.copy_input(
                summary, output / "source/capture/summaries" / summary.name
            )
        PREPARE.copy_input(metadata, output / "source/bag/metadata.yaml")
        document(
            output / "source/capture/runtime-manifest.json",
            json.loads(
                (ROOT / "test/qualification/fixtures/runtime-manifest.json").read_text()
            ),
        )
        document(output / "source/capture/scenario.yaml", {"retained": True})
        document(output / "source/capture/qos-overrides.yaml", {"retained": True})
        return PREPARE.dataset_document(output, output)


class CompleteBag(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="complete-bag-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def capture(
        self, names=("recording_9.mcap", "nested/recording_0.mcap"), **kwargs
    ) -> Capture:
        return Capture(self.root / "capture", names, **kwargs)

    def test_one_member_uses_the_same_canonical_model(self) -> None:
        dataset = self.capture(("recording_0.mcap",)).retain(self.root / "retained")
        self.assertEqual(dataset["schema_version"], "dataset-manifest.v2")
        self.assertEqual(len(dataset["bag"]["members"]), 1)
        self.assertEqual(dataset["bag"]["message_count"], 4)

    def test_metadata_order_nested_paths_and_seam_gaps(self) -> None:
        capture = self.capture()
        dataset = capture.retain(self.root / "retained")
        self.assertEqual(
            [m["relative_path"] for m in dataset["bag"]["members"]], list(capture.names)
        )
        self.assertEqual(dataset["bag"]["message_count"], 8)
        self.assertEqual(
            dataset["time"]["end_ns"] - dataset["time"]["start_ns"], 5_000_000_000
        )
        self.assertEqual(
            sum(f["duration"]["nanoseconds"] for f in capture.info["files"]),
            2_000_000_000,
        )

    def test_complete_retention_survives_source_removal(self) -> None:
        capture = self.capture()
        output = self.root / "retained"
        dataset = capture.retain(output)
        shutil.rmtree(capture.root)
        self.assertEqual(PREPARE.dataset_document(output, output), dataset)

    def test_initial_and_final_native_counts_can_evolve(self) -> None:
        self.assertEqual(len(self.capture().select()[0]), 2)

    def test_missing_member(self) -> None:
        capture = self.capture()
        (capture.bag / capture.names[-1]).unlink()
        with self.assertRaises(FileNotFoundError):
            capture.select()

    def test_surplus_member(self) -> None:
        capture = self.capture()
        (capture.bag / "surplus.mcap").write_bytes(b"surplus")
        with self.assertRaisesRegex(ValueError, "surplus"):
            capture.select()

    def test_missing_summary(self) -> None:
        capture = self.capture()
        capture.summaries[-1][0].unlink()
        with self.assertRaisesRegex(ValueError, "bijection"):
            capture.select()

    def test_duplicate_summary(self) -> None:
        capture = self.capture()
        shutil.copyfile(
            capture.summaries[0][0],
            capture.root / "evidence/summaries/duplicate.recording-summary.json",
        )
        with self.assertRaisesRegex(ValueError, "duplicate summaries"):
            capture.select()

    def test_duplicate_metadata_path(self) -> None:
        capture = self.capture()
        capture.info["relative_file_paths"][-1] = capture.names[0]
        capture.bind()
        with self.assertRaisesRegex(ValueError, "ordered unique"):
            capture.select()

    def test_unsafe_member_paths(self) -> None:
        capture = self.capture()
        for name in (
            "../outside.mcap",
            "/outside.mcap",
            "nested/../outside.mcap",
            "nested//recording_0.mcap",
        ):
            with self.subTest(name=name), self.assertRaises(ValueError):
                PREPARE.member_path(capture.bag, name)

    def test_duplicate_raw_bytes_are_not_distinct_members(self) -> None:
        capture = self.capture()
        shutil.copyfile(capture.bag / capture.names[0], capture.bag / capture.names[1])
        with self.assertRaisesRegex(ValueError, "bijection"):
            capture.select()

    def test_corrupt_raw_bytes_fail_original_source_binding(self) -> None:
        capture = self.capture()
        (capture.bag / capture.names[1]).write_bytes(b"corrupt closed MCAP")
        with self.assertRaisesRegex(ValueError, "bijection"):
            capture.select()

    def test_recording_size_limit_is_preserved(self) -> None:
        capture = self.capture()
        capture.policy["max_segment_size_bytes"] = 1
        with self.assertRaisesRegex(ValueError, "segment byte limit"):
            capture.select()

    def test_recording_duration_limit_is_preserved(self) -> None:
        capture = self.capture()
        capture.policy["max_segment_duration_sec"] = 0.5
        with self.assertRaisesRegex(ValueError, "segment duration"):
            capture.select()

    def test_mixed_capture_run(self) -> None:
        capture = self.capture(
            mixed={"run_id": "run-00000000-0000-4000-8000-000000000002"}
        )
        with self.assertRaisesRegex(ValueError, "MCAP capture"):
            capture.select()

    def test_mixed_governance_and_timestamp_basis(self) -> None:
        for field, value in (
            ("retention_class", "pull-request-7d"),
            ("data_classification", "internal"),
            ("record_timestamp_basis", "ros_time"),
            ("ros_distro", "rolling"),
        ):
            with self.subTest(field=field):
                temporary = tempfile.TemporaryDirectory()
                self.addCleanup(temporary.cleanup)
                capture = Capture(
                    Path(temporary.name),
                    ("recording_0.mcap", "recording_1.mcap"),
                    mixed={field: value},
                )
                with self.assertRaisesRegex(ValueError, "MCAP capture"):
                    capture.select()

    def test_index_raw_summary_size_ordinal_and_run_are_exact(self) -> None:
        capture = self.capture()
        original = copy.deepcopy(capture.index)
        mutations = [
            lambda d: d["artifacts"][0].update(size_bytes=1),
            lambda d: d["artifacts"][0]["recording_summary"].update(size_bytes=1),
            lambda d: d["artifacts"][1].update(segment_index=7),
            lambda d: d.update(run_id="run-00000000-0000-4000-8000-000000000002"),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                capture.index = copy.deepcopy(original)
                mutate(capture.index)
                capture.bind()
                with self.assertRaisesRegex(ValueError, "source evidence index"):
                    capture.select()

    def test_statement_missing_and_surplus_recording_refs(self) -> None:
        capture = self.capture()
        original = copy.deepcopy(capture.statement)
        capture.statement["predicate"]["artifacts"].pop(0)
        with self.assertRaisesRegex(ValueError, "source statement"):
            capture.select()
        capture.statement = copy.deepcopy(original)
        capture.subjects["extra"] = "a" * 64
        capture.statement["predicate"]["artifacts"].append(
            {"kind": "recording", "subject_name": "extra"}
        )
        with self.assertRaisesRegex(ValueError, "source statement"):
            capture.select()

    def test_native_type_hash_and_qos_pin_are_retained(self) -> None:
        capture = self.capture()
        output = self.root / "retained"
        dataset = capture.retain(output)
        self.assertEqual(
            [c["type_hash"] for c in dataset["channels"]], [v[2] for v in TOPICS]
        )
        self.assertTrue(
            all(
                c["qos_profile_sha256"] == dataset["bag"]["metadata"]["sha256"]
                for c in dataset["channels"]
            )
        )

    def test_copy_detects_source_change_during_retention(self) -> None:
        source, target = self.root / "source.bin", self.root / "target.bin"
        source.write_bytes(b"original")
        copyfile = shutil.copyfile

        def changed_source(a, b):
            result = copyfile(a, b)
            Path(a).write_bytes(b"changed")
            return result

        with (
            patch.object(PREPARE.shutil, "copyfile", changed_source),
            self.assertRaisesRegex(ValueError, "changed during retention"),
        ):
            PREPARE.copy_input(source, target)

    @unittest.skipUnless(NATIVE_ROS, "stock ROS is required")
    def test_native_directory_reader_scans_one_and_all_nested_members(self) -> None:
        for names in (
            ("recording_0.mcap",),
            ("recording_9.mcap", "nested/recording_0.mcap"),
        ):
            with self.subTest(names=names):
                temporary = tempfile.TemporaryDirectory()
                self.addCleanup(temporary.cleanup)
                capture = Capture(Path(temporary.name), names)
                scan = PREPARE.scan_recording(capture.bag, "/example/sequence")
                self.assertEqual(scan["total_message_count"], len(names) * 4)
                self.assertEqual(scan["clock_samples"], len(names) * 2)
                self.assertEqual(scan["message_count"], len(names) * 2)

    @unittest.skipUnless(NATIVE_ROS, "stock ROS is required")
    def test_native_scan_rejects_clock_reset_across_the_segment_seam(self) -> None:
        capture = self.capture(reset=True)
        with self.assertRaisesRegex(ValueError, "backward ROS clock"):
            PREPARE.scan_recording(capture.bag, "/example/sequence")

    def test_collector_keeps_all_input_and_new_observation_roles(self) -> None:
        from robotics_runtime_contracts.qualification import (
            inspect_qualification_artifacts,
        )

        capture = self.capture()
        output = self.root / "retained"
        dataset = capture.retain(output)
        document(output / "dataset-manifest.json", dataset)
        observed = Capture(self.root / "observation", ("observed.mcap",))
        observed_mcap = observed.bag / observed.names[0]
        observed_summary = observed.summaries[0][0]
        extras = (
            "configuration/rosbag2-version.txt",
            "configuration/playback-inputs.json",
            "logs/playback-gate.log",
            "logs/playback-probe.log",
            "playback-image.json",
            "probe-image.json",
            "compose-original.json",
            "compose.json",
        )
        for relative in extras:
            document(output / relative, {"fixture": relative})
        script = (ROOT / "scripts/ci/foundation/run-acceptance.sh").read_text()
        begin = script.index("append_playback_raw() {")
        end = script.index('for index in "${!mcap_summaries[@]}"', begin)
        jq = """jq() {
  "${FIXTURE_PYTHON}" -c 'import json,sys
assert sys.argv[1] == ".bag.members[].recording.sha256"
for member in json.load(open(sys.argv[2]))["bag"]["members"]:
 print(member["recording"]["sha256"])' "$2" "$3"
}
"""
        shell = (
            "set -Eeuo pipefail\n"
            + jq
            + """
run_dir="$1"
data_source=recording_playback
mcap_files=("$2")
qualification_inputs=(--evidence "recording:primary-0.mcap=$2" --recording-summary "primary-0=$3")
"""
            + script[begin:end]
            + """printf '%s\\0' "${qualification_inputs[@]}"
"""
        )
        import os
        import subprocess
        import sys

        process = subprocess.run(
            [
                "bash",
                "-c",
                shell,
                "collector",
                str(output),
                str(observed_mcap),
                str(observed_summary),
            ],
            env=os.environ | {"FIXTURE_PYTHON": sys.executable},
            capture_output=True,
            check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr.decode())
        values = process.stdout.decode().rstrip("\0").split("\0")
        specifications = []
        for option, value in zip(values[::2], values[1::2], strict=True):
            if option == "--recording-summary":
                subject, path = value.split("=", 1)
                specifications.append(
                    f"recording_summary:recording-summaries/{subject}.json={path}"
                )
            else:
                specifications.append(value)
        report = inspect_qualification_artifacts(specifications)
        self.assertFalse([d for d in report.diagnostics if d.check == "artifact.load"])
        source_digests = {
            member["recording"]["sha256"] for member in dataset["bag"]["members"]
        }
        summary_digests = {
            member["recording_summary"]["sha256"]
            for member in dataset["bag"]["members"]
        }
        loaded = report.artifacts
        self.assertEqual(
            {a.sha256 for a in loaded if a.kind == "recording"},
            source_digests | {PREPARE.sha256(observed_mcap)},
        )
        self.assertTrue(
            summary_digests.issubset(
                {a.sha256 for a in loaded if a.kind == "recording_summary"}
            )
        )
        self.assertTrue(
            summary_digests.issubset(
                {a.sha256 for a in loaded if a.kind == "other_evidence"}
            )
        )
        metadata = next(
            a for a in loaded if a.sha256 == dataset["bag"]["metadata"]["sha256"]
        )
        self.assertIsNotNone(metadata.native_metadata_bytes)
        reused = subprocess.run(
            [
                "bash",
                "-c",
                shell,
                "collector",
                str(output),
                str(capture.bag / capture.names[-1]),
                str(observed_summary),
            ],
            env=os.environ | {"FIXTURE_PYTHON": sys.executable},
            capture_output=True,
            check=False,
        )
        self.assertEqual(reused.returncode, 65)
        self.assertIn(b"cannot reuse its source", reused.stderr)


if __name__ == "__main__":
    unittest.main()
