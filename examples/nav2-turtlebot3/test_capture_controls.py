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


if __name__ == "__main__":
    unittest.main()
