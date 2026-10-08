"""Verify stock topic extraction through the installed public contracts loader."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "scripts/ci/foundation/lib.sh"
SCENARIO = ROOT / "examples/minimal-consumer/scenario.yaml"


class ConsumerConfigurationTests(unittest.TestCase):
    def configure(self, scenario: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; foundation_scenario_topics "$2" "$3"',
                "consumer-config",
                str(LIBRARY),
                sys.executable,
                str(scenario),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def temporary_scenario(self, value: dict) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "scenario.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_public_scenario_configures_one_topic_and_bounded_recording(self) -> None:
        from robotics_runtime_contracts import load_mapping, validate_document

        scenario = load_mapping(SCENARIO)
        validate_document(scenario)
        topic = next(
            item["name"]
            for item in scenario["expected_ros_graph"]["topics"]
            if item["type"] == "std_msgs/msg/UInt64"
        )
        self.assertIn(topic, scenario["evidence_policy"]["topics"])
        result = self.configure(SCENARIO)
        self.assertEqual(result.returncode, 0, result.stderr)
        configuration = json.loads(result.stdout)
        self.assertEqual(configuration["metrics_topic"], topic)
        selected = re.compile(configuration["record_regex"])
        self.assertTrue(selected.fullmatch(topic))
        self.assertTrue(selected.fullmatch("/clock"))
        self.assertFalse(selected.fullmatch(topic + "/unrequested"))

    def test_recording_regex_escapes_declared_names(self) -> None:
        topic = "/consumer/probe.+(raw)"
        path = self.temporary_scenario(
            {
                "expected_ros_graph": {
                    "topics": [{"name": topic, "type": "std_msgs/msg/UInt64"}]
                },
                "evidence_policy": {"topics": ["/clock", topic]},
            }
        )
        result = self.configure(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        configuration = json.loads(result.stdout)
        self.assertEqual(configuration["metrics_topic"], topic)
        selected = re.compile(configuration["record_regex"])
        self.assertTrue(selected.fullmatch(topic))
        self.assertFalse(selected.fullmatch("/consumer/probeZZraw"))

    def test_legacy_clock_only_scenario_retains_the_stock_probe(self) -> None:
        path = self.temporary_scenario({"evidence_policy": {"topics": ["/clock"]}})
        result = self.configure(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        configuration = json.loads(result.stdout)
        self.assertEqual(configuration["metrics_topic"], "/robotics/runtime_probe")
        self.assertEqual(configuration["record_regex"], "^(/clock)$")

    def test_probe_must_be_recorded_and_ambiguity_is_rejected(self) -> None:
        for topics, recordings in (
            ([{"name": "/probe", "type": "std_msgs/msg/UInt64"}], ["/clock"]),
            (
                [
                    {"name": "/first", "type": "std_msgs/msg/UInt64"},
                    {"name": "/second", "type": "std_msgs/msg/UInt64"},
                ],
                ["/first", "/second"],
            ),
        ):
            with self.subTest(topics=topics):
                path = self.temporary_scenario(
                    {
                        "expected_ros_graph": {"topics": topics},
                        "evidence_policy": {"topics": recordings},
                    }
                )
                result = self.configure(path)
                self.assertNotEqual(result.returncode, 0)

    def test_recording_topics_cannot_be_empty(self) -> None:
        path = self.temporary_scenario({"evidence_policy": {"topics": []}})
        self.assertNotEqual(self.configure(path).returncode, 0)


if __name__ == "__main__":
    unittest.main()
