"""Current consumer source controls, without creating a ROS execution."""

import ast
import io
import json
import types
import unittest
from pathlib import Path

from robotics_acceptance_harness.readiness import GraphSnapshot, wait_for_readiness

SOURCE = Path(__file__).with_name("workload.py")
TREE = ast.parse(SOURCE.read_text())


class CaptureControls(unittest.TestCase):
    def test_buffered_journal_and_compact_callback_keep_native_metadata(self):
        record = next(
            n
            for n in ast.walk(TREE)
            if isinstance(n, ast.FunctionDef) and n.name == "record"
        )
        # The closure's nonlocal counter is supplied by a small enclosing fixture.
        wrapper = ast.FunctionDef(
            name="factory",
            args=ast.arguments(
                posonlyargs=[], args=[], kwonlyargs=[], kw_defaults=[], defaults=[]
            ),
            body=[
                ast.Assign(
                    targets=[ast.Name(id="raw_bytes", ctx=ast.Store())],
                    value=ast.Constant(0),
                ),
                record,
                ast.Return(value=ast.Name(id="record", ctx=ast.Load())),
            ],
            decorator_list=[],
        )
        namespace = {
            "time": types.SimpleNamespace(
                time_ns=lambda: 123, monotonic_ns=lambda: 456
            ),
            "args": types.SimpleNamespace(run_id="run-source-control"),
            "json": json,
            "raw": io.StringIO(),
        }
        exec(  # noqa: S102 - exact trusted repository AST, no caller input
            compile(
                ast.fix_missing_locations(ast.Module(body=[wrapper], type_ignores=[])),
                str(SOURCE),
                "exec",
            ),
            namespace,
        )
        metadata = {
            "publication_sequence_number": 2**53 + 17,
            "publisher_gid": None,
            "reception_sequence_number": None,
        }
        namespace["factory"]()("odom", {"message_info": metadata})
        self.assertEqual(
            json.loads(namespace["raw"].getvalue())["message_info"], metadata
        )
        calls = [n for n in ast.walk(record) if isinstance(n, ast.Call)]
        self.assertFalse(
            any(
                isinstance(n.func, ast.Attribute) and n.func.attr == "flush"
                for n in calls
            )
        )
        callback = next(
            n
            for n in ast.walk(TREE)
            if isinstance(n, ast.FunctionDef) and n.name == "received"
        )
        self.assertFalse(
            any(
                isinstance(n, ast.Call)
                and isinstance(n.func, ast.Name)
                and n.func.id == "message_to_ordereddict"
                for n in ast.walk(callback)
            )
        )

    def test_actual_public_late_return_is_refused_by_same_caller_guard(self):
        expected = {"topics": [], "services": [], "actions": [], "lifecycle_nodes": []}
        ticks = iter([9_000_000_000, 11_000_000_000])
        observer = types.SimpleNamespace(snapshot=lambda: GraphSnapshot(11_000_000_000))
        result = wait_for_readiness(
            expected,
            observer,
            timeout_sec=1,
            stable_for_sec=0,
            now_ns=lambda: next(ticks),
        )
        self.assertEqual(result.first_ready_at_ns, 11_000_000_000)
        guard = next(
            n
            for n in ast.walk(TREE)
            if isinstance(n, ast.If)
            and any(
                isinstance(child, ast.Constant)
                and child.value
                == "published graph observation exceeded readiness deadline"
                for child in ast.walk(n)
            )
        )
        namespace = {
            "time": types.SimpleNamespace(monotonic=lambda: 11),
            "ready_deadline": 10,
        }
        with self.assertRaises(TimeoutError):
            exec(  # noqa: S102 - exact trusted repository AST, no caller input
                compile(
                    ast.fix_missing_locations(
                        ast.Module(body=[guard], type_ignores=[])
                    ),
                    str(SOURCE),
                    "exec",
                ),
                namespace,
            )

    def test_reliable_depth100_is_the_actual_subscription_configuration(self):
        calls = [
            n
            for n in ast.walk(TREE)
            if isinstance(n, ast.Call)
            and isinstance(n.func, ast.Attribute)
            and n.func.attr == "create_subscription"
        ]
        for topic in ("/odom", "/clock"):
            selected = next(
                call
                for call in calls
                if len(call.args) > 1
                and isinstance(call.args[1], ast.Constant)
                and call.args[1].value == topic
            )
            qos = selected.args[3]
            self.assertEqual(
                next(k.value.value for k in qos.keywords if k.arg == "depth"), 100
            )
            reliability = next(k.value for k in qos.keywords if k.arg == "reliability")
            self.assertEqual(reliability.attr, "RELIABLE")


class RecorderStorageControls(unittest.TestCase):
    def test_stock_compression_crc_and_closed_single_segment_size(self):
        import runpy
        import tempfile
        import time
        from mcap.writer import Writer, CompressionType

        recorder = runpy.run_path(str(SOURCE.with_name("record-topics.py")))
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "recording_0.mcap"
            with path.open("wb") as stream:
                writer = Writer(
                    stream, compression=CompressionType.ZSTD, chunk_size=256
                )
                writer.start(profile="ros2")
                schema = writer.register_schema(
                    name="std_msgs/msg/UInt64", encoding="ros2msg", data=b"uint64 data"
                )
                channel = writer.register_channel(
                    topic="/example", message_encoding="cdr", schema_id=schema
                )
                for number in range(20):
                    writer.add_message(
                        channel_id=channel,
                        log_time=number,
                        publish_time=number,
                        data=b"x" * 16,
                    )
                writer.finish()
            metadata = root / "metadata.yaml"
            metadata.write_text("stock fixture metadata")
            artifact = recorder["artifact_file"]
            member = artifact(path, root, time.monotonic() + 5)
            meta = artifact(metadata, root, time.monotonic() + 5)
            observed = recorder["storage_observation"](root, [member], meta, 20)
            self.assertEqual(observed["compression"], "zstd")
            self.assertEqual(
                observed["spool_peak_size_bytes"],
                path.stat().st_size + metadata.stat().st_size,
            )
            with self.assertRaises(ValueError):
                recorder["storage_observation"](root, [member, member], meta, 40)
            with self.assertRaises(ValueError):
                recorder["storage_observation"](root, [member], meta, 19)


if __name__ == "__main__":
    unittest.main()
