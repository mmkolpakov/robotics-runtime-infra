"""Synthetic output controls; these documents are not native run evidence."""

import copy
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from robotics_acceptance_harness.result import write_contract_json, write_junit_xml
from robotics_runtime_contracts import ContractValidationError, validate_document


class PublicResultOutputControls(unittest.TestCase):
    def setUp(self):
        fixture = Path(__file__).parent / "evaluator/tests/fixtures/result-output.json"
        self.result = json.loads(fixture.read_bytes())

    def test_supported_profiles_preserve_failed_and_unevaluated_results(self):
        for profile in (
            "standard_isolated",
            "local_high_throughput",
            "secure_shared_memory",
        ):
            with (
                self.subTest(profile=profile),
                tempfile.TemporaryDirectory() as directory,
            ):
                result = copy.deepcopy(self.result)
                result["execution"]["data_plane_profile"] = profile
                root = Path(directory)
                write_contract_json(result, root / "result.json", replace=False)
                write_junit_xml(result, root / "junit.xml")
                actual = json.loads((root / "result.json").read_bytes())
                validate_document(actual)
                self.assertEqual(actual, result)
                self.assertEqual(actual["status"], "failed")
                self.assertIn("$.observed_ros_graph", actual["unevaluated"])
                junit = ET.parse(root / "junit.xml")
                self.assertEqual(len(junit.findall(".//failure")), 1)
                self.assertGreaterEqual(len(junit.findall(".//skipped")), 1)

    def test_unknown_profile_is_rejected_before_output(self):
        result = copy.deepcopy(self.result)
        result["execution"]["data_plane_profile"] = "fastdds-udp-private"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for writer, filename in (
                (write_contract_json, "result.json"),
                (write_junit_xml, "junit.xml"),
            ):
                with self.subTest(writer=writer.__name__):
                    path = root / filename
                    with self.assertRaises(ContractValidationError):
                        writer(result, path)
                    self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
