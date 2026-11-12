"""Published SDK supply policy is checked before any SDK package import."""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location(
    "sdk_policy", ROOT / "check-sdk-wheels.py"
)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)
COHORT = json.loads(POLICY.POLICY.read_bytes())["sdk_cohort"]["wheels"]


class SdkPolicyControls(unittest.TestCase):
    def test_caller_wheels_and_lock_cannot_replace_committed_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            for name in COHORT:
                (folder / name).write_bytes(b"caller bytes")
            (folder / "requirements.lock").write_text("caller-supplied-policy")
            with self.assertRaisesRegex(ValueError, "committed cohort"):
                POLICY.check(folder)

    def test_published_wheels_and_same_size_tamper(self):
        wheels = os.environ.get("NAV2_SDK_WHEELS")
        if not wheels:
            self.skipTest("exact published SDK wheel storage required")
        POLICY.check(Path(wheels))
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            for name in COHORT:
                shutil.copyfile(Path(wheels) / name, folder / name)
            altered = folder / next(iter(COHORT))
            with altered.open("r+b") as stream:
                first = stream.read(1)
                stream.seek(0)
                stream.write(bytes([first[0] ^ 1]))
            with self.assertRaisesRegex(ValueError, "committed cohort"):
                POLICY.check(folder)

    def test_symlink_is_not_an_admitted_stored_wheel(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            first = folder / next(iter(COHORT))
            outside = folder / "other"
            outside.write_bytes(b"candidate")
            first.symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "without symlinks"):
                POLICY.check(folder)

    def test_fifo_is_refused_in_bounded_process_before_sdk_imports(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            os.mkfifo(folder / next(iter(COHORT)), 0o600)
            result = subprocess.run(
                [sys.executable, "-I", str(ROOT / "check-sdk-wheels.py"), str(folder)],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("committed cohort policy", result.stderr)

    def test_oversized_regular_file_refuses_before_hashing(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            name = next(iter(COHORT))
            with (folder / name).open("wb") as stream:
                stream.truncate(COHORT[name]["size_bytes"] + 1)
            with self.assertRaisesRegex(ValueError, "committed cohort"):
                POLICY.check(folder)


if __name__ == "__main__":
    unittest.main()
