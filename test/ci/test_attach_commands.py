"""Run resolved attach commands through the installed verifier's input boundary."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]


class AttachCommandTests(unittest.TestCase):
    def test_default_commands_reach_document_validation(self):
        for profile, service in (
            ("edge-attach", "edge-attach-observer"),
            ("hil", "hil-observer"),
            ("real-observation", "real-observation-observer"),
        ):
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as work:
                root = Path(work)
                compose = [
                    "docker",
                    "compose",
                    "-f",
                    "compose.yaml",
                    "-f",
                    "compose.edge-attach.yaml",
                ]
                if profile == "real-observation":
                    compose.extend(["-f", "compose.real-observation.yaml"])
                env = os.environ | {
                    "COMPOSE_DISABLE_ENV_FILE": "1",
                    "ROBOTICS_RUN_ID": "run-aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
                    "ROBOTICS_DOMAIN_ID": "primary",
                    "ROBOTICS_RUN_INPUT_DIR": str(root / "input"),
                    "ROBOTICS_RESULTS_DIR": str(root / "results"),
                }
                model = json.loads(
                    subprocess.check_output(
                        [*compose, "--profile", profile, "config", "--format", "json"],
                        cwd=ROOT,
                        env=env,
                        text=True,
                    )
                )
                config = model["services"][service]
                command = config["command"]
                self.assertEqual(command[:2], ["robotics-acceptance", "verify"])
                mounts = {volume["target"]: volume for volume in config["volumes"]}
                required = (
                    "--scenario",
                    "--runtime",
                    "--run-id",
                    "--domain-id",
                    "--run-context",
                    "--evidence-index",
                    "--otel-metrics",
                    "--measurement-complete",
                    "--output",
                    "--diagnostic-output",
                )
                for flag in required:
                    self.assertEqual(command.count(flag), 1)
                    self.assertTrue(command[command.index(flag) + 1])
                for flag in (
                    "--scenario",
                    "--run-context",
                    "--runtime",
                    "--evidence-index",
                    "--otel-metrics",
                ):
                    directory = str(
                        PurePosixPath(command[command.index(flag) + 1]).parent
                    )
                    self.assertTrue(mounts[directory]["read_only"])
                marker = command[command.index("--measurement-complete") + 1]
                self.assertEqual(str(PurePosixPath(marker).parent), "/results")
                self.assertFalse(mounts["/results"].get("read_only", False))
                # Only translate container paths to an isolated local filesystem;
                # execute the same arguments with the real installed CLI. An
                # invalid document must reach its structured diagnostic boundary,
                # rather than exiting from argparse for missing required flags.
                argv = [
                    str(root / arg.lstrip("/")) if arg.startswith("/") else arg
                    for arg in command[1:]
                ]
                scenario = root / "input/scenario.yaml"
                scenario.parent.mkdir()
                scenario.write_text("{}\n", encoding="utf-8")
                (root / "results").mkdir()
                result = subprocess.run(
                    [sys.executable, "-m", "robotics_acceptance_harness.cli", *argv],
                    cwd=root,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                diagnostic = json.loads(
                    (root / "results/diagnostic.json").read_text(encoding="utf-8")
                )
                self.assertEqual(diagnostic["command"], "verify")
                self.assertNotEqual(diagnostic["error_id"], "internal.error")
                self.assertIn("error: [", result.stderr)
                self.assertNotIn("the following arguments are required", result.stderr)
                self.assertFalse((root / "results/measurement-complete").exists())
                self.assertFalse((root / "results/acceptance-result.json").exists())


if __name__ == "__main__":
    unittest.main()
