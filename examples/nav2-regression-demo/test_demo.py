"""Self-test: the demo demonstrates a failed robot qualification.

Runs the five-case assessment through the public SDK path with real Cosign
key-only admission and asserts the verdict taxonomy, the failed qualification
while the action SUCCEEDED, the evidence-refusal ERROR (not robot FAILED), the
synthetic qualification-verdict JUnit gate, and real (non-placeholder) provenance
digests. Requires the installed SDK cohort, the built evaluator wheel, and an
operator Cosign tool (ROBOTICS_COSIGN_PROFILE or cosign on PATH).
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

DEMO = Path(__file__).resolve().parent
sys.path.insert(0, str(DEMO))

import regression_driver as driver

EXPECTED = {
    "baseline": "passed",
    "criterion-sensitivity": "failed",
    "insufficient-observation": "incomplete",
    "evidence-refusal": "error",
    "missing-coverage": "incomplete",
}


class DemoQualification(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cosign_profile = os.environ.get("ROBOTICS_COSIGN_PROFILE")
        if not cls.cosign_profile and not shutil.which("cosign"):
            raise unittest.SkipTest("Cosign required for real evaluator admission")
        wheels = list(
            (DEMO / "dist").glob("nav2_turtlebot3_evaluator-*-py3-none-any.whl")
        )
        if not wheels:
            raise unittest.SkipTest("build the evaluator wheel first (./run-demo.sh)")
        cls.temporary = tempfile.TemporaryDirectory(prefix="nav2-demo-selftest-")
        cls.work = Path(cls.temporary.name)
        argv = [
            "--work-dir",
            str(cls.work),
            "--output",
            str(cls.work / "results.json"),
            "--report",
            str(cls.work / "report.txt"),
            "--wheel",
            str(wheels[0]),
        ]
        if cls.cosign_profile:
            argv += ["--cosign-profile", cls.cosign_profile]
        with contextlib.redirect_stdout(io.StringIO()):
            cls.exit_code = driver.main(argv)
        cls.results = json.loads((cls.work / "results.json").read_bytes())

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_demo_succeeds(self):
        self.assertEqual(self.exit_code, 0)

    def test_verdict_taxonomy(self):
        for label, verdict in EXPECTED.items():
            self.assertEqual(self.results["cases"][label]["verdict"], verdict, label)

    def test_failed_qualification_while_action_succeeded(self):
        sens = self.results["cases"]["criterion-sensitivity"]
        self.assertEqual(sens["action_status"], 4)  # NavigateToPose SUCCEEDED
        self.assertEqual(sens["verdict"], "failed")
        decisive = next(
            a
            for a in sens["assertions"]
            if a["assertion_id"].endswith(".action-success")
        )
        self.assertEqual(decisive["status"], "failed")
        self.assertGreater(sens["pose_error_m"], sens["max_final_pose_error_m"])

    def test_baseline_passes(self):
        base = self.results["cases"]["baseline"]
        self.assertEqual(base["verdict"], "passed")
        self.assertLessEqual(base["pose_error_m"], base["max_final_pose_error_m"])

    def test_insufficient_observation_unevaluated(self):
        case = self.results["cases"]["insufficient-observation"]
        self.assertEqual(case["verdict"], "incomplete")
        self.assertIn("$.observations.condition", case["unevaluated"])

    def test_evidence_refusal_is_error_not_robot_failed(self):
        case = self.results["cases"]["evidence-refusal"]
        self.assertEqual(case["verdict"], "error")
        self.assertFalse(case["evidence_valid"])
        self.assertNotEqual(case["verdict"], "failed")

    def test_missing_coverage_incomplete(self):
        case = self.results["cases"]["missing-coverage"]
        self.assertEqual(case["verdict"], "incomplete")
        self.assertTrue(
            any("action-success" in u for u in case["unevaluated"]), case["unevaluated"]
        )

    def test_qualification_junit_antiproxy(self):
        suite = ET.parse(self.work / "qualification-junit.xml").getroot()
        self.assertEqual(suite.get("failures"), "4")
        self.assertEqual(suite.get("tests"), "5")
        by_class = {c.get("classname"): c for c in suite.findall("testcase")}
        self.assertIsNone(by_class["nav2.qualification.baseline"].find("failure"))
        for label in EXPECTED:
            if label == "baseline":
                continue
            self.assertIsNotNone(
                by_class[f"nav2.qualification.{label}"].find("failure"), label
            )

    def test_provenance_real_digests(self):
        prov = self.results["provenance"]
        for key in ("evaluator_wheel_sha256", "evaluator_receipt_sha256"):
            self.assertRegex(prov[key], r"^[0-9a-f]{64}$")
            self.assertNotEqual(prov[key], "a" * 64)
            self.assertNotEqual(prov[key], "b" * 64)
        self.assertEqual(
            prov["sdk"]["robotics-acceptance-harness"]["version"], "0.23.1"
        )
        self.assertEqual(prov["sdk"]["robotics-runtime-contracts"]["version"], "0.22.0")

    def test_recording_timestamps_not_now(self):
        base = self.results["cases"]["baseline"]
        self.assertTrue(base["recording_started_at"].startswith("2026-10-08"))
        self.assertTrue(base["recording_finished_at"].startswith("2026-10-08"))

    def test_cdr_decoded(self):
        cdr = self.results["cases"]["baseline"]["cdr"]
        self.assertEqual(cdr["status_int8"], 4)
        self.assertEqual(cdr["status_name"], "SUCCEEDED")
        self.assertEqual(cdr["encapsulation"], "CDR_LE")


if __name__ == "__main__":
    unittest.main()
