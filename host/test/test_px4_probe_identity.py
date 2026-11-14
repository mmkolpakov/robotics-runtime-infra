from __future__ import annotations

import hashlib
import tempfile
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch, Mock

import importlib.util

spec = importlib.util.spec_from_file_location(
    "px4_probe", Path(__file__).parents[1] / "workers/px4/probe.py"
)
assert spec and spec.loader
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ActorIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / "binary"
        self.binary.write_bytes(b"px4 executable")

    def process(self, pid, instance=0):
        root = self.root / str(pid)
        root.mkdir()
        (root / "exe").symlink_to(self.binary)
        (root / "stat").write_text(f"{pid} (px4) S " + "0 " * 18 + "12345 0")
        (root / "cmdline").write_bytes(b"px4\0-i\0" + str(instance).encode() + b"\0")
        return root

    def observe(self):
        actual = probe.os.readlink

        def selected(path):
            if Path(path).name == "exe":
                return "/opt/px4/build/px4_sitl_default/bin/px4"
            return actual(path)

        with patch.object(probe.os, "readlink", side_effect=selected):
            return probe.actor_identity("run-1", "a" * 64, 0, self.root)

    def test_actual_one_process_fields(self):
        self.process(21)
        result = self.observe()
        self.assertEqual(result["owner_id"], "run-1")
        self.assertEqual(result["container_id"], "a" * 64)
        self.assertTrue(result["captured_unix_ns"].isdigit())
        self.assertEqual(result["px4_process"]["pid"], 21)
        self.assertEqual(result["px4_process"]["start_ticks"], "12345")
        self.assertEqual(
            result["px4_process"]["executable_sha256"],
            hashlib.sha256(b"px4 executable").hexdigest(),
        )

    def test_missing_and_multiple_refused(self):
        with self.assertRaisesRegex(RuntimeError, "exactly one"):
            self.observe()
        self.process(21)
        self.process(22)
        with self.assertRaisesRegex(RuntimeError, "exactly one|multiple"):
            self.observe()

    def test_wrong_or_ambiguous_instance_refused(self):
        process = self.process(21, 2)
        with self.assertRaisesRegex(RuntimeError, "instance differs"):
            self.observe()
        (process / "cmdline").write_bytes(b"px4\0-i\00\0--instance\00\0")
        with self.assertRaisesRegex(RuntimeError, "explicit"):
            self.observe()

    def test_invalid_container_id_refused(self):
        with self.assertRaisesRegex(ValueError, "container ID"):
            probe.actor_identity("run-1", "bad", 0, self.root)


class ReadinessTest(unittest.TestCase):
    def setUp(self):
        self.now = 0.0
        self.waits = []
        self.node = Mock()
        self.args = types.SimpleNamespace(
            mode="ready", seconds=1.0, world="default", model="x500_0", owner_id="run-1"
        )
        names = [
            "boolean_pb2.Boolean",
            "empty_pb2.Empty",
            "scene_pb2.Scene",
            "pose_v_pb2.Pose_V",
            "world_control_pb2.WorldControl",
            "world_stats_pb2.WorldStatistics",
        ]
        modules = {"gz.transport": types.SimpleNamespace(Node=lambda: self.node)}
        for name in names:
            module, symbol = name.split(".")
            modules["gz.msgs." + module] = types.SimpleNamespace(
                **{symbol: type(symbol, (), {})}
            )
        modules["google.protobuf.json_format"] = types.SimpleNamespace(
            MessageToDict=lambda scene, **kwargs: {
                "model": [{"name": m.name} for m in scene.model]
            }
        )
        self.enterContext(patch.dict(sys.modules, modules))
        self.enterContext(
            patch.object(probe.time, "monotonic", side_effect=lambda: self.now)
        )
        event = Mock()
        event.wait.side_effect = self.wait
        self.enterContext(patch.object(probe.threading, "Event", return_value=event))
        self.enterContext(
            patch.object(
                probe,
                "Path",
                return_value=types.SimpleNamespace(
                    read_bytes=lambda: b"init", read_text=lambda: "catatonit\n"
                ),
            )
        )
        self.enterContext(
            patch.object(probe.os, "readlink", return_value="/usr/bin/catatonit")
        )

    def wait(self, seconds):
        self.waits.append(seconds)
        self.now += seconds

    def scene(self, *names):
        return types.SimpleNamespace(
            model=[types.SimpleNamespace(name=name) for name in names]
        )

    def test_service_then_model_startup_waits_for_one_exact_model(self):
        self.node.request.side_effect = [
            (False, None),
            (True, self.scene()),
            (True, self.scene("x500_0")),
        ]
        result = probe.run(self.args)
        self.assertTrue(result["ready"])
        self.assertEqual(result["owner_id"], "run-1")
        self.assertEqual(
            result["oci_init"]["sha256"], hashlib.sha256(b"init").hexdigest()
        )
        self.assertEqual(len(self.waits), 2)
        self.assertFalse(self.node.subscribe.called)
        for call in self.node.request.call_args_list:
            self.assertEqual(call.args[0], "/world/default/scene/info")
            self.assertLessEqual(call.args[-1], 1000)

    def test_request_timeout_uses_remaining_budget_and_never_accepts_late_scene(self):
        self.args.seconds = 0.02

        def late(*args):
            self.assertLessEqual(args[-1], 20)
            self.now += 0.021
            return True, self.scene("x500_0")

        self.node.request.side_effect = late
        with self.assertRaisesRegex(TimeoutError, "readiness deadline"):
            probe.run(self.args)
        self.assertEqual(self.node.request.call_count, 1)

    def test_absent_model_exhausts_only_its_readiness_budget(self):
        self.args.seconds = 0.12
        self.node.request.return_value = (True, self.scene("ground_plane"))
        with self.assertRaisesRegex(TimeoutError, "readiness deadline"):
            probe.run(self.args)
        self.assertAlmostEqual(self.now, 0.12)
        self.assertLessEqual(max(self.waits), 0.05)

    def test_duplicate_exact_models_and_malformed_scene_fail_without_wait(self):
        for scene, error in [
            (self.scene("x500_0", "x500_0"), RuntimeError),
            (object(), AttributeError),
        ]:
            self.node.reset_mock()
            self.node.request.return_value = (True, scene)
            with self.assertRaises(error):
                probe.run(self.args)
            self.assertEqual(self.node.request.call_count, 1)
            self.assertEqual(self.waits, [])

    def test_unreadable_init_identity_is_not_a_startup_wait(self):
        self.node.request.return_value = (True, self.scene("x500_0"))
        identity = types.SimpleNamespace(
            read_text=lambda: "catatonit",
            read_bytes=Mock(side_effect=OSError("identity unavailable")),
        )
        with patch.object(probe, "Path", return_value=identity):
            with self.assertRaisesRegex(OSError, "identity unavailable"):
                probe.run(self.args)
        self.assertEqual(self.node.request.call_count, 1)
        self.assertEqual(self.waits, [])

    def test_observe_does_not_inherit_readiness_waiting(self):
        self.args.mode = "observe"
        self.node.request.return_value = (False, None)
        with self.assertRaisesRegex(RuntimeError, "exactly one"):
            probe.run(self.args)
        self.assertEqual(self.node.request.call_count, 1)
        self.assertEqual(self.node.request.call_args.args[-1], 3000)
        self.assertEqual(self.waits, [])


class ProbeOutputTest(unittest.TestCase):
    def test_ready_budget_is_mode_specific_and_output_reserved_once(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "facts.json"
            args = [
                "probe",
                "--mode",
                "ready",
                "--seconds",
                "120",
                "--owner-id",
                "run-1",
                "--output",
                str(path),
            ]
            with (
                patch.object(sys, "argv", args),
                patch.object(probe, "run", return_value={"ready": True}) as run,
            ):
                self.assertEqual(probe.main(), 0)
                self.assertEqual(run.call_args.args[0].seconds, 120)
            original = path.read_bytes()
            with patch.object(sys, "argv", args), patch.object(probe, "run") as run:
                with self.assertRaises(FileExistsError):
                    probe.main()
                run.assert_not_called()
            self.assertEqual(path.read_bytes(), original)
            for mode, seconds in [
                ("ready", "301"),
                ("observe", "61"),
                ("last-state", "61"),
            ]:
                refused = args.copy()
                refused[refused.index("--mode") + 1] = mode
                refused[refused.index("--seconds") + 1] = seconds
                with patch.object(sys, "argv", refused), self.assertRaises(SystemExit):
                    probe.main()


if __name__ == "__main__":
    unittest.main()
