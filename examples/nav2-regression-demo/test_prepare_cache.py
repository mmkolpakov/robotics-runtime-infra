"""The prepare cache probe must not import evaluator code before admission."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).with_name("run-demo.sh")


class PrepareCache(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nav2-prepare-cache-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.demo = self.root / "nav2-regression-demo"
        self.demo.mkdir()
        shutil.copyfile(SOURCE, self.demo / "run-demo.sh")
        evaluator = self.root / "nav2-turtlebot3/evaluator"
        evaluator.mkdir(parents=True)
        (evaluator / "pyproject.toml").write_text(
            '[project]\nname = "nav2-turtlebot3-evaluator"\nversion = "0.3.0"\n'
        )
        self.venv = self.demo / ".venv"
        subprocess.run(
            [sys.executable, "-I", "-m", "venv", "--without-pip", str(self.venv)],
            check=True,
            capture_output=True,
            timeout=30,
        )
        self.python = self.venv / "bin/python"
        result = subprocess.run(
            [
                str(self.python),
                "-I",
                "-c",
                "import sysconfig; print(sysconfig.get_path('purelib'))",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.site = Path(result.stdout.strip())
        module = self.site / "nav2_turtlebot3_evaluator"
        module.mkdir()
        self.sentinel = self.root / "imported"
        (module / "__init__.py").write_text(
            "from pathlib import Path\n"
            f"Path({str(self.sentinel)!r}).write_text('imported before admission')\n"
            "raise RuntimeError('evaluator must not be imported by preparation')\n"
        )
        self.metadata = self.site / "nav2_turtlebot3_evaluator-0.3.0.dist-info"
        self.metadata.mkdir()
        self.set_version("0.3.0")
        tools = self.root / "tools"
        tools.mkdir()
        self.install = self.root / "installer-called"
        uv = tools / "uv"
        uv.write_text(f"#!/bin/sh\nprintf called > '{self.install}'\nexit 79\n")
        uv.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + ":/usr/bin:/bin")

    def set_version(self, value):
        (self.metadata / "METADATA").write_text(
            f"Metadata-Version: 2.1\nName: nav2-turtlebot3-evaluator\nVersion: {value}\n"
        )

    def prepare(self):
        return subprocess.run(
            [
                "/usr/bin/bash",
                str(self.demo / "run-demo.sh"),
                "--prepare-only",
                "--skip-release-env",
            ],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )

    def test_matching_metadata_reuses_without_importing_evaluator(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Reusing installed SDK cohort and evaluator", result.stdout)
        self.assertFalse(self.sentinel.exists())
        self.assertFalse(self.install.exists())

    def test_stale_metadata_requests_install_without_importing_evaluator(self):
        self.set_version("0.2.0")
        result = self.prepare()
        self.assertEqual(result.returncode, 79, result.stderr)
        self.assertTrue(self.install.exists())
        self.assertFalse(self.sentinel.exists())

    def test_missing_metadata_requests_install_without_importing_evaluator(self):
        shutil.rmtree(self.metadata)
        result = self.prepare()
        self.assertEqual(result.returncode, 79, result.stderr)
        self.assertTrue(self.install.exists())
        self.assertFalse(self.sentinel.exists())


if __name__ == "__main__":
    unittest.main()
