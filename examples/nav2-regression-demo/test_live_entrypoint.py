"""The live entry point delegates without starting a native workload in this test."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

DEMO = Path(__file__).resolve().parent
SCRIPT = DEMO / "run-live.sh"
IMAGE = "registry.example/nav2@sha256:" + "a" * 64


class LiveEntrypoint(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nav2-live-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.requirements = self.root / "requirements with spaces.json"
        self.requirements.write_text("{}")
        self.output = self.root / "output with spaces"
        self.env = dict(os.environ, PATH=str(self.bin) + ":/usr/bin:/bin")
        self.env["NAV2_TEST_CALLS"] = str(self.calls)
        for name in ("node", "podman", "gh", "curl"):
            executable = self.bin / name
            executable.write_text(
                "#!/usr/bin/python3\n"
                "import json, os, sys\n"
                "with open(os.environ['NAV2_TEST_CALLS'], 'a') as log:\n"
                "    log.write(json.dumps([os.path.basename(sys.argv[0]), *sys.argv[1:]]) + '\\n')\n"
                "sys.exit(int(os.environ.get('NAV2_TEST_EXIT', '0')))\n"
            )
            executable.chmod(0o755)

    def invoke(self, *args):
        return subprocess.run(
            ["/usr/bin/bash", str(SCRIPT), *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def recorded(self):
        return (
            [json.loads(line) for line in self.calls.read_text().splitlines()]
            if self.calls.exists()
            else []
        )

    def arguments(self):
        return [
            "--image",
            IMAGE,
            "--requirements",
            str(self.requirements),
            "--python",
            sys.executable,
            "--output",
            str(self.output),
        ]

    def test_help_does_not_require_inputs_or_tools(self):
        result = self.invoke("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("evaluation-inputs.json", result.stdout)
        self.assertEqual(self.recorded(), [])

    def test_missing_or_mutable_image_never_dispatches(self):
        for args in ([], ["--image", "registry.example/nav2:latest"]):
            with self.subTest(args=args):
                self.assertEqual(self.invoke(*args).returncode, 2)
                self.assertEqual(self.recorded(), [])
                self.assertFalse(self.output.exists())

    def test_missing_input_and_existing_output_never_dispatch(self):
        args = self.arguments()
        self.requirements.unlink()
        self.assertEqual(self.invoke(*args).returncode, 2)
        self.requirements.write_text("{}")
        self.output.mkdir()
        self.assertEqual(self.invoke(*args).returncode, 2)
        self.assertEqual(self.recorded(), [])

    def test_relative_output_and_unknown_case_never_dispatch(self):
        self.assertEqual(
            self.invoke(*self.arguments(), "--output", "relative").returncode, 2
        )
        self.assertEqual(
            self.invoke(*self.arguments(), "--case", "other").returncode, 2
        )
        self.assertEqual(self.recorded(), [])

    def test_all_cases_dispatch_the_existing_owner_with_literal_paths(self):
        self.env["NAV2_DEMO_RELEASE_TAG"] = "must-not-be-downloaded"
        for mode in ("success", "cancel", "timeout", "server-failure"):
            with self.subTest(mode=mode):
                result = self.invoke(*self.arguments(), "--case", mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    self.recorded()[-1],
                    [
                        "node",
                        str(DEMO.parent / "nav2-turtlebot3/native-check.mjs"),
                        str(self.output),
                        str(DEMO.parent / "nav2-turtlebot3"),
                        IMAGE,
                        mode,
                        str(self.requirements),
                        sys.executable,
                    ],
                )
        self.assertEqual(len(self.recorded()), 4)
        self.assertFalse(self.output.exists())

    def test_owner_failure_is_propagated_without_retry(self):
        self.env["NAV2_TEST_EXIT"] = "23"
        self.assertEqual(self.invoke(*self.arguments()).returncode, 23)
        self.assertEqual(len(self.recorded()), 1)

    def test_pull_only_uses_the_explicit_digest_without_launch(self):
        result = self.invoke("--pull-only", "--image", IMAGE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded(), [["podman", "pull", "--", IMAGE]])
        self.assertFalse(self.output.exists())

    def test_local_image_id_cannot_be_pulled(self):
        self.assertEqual(
            self.invoke("--pull-only", "--image", "sha256:" + "a" * 64).returncode, 2
        )
        self.assertEqual(self.recorded(), [])


if __name__ == "__main__":
    unittest.main()
