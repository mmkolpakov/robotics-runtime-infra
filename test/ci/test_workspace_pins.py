"""Regression checks for immutable source and generated foundation inputs."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "workspace_pins", ROOT / "scripts/ci/foundation/sync-workspace-pins.py"
)
assert SPEC is not None and SPEC.loader is not None
pins = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pins)


class WorkspacePinsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.git("init", "--quiet")
        self.git("config", "core.autocrlf", "false")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("pyproject.toml", '[tool.uv.workspace]\nmembers = ["packages/*"]\n')
        lock = "version = 1\n"
        for directory, distribution in pins.PACKAGES.items():
            project = f'''[project]
name = "{distribution}"
version = "1.2.3"
dependencies = ["packaging>=24", "robotics-runtime-contracts>=1.2"]
[project.optional-dependencies]
mcap = ["mcap>=1.4,<2"]
[build-system]
requires = ["hatchling==1.29.0"]
'''
            self.write(f"packages/{directory}/pyproject.toml", project)
            lock += f'''[[package]]
name = "{distribution}"
version = "1.2.3"
source = {{ editable = "packages/{directory}" }}
'''
        self.write("uv.lock", lock)
        self.commit()
        self.revision = self.git("rev-parse", "HEAD").strip()
        (self.root / "config/trust").mkdir(parents=True)
        (self.root / "config/trust/identities.json").write_text(
            json.dumps({"core": {"repository": "mmkolpakov/robotics-runtime"}})
        )
        self.set_pin(self.revision)
        (self.root / "docker-bake.hcl").write_text(
            "# FOUNDATION_GENERATED_START\n# FOUNDATION_GENERATED_END\n", newline="\n"
        )

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.workspace), *args], text=True
        )

    def write(self, relative, text):
        path = self.workspace / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, newline="\n")

    def commit(self):
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "fixture")

    def set_pin(self, revision, release=None):
        pin = {
            "type": "git",
            "url": "https://github.com/mmkolpakov/robotics-runtime.git",
        }
        if release is not None:
            pin["release"] = release
        pin["version"] = revision
        (self.root / "foundation.repos").write_text(
            json.dumps({"repositories": {"robotics-runtime": pin}})
        )

    def release_outputs(self):
        with (
            patch.object(pins, "export_lock", return_value="packaging==26.3\n"),
            patch.object(pins, "export_build_lock", return_value="hatchling==1.29.0\n"),
        ):
            return pins.outputs(self.root, self.workspace)

    def test_rejects_a_branch_instead_of_a_commit(self):
        self.set_pin("main")
        with self.assertRaisesRegex(ValueError, "immutable full Git commit"):
            pins.workspace_pin(self.root)

    def test_rejects_an_imported_checkout_at_another_commit(self):
        self.write("README.md", "new revision\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "pinned revision"):
            pins.export_lock(
                self.workspace, self.revision, "robotics-runtime-contracts"
            )

    def test_rejects_modified_workspace_inputs_before_export(self):
        self.write("uv.lock", "version = 999\n")
        with self.assertRaises(subprocess.CalledProcessError):
            pins.export_lock(
                self.workspace, self.revision, "robotics-runtime-contracts"
            )

    def test_rejects_metadata_that_disagrees_with_committed_lock(self):
        path = self.workspace / "packages/contracts/pyproject.toml"
        path.write_text(
            path.read_text().replace('version = "1.2.3"', 'version = "9.9.9"')
        )
        self.commit()
        self.set_pin(self.git("rev-parse", "HEAD").strip())
        with self.assertRaisesRegex(ValueError, "lock disagrees"):
            pins.outputs(self.root, self.workspace)

    def test_check_reports_drift_without_overwriting_it(self):
        with (
            patch.object(pins, "export_lock", return_value="packaging==26.3\n"),
            patch.object(pins, "export_build_lock", return_value="hatchling==1.29.0\n"),
        ):
            pins.synchronize(self.root, self.workspace, check=False)
            path = self.root / "config/foundation-lock.json"
            path.write_text("{}\n", newline="\n")
            with self.assertRaisesRegex(ValueError, "stale foundation inputs"):
                pins.synchronize(self.root, self.workspace, check=True)
            self.assertEqual(path.read_text(), "{}\n")
            pins.synchronize(self.root, self.workspace, check=False)
            pins.synchronize(self.root, self.workspace, check=True)
        result = json.loads(path.read_text())
        self.assertEqual(result["workspace"]["revision"], self.revision)
        self.assertEqual(result["packages"]["contracts"]["version"], "1.2.3")

    def test_rejects_a_release_that_is_not_a_harness_tag(self):
        for release in ("main", "contracts-v1.2.3", "harness-v1.2", 7):
            self.set_pin(self.revision, release)
            with self.assertRaisesRegex(ValueError, "harness-vX.Y.Z"):
                pins.workspace_pin(self.root)

    def test_binds_a_release_pin_to_both_published_tags(self):
        self.git("tag", "harness-v1.2.3")
        self.git("tag", "contracts-v1.2.3")
        self.set_pin(self.revision, "harness-v1.2.3")
        docs = self.release_outputs()[self.root / "docs/foundation-compatibility.md"]
        self.assertIn("`harness-v1.2.3` and `contracts-v1.2.3`", docs)
        self.assertNotIn("development candidate", docs)

    def test_rejects_a_release_tag_at_another_commit(self):
        self.git("tag", "harness-v1.2.3")
        self.git("tag", "contracts-v1.2.3")
        self.write("README.md", "after the release\n")
        self.commit()
        self.set_pin(self.git("rev-parse", "HEAD").strip(), "harness-v1.2.3")
        with self.assertRaisesRegex(ValueError, "does not point to the pinned"):
            self.release_outputs()

    def test_rejects_a_harness_version_that_differs_from_its_tag(self):
        self.git("tag", "harness-v1.2.4")
        self.git("tag", "contracts-v1.2.3")
        self.set_pin(self.revision, "harness-v1.2.4")
        with self.assertRaisesRegex(ValueError, "harness version"):
            self.release_outputs()

    def test_rejects_contracts_that_differ_from_their_release_tag(self):
        self.git("tag", "contracts-v1.2.3")
        self.write("packages/contracts/schema.json", "{}\n")
        self.commit()
        revision = self.git("rev-parse", "HEAD").strip()
        self.git("tag", "harness-v1.2.3")
        self.set_pin(revision, "harness-v1.2.3")
        with self.assertRaisesRegex(ValueError, "contracts source differs"):
            self.release_outputs()

    def test_rejects_two_generated_blocks_before_any_write(self):
        path = self.root / "docker-bake.hcl"
        path.write_text(path.read_text() * 2)
        with self.assertRaisesRegex(ValueError, "exactly one generated"):
            pins.outputs(self.root, self.workspace)
        self.assertFalse((self.root / "config/foundation-lock.json").exists())


if __name__ == "__main__":
    unittest.main()
