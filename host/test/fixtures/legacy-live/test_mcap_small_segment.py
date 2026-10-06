"""Selected MCAP configuration checks and stock file-writer tests; no live publisher claim."""

import ast
import hashlib
import random
import tempfile
import unittest
from pathlib import Path

import yaml
from robotics_runtime_contracts import load_mapping

ROOT = Path(__file__).resolve().parents[4]
PROFILE = ROOT / "host/test/fixtures/legacy-live/mcap-writer-small-segment.yaml"
SPLIT_BYTES = 1048576
FINAL_CAP_BYTES = 2097152


class SelectedCaptureConfiguration(unittest.TestCase):
    def test_selected_profile_preserves_format_safety_and_global_throughput_defaults(
        self,
    ):
        global_options = dict(load_mapping(ROOT / "config/recording/mcap-writer.yaml"))
        selected = dict(load_mapping(PROFILE))
        self.assertEqual(global_options["chunkSize"], 4194304)
        self.assertEqual(selected.pop("chunkSize"), 262144)
        global_options.pop("chunkSize")
        self.assertEqual(selected, global_options)
        compose = yaml.safe_load(
            (ROOT / "host/test/fixtures/legacy-live/compose.yaml").read_bytes()
        )
        command = compose["services"]["recorder"]["command"]
        self.assertEqual(command[command.index("--max-bag-size") + 1], str(SPLIT_BYTES))
        self.assertEqual(command[command.index("--max-cache-size") + 1], "0")
        evidence = yaml.safe_load(
            (ROOT / "host/test/fixtures/legacy-live/evidence.yaml").read_bytes()
        )
        self.assertEqual(
            int(
                evidence["x-evidence"]["environment"]["EVIDENCE_MAX_SEGMENT_SIZE_BYTES"]
            ),
            FINAL_CAP_BYTES,
        )

    def test_both_executed_and_retained_configuration_copies_preserve_selected_bytes(
        self,
    ):
        source = ROOT / "host/workers/legacy-live/prepare-live.py"
        tree = ast.parse(source.read_text())
        function = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef)
            and node.name == "copy_capture_configurations"
        )
        namespace = {}
        # Execute only this inspected repository function, not the CLI or native workers.
        exec(  # noqa: S102
            compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec"),
            namespace,
        )
        before = PROFILE.read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            inputs, data = Path(directory) / "inputs", Path(directory) / "data"
            namespace["copy_capture_configurations"](ROOT, inputs, data)
            for copied in (
                inputs / "config/recording/mcap-writer.yaml",
                data / "configuration/capture/mcap-writer.yaml",
            ):
                self.assertEqual(copied.read_bytes(), before)
                self.assertEqual(
                    hashlib.sha256(copied.read_bytes()).hexdigest(),
                    hashlib.sha256(before).hexdigest(),
                )
        self.assertEqual(PROFILE.read_bytes(), before)

    def test_installed_deployment_declares_the_same_selected_source_asset(self):
        source = ROOT / "host/test/fixtures/installed-legacy/prepare.py"
        tree = ast.parse(source.read_text())
        deployment = next(
            ast.literal_eval(node.value)
            for node in tree.body
            if isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == "DEPLOYMENT"
                for target in node.targets
            )
        )
        relative = PROFILE.relative_to(ROOT).as_posix()
        self.assertIn(relative, deployment)
        self.assertNotIn("config/recording/mcap-writer.yaml", deployment)
        self.assertTrue((ROOT / relative).is_file())


class StockMcapFileWriter(unittest.TestCase):
    def writer(self, directory, topic, message_type):
        import rosbag2_py

        writer = rosbag2_py.SequentialWriter()
        writer.open(
            rosbag2_py.StorageOptions(
                uri=str(directory),
                storage_id="mcap",
                max_bagfile_size=SPLIT_BYTES,
                max_cache_size=0,
                storage_config_uri=str(PROFILE),
            ),
            rosbag2_py.ConverterOptions("", ""),
        )
        writer.create_topic(
            rosbag2_py.TopicMetadata(
                name=topic, type=message_type, serialization_format="cdr"
            )
        )
        return writer

    def test_tiny_message_index_growth_rotates_before_finalized_segments_exceed_cap(
        self,
    ):
        from mcap.reader import make_reader
        from rclpy.serialization import serialize_message
        from rosgraph_msgs.msg import Clock

        with tempfile.TemporaryDirectory() as directory:
            bag = Path(directory) / "clock"
            writer = self.writer(bag, "/clock", "rosgraph_msgs/msg/Clock")
            message = Clock()
            count = 150000
            try:
                for index in range(count):
                    message.clock.nanosec = index
                    writer.write("/clock", serialize_message(message), index)
            finally:
                writer.close()
            files = sorted(bag.glob("*.mcap"))
            self.assertGreaterEqual(
                len(files), 2, "stock size splitting must actually occur"
            )
            observed = 0
            compressed = False
            for path in files:
                self.assertLessEqual(path.stat().st_size, FINAL_CAP_BYTES)
                with path.open("rb") as stream:
                    reader = make_reader(stream, validate_crcs=True)
                    observed += sum(1 for _ in reader.iter_messages())
                    summary = reader.get_summary()
                    self.assertIsNotNone(summary)
                    self.assertTrue(summary.chunk_indexes)
                    self.assertTrue(summary.channels)
                    self.assertTrue(summary.schemas)
                    self.assertTrue(
                        all(
                            chunk.compression in ("zstd", "")
                            for chunk in summary.chunk_indexes
                        )
                    )
                    compressed |= any(
                        chunk.compression == "zstd" for chunk in summary.chunk_indexes
                    )
            self.assertEqual(observed, count)
            self.assertTrue(compressed)

    def test_arbitrary_oversized_message_remains_outside_the_guaranteed_profile(self):
        from rclpy.serialization import serialize_message
        from std_msgs.msg import UInt8MultiArray

        with tempfile.TemporaryDirectory() as directory:
            bag = Path(directory) / "oversized"
            writer = self.writer(bag, "/oversized", "std_msgs/msg/UInt8MultiArray")
            payload = random.Random(20261006).randbytes(FINAL_CAP_BYTES + 1048576)
            try:
                writer.write(
                    "/oversized",
                    serialize_message(UInt8MultiArray(data=list(payload))),
                    1,
                )
            finally:
                writer.close()
            self.assertGreater(
                max(path.stat().st_size for path in bag.glob("*.mcap")), FINAL_CAP_BYTES
            )


if __name__ == "__main__":
    unittest.main()
