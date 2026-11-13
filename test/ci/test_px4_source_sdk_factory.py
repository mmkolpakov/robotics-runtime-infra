from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "px4_source_factory", ROOT / "host/tools/prepare-px4-image.py"
)
assert SPEC is not None and SPEC.loader is not None
FACTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FACTORY)


class SourceInputs(unittest.TestCase):
    def test_real_source_lock_and_legacy_wheel_are_distinct(self):
        lock, _ = FACTORY.source_sdk_lock()
        self.assertEqual(
            lock["sdk"]["commit"], "2da0f3f85f0cd1ed12f981dcac17b647030186f0"
        )
        self.assertEqual(lock["origin"], "project-source-build")
        self.assertIn(
            "mavsdk==4.1.0", (ROOT / "docker/python/px4-native-sdk.lock").read_text()
        )
        self.assertEqual(len(lock["archives"]), 5)
        self.assertEqual(
            lock["archives"]["pymavlink"]["commit"], lock["mavlink_pymavlink_commit"]
        )

    def test_missing_apt_evidence_never_reaches_backend(self):
        lock, _ = FACTORY.source_sdk_lock()
        lock.pop("apt_closure", None)
        with patch.object(FACTORY.subprocess, "run") as backend:
            for target in ("worker", "native-sdk-source"):
                with (
                    self.subTest(target=target),
                    self.assertRaisesRegex(ValueError, "closed APT inputs"),
                ):
                    FACTORY.require_apt_closure(lock, target)
            backend.assert_not_called()
        for target in ("native-source-inputs", "native-source-runtime-inputs"):
            FACTORY.require_apt_closure(lock, target)

    def test_corrupt_cached_source_is_refused_without_download(self):
        lock, _ = FACTORY.source_sdk_lock()
        item = lock["archives"]["MAVLink"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "host/.tools/mavsdk-source-cache"
            cache.mkdir(parents=True)
            retained = cache / (item["sha256"] + ".tar.gz")
            retained.write_bytes(b"corrupt")
            with (
                patch.object(FACTORY, "ROOT", root),
                patch.object(FACTORY.subprocess, "run") as download,
            ):
                with self.assertRaisesRegex(
                    ValueError, "retained source archive differs"
                ):
                    FACTORY.source_archive(item)
                download.assert_not_called()

    def test_tag_and_clean_tree_are_checked_with_stock_git(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "host/.tools/sdk"
            repo.mkdir(parents=True)

            def git(*args):
                return subprocess.check_output(
                    ["git", "-C", str(repo), *args], text=True
                ).strip()

            git("init", "--quiet")
            source = repo / "source.txt"
            source.write_text("source")
            git("add", "source.txt")
            git(
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.test",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--quiet",
                "-m",
                "fixture",
            )
            commit = git("rev-parse", "HEAD")
            git("tag", "v4.2.0")
            lock = {
                "sdk": {
                    "commit": commit,
                    "tree": git("rev-parse", "HEAD^{tree}"),
                    "tag": "v4.2.0",
                }
            }
            with patch.object(FACTORY, "ROOT", root):
                self.assertEqual(FACTORY.validate_sdk_source(repo, lock), repo)
                source.write_text("changed")
                with self.assertRaisesRegex(ValueError, "clean tagged"):
                    FACTORY.validate_sdk_source(repo, lock)
                with self.assertRaisesRegex(ValueError, "project tool directory"):
                    FACTORY.validate_sdk_source(root / "outside", lock)

    def test_source_build_uses_bounded_graceful_backend_and_closed_inputs(self):
        args = Namespace(
            deps_image="sha256:" + "a" * 64,
            build_target="native-sdk-source",
            tag="localhost/test:source",
        )
        closure = {"inventory_sha256": "b" * 64, "deb_manifest_sha256": "c" * 64}
        lock = {
            "platform": "linux/amd64",
            "ubuntu_snapshot": "20261113T000000Z",
            "apt_closure": {"build": closure},
        }
        with patch.object(FACTORY.subprocess, "run") as backend:
            FACTORY.build_image(
                args, Path("/owned/context"), Path("/owned/Dockerfile"), lock
            )
        argv = backend.call_args.args[0]
        self.assertEqual(
            argv[:4],
            ["/usr/bin/timeout", "--signal=TERM", "--kill-after=120s", "6600s"],
        )
        self.assertNotIn("timeout", backend.call_args.kwargs)
        self.assertIn("APT_BUILD_CLOSURE_SHA256=" + "b" * 64, argv)
        self.assertIn("--force-rm", argv)
        self.assertEqual(argv[argv.index("--target") + 1], "native-sdk-source")

    def test_source_options_do_not_change_old_controller_defaults(self):
        tool = ROOT / "host/tools/prepare-px4-image.py"
        for controller in ("legacy", "native-python"):
            result = subprocess.run(
                [
                    "python3",
                    str(tool),
                    "--controller",
                    controller,
                    "--deps-image",
                    "sha256:" + "a" * 64,
                    "--build-target",
                    "native-sdk-source",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(
                "source SDK inputs require native-python-source", result.stderr
            )


if __name__ == "__main__":
    unittest.main()
