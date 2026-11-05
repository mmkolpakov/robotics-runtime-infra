from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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


if __name__ == "__main__":
    unittest.main()
