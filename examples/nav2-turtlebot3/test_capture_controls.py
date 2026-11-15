"""Current consumer source controls, without creating a ROS execution."""

import ast
import io
import json
import runpy
import types
import unittest
from pathlib import Path

from robotics_acceptance_harness.readiness import GraphSnapshot, wait_for_readiness

SOURCE = Path(__file__).with_name("workload.py")
TREE = ast.parse(SOURCE.read_text())


class CommandGuardControls(unittest.TestCase):
    def test_only_the_guarded_topic_reaches_the_bridge(self):
        recorder = runpy.run_path(str(SOURCE.with_name("record-topics.py")))
        twist = "geometry_msgs/msg/Twist"

        def endpoint(name):
            return types.SimpleNamespace(
                node_namespace="/", node_name=name, topic_type=twist
            )

        endpoints = {
            "/cmd_vel": [endpoint("cmd_vel_deadman")],
            "/cmd_vel_guarded": [endpoint("ros_gz_bridge")],
        }
        indexed = {
            "/cmd_vel": [endpoint("collision_monitor")],
            "/cmd_vel_guarded": [endpoint("cmd_vel_deadman")],
        }
        observer = types.SimpleNamespace(
            get_publishers_info_by_topic=indexed.__getitem__,
            get_subscriptions_info_by_topic=endpoints.__getitem__,
        )
        self.assertTrue(
            recorder["has_command_guard"](recorder["command_path"](observer))
        )
        endpoints["/cmd_vel"].append(endpoint("ros_gz_bridge"))
        self.assertFalse(
            recorder["has_command_guard"](recorder["command_path"](observer))
        )
        endpoints["/cmd_vel"].pop()
        indexed["/cmd_vel_guarded"].append(endpoint("foreign"))
        self.assertFalse(
            recorder["has_command_guard"](recorder["command_path"](observer))
        )

    def test_bridge_remap_is_scoped_to_the_stock_spawn_launch(self):
        path = SOURCE.with_name("native_simulation.launch.py")
        tree = ast.parse(path.read_text())
        groups = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "GroupAction"
        ]
        self.assertEqual(len(groups), 1)
        group = groups[0]
        self.assertEqual(
            {kw.arg: ast.literal_eval(kw.value) for kw in group.keywords},
            {"scoped": True},
        )
        remap, spawn = group.args[0].elts
        self.assertEqual(
            {kw.arg: ast.literal_eval(kw.value) for kw in remap.keywords},
            {"src": "cmd_vel", "dst": "cmd_vel_guarded"},
        )
        self.assertIn("launch/spawn_tb3.launch.py", ast.unparse(spawn))
        self.assertNotIn("bringup_launch.py", ast.unparse(group))
        for node in ast.walk(tree):
            if not (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name)
                and node.func.id == "Node"
            ):
                continue
            kwargs = {kw.arg: kw.value for kw in node.keywords}
            if ast.literal_eval(kwargs["name"]) != "cmd_vel_deadman":
                continue
            self.assertEqual(
                ast.literal_eval(kwargs["package"]), "nav2_velocity_smoother"
            )
            self.assertEqual(
                ast.literal_eval(kwargs["remappings"]),
                [("cmd_vel_smoothed", "cmd_vel_guarded")],
            )
            params = ast.literal_eval(kwargs["parameters"])[0]
            self.assertIs(params["autostart_node"], True)
            self.assertEqual(params["bond_heartbeat_period"], 0.0)
            self.assertEqual(params["velocity_timeout"], 0.5)
            self.assertEqual(params["max_velocity"], [0.46, 0.0, 1.9])
            break
        else:
            self.fail("the native launch does not include the command guard")


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
