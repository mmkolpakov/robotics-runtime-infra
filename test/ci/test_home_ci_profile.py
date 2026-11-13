from __future__ import annotations

import json
import re
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
PUBLICATION = {
    "release.yml",
    "host-release.yml",
    "release-image.yml",
    "publish-conformance-image.yml",
}


class HomeCiWorkflowTest(unittest.TestCase):
    def test_every_software_job_has_a_fixed_executor_and_early_guard(self) -> None:
        refs: set[str] = set()
        count = 0
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            if path.name in PUBLICATION:
                continue
            document = yaml.safe_load(path.read_text())
            for name, job in document["jobs"].items():
                runner = job.get("runs-on")
                if runner is None or (path.name == "docs.yml" and name == "deploy"):
                    continue
                if isinstance(runner, list):
                    self.assertIn(
                        (path.name, name),
                        {
                            ("hardware-qualification.yml", "qualify"),
                            ("rk3588-qualification.yml", "qualify"),
                        },
                    )
                    continue
                with self.subTest(workflow=path.name, job=name):
                    self.assertIn("[vars.ROBOTICS_CI_EXECUTOR || 'hosted']", runner)
                    matched = re.search(r"fromJSON\('([^']+)'\)", runner)
                    self.assertIsNotNone(matched)
                    assert matched is not None
                    mapping = json.loads(matched[1])
                    arch = "arm64" if mapping["hosted"].endswith("-arm") else "x64"
                    self.assertEqual(set(mapping), {"hosted", "home"})
                    self.assertEqual(
                        mapping["hosted"],
                        "ubuntu-24.04" + ("-arm" if arch == "arm64" else ""),
                    )
                    self.assertEqual(
                        mapping["home"],
                        ["self-hosted", "linux", arch, "robotics-ci-home"],
                    )
                    guard = job["steps"][0]
                    self.assertEqual(guard["id"], "ci-profile")
                    repository = (
                        "robotics-runtime"
                        if (ROOT / "packages/harness").is_dir()
                        else "robotics-runtime-infra"
                    )
                    self.assertRegex(
                        guard["uses"],
                        "^mmkolpakov/"
                        + repository
                        + r"/\.github/actions/ci-profile@[a-f0-9]{40}$",
                    )
                    self.assertEqual(guard["with"]["architecture"], arch)
                    self.assertEqual(
                        guard["with"]["runner-environment"], "${{ runner.environment }}"
                    )
                    if any(
                        job.get("permissions", {}).get(key) == "write"
                        for key in ("id-token", "attestations")
                    ):
                        self.assertEqual(guard["with"]["trust"], "github-provenance")
                    refs.add(guard["uses"].split("@", 1)[1])
                    count += 1
        self.assertGreater(count, 0)
        self.assertEqual(len(refs), 1)
        revision = refs.pop()
        for name in ("action.yml", "check.cjs"):
            path = ".github/actions/ci-profile/" + name
            pinned = subprocess.check_output(
                ["git", "show", revision + ":" + path], cwd=ROOT
            )
            self.assertEqual(pinned, (ROOT / path).read_bytes())


if __name__ == "__main__":
    unittest.main()
