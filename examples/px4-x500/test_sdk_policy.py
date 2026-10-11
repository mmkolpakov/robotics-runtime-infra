"""Committed policy, rather than caller storage/lock content, selects SDK bytes."""

import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location(
    "sdk_policy", ROOT / "check-sdk-wheels.py"
)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class SdkPolicyControls(unittest.TestCase):
    def test_caller_wheels_and_requirements_cannot_replace_committed_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            cohort = json.loads((ROOT / "input-pins.json").read_bytes())[
                "sdk_test_cohort"
            ]
            for name in cohort["wheels"]:
                (folder / name).write_bytes(b"caller-provided bytes")
            (folder / "requirements.lock").write_text("caller-supplied-policy")
            with self.assertRaisesRegex(ValueError, "committed cohort"):
                POLICY.check(folder)

    def test_exact_source_candidate_is_accepted_and_tamper_refused(self):
        wheels = os.environ.get("PX4_SDK_WHEELS")
        if not wheels:
            self.skipTest("exact built source SDK wheel storage required")
        POLICY.check(Path(wheels))
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            names = json.loads((ROOT / "input-pins.json").read_bytes())[
                "sdk_test_cohort"
            ]["wheels"]
            for name in names:
                shutil.copyfile(Path(wheels) / name, folder / name)
            altered = folder / next(iter(names))
            with altered.open("ab") as stream:
                stream.write(b"altered")
            with self.assertRaisesRegex(ValueError, "committed cohort"):
                POLICY.check(folder)


if __name__ == "__main__":
    unittest.main()
