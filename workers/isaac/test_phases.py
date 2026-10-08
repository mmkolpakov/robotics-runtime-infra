"""Private marker boundary checks; no GPU/Kit qualification is simulated."""

from __future__ import annotations
import argparse
import importlib.util
import json
import tempfile
import hashlib
import subprocess
import sys
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "isaac_bootstrap", Path(__file__).with_name("native-observe.py")
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrivatePhaseTest(unittest.TestCase):
    def test_owner_bound_markers_and_atomic_facts(self):
        with tempfile.TemporaryDirectory(prefix="rr-isaac-markers-") as directory:
            args = argparse.Namespace(
                phase_directory=Path(directory), owner_id="owner", phase_token="a" * 36
            )
            self.assertFalse(MODULE.phase_marker(args, "start"))
            MODULE.phase_write(args, "ready.json", {"phase": "ready"})
            raw = json.loads((Path(directory) / "ready.json").read_text())
            self.assertEqual(raw["owner_id"], "owner")
            self.assertEqual(raw["phase_token"], "a" * 36)
            marker = Path(directory) / "start.json"
            marker.write_text(
                json.dumps(
                    {"owner_id": "foreign", "phase_token": "a" * 36, "action": "start"}
                )
            )
            with self.assertRaisesRegex(RuntimeError, "another episode"):
                MODULE.phase_marker(args, "start")
            marker.write_text(
                json.dumps(
                    {"owner_id": "owner", "phase_token": "a" * 36, "action": "start"}
                )
            )
            self.assertTrue(MODULE.phase_marker(args, "start"))
            marker.unlink()
            marker.symlink_to(Path(directory) / "ready.json")
            with self.assertRaisesRegex(RuntimeError, "regular file"):
                MODULE.phase_marker(args, "start")
            marker.unlink()
            marker.write_bytes(b"x" * 4097)
            with self.assertRaisesRegex(RuntimeError, "bounded"):
                MODULE.phase_marker(args, "start")
            self.assertFalse(list(Path(directory).glob(".*")))

    def test_invalid_phase_configuration_rejects_before_sdk_import(self):
        worker = Path(__file__).with_name("native-observe.py")
        scene = worker.with_name("fixture.usda")
        with tempfile.TemporaryDirectory(prefix="rr-isaac-config-") as directory:
            for timeout in ("0", "-1", "nan", "301"):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(worker),
                        "--scene",
                        str(scene),
                        "--expected-scene-sha256",
                        hashlib.sha256(scene.read_bytes()).hexdigest(),
                        "--phase-directory",
                        directory,
                        "--owner-id",
                        "owner",
                        "--phase-token",
                        "a" * 36,
                        "--phase-timeout-seconds",
                        timeout,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("private phase waits must be bounded", result.stderr)
                self.assertNotIn("ModuleNotFoundError", result.stderr)
                self.assertFalse(list(Path(directory).iterdir()))


if __name__ == "__main__":
    unittest.main()
