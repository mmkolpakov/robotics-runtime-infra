"""Generated PX4 contexts only; every Git observation and image build is mocked."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
from contextlib import redirect_stderr
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE_ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "prepare_px4_image", Path(__file__).with_name("prepare-px4-image.py")
)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
SERVER_SHA = "7cd0a2995460983e82fe2cf0ef187aba852bb849168ce972a139680f3611c0d8"
HELPER = "examples/px4-x500/evaluator/src/px4_x500_evaluator/_px4_listener.py"


class ContextControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="px4-context-control-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "host/.tools/PX4-Autopilot"
        build = "build/px4_sitl_default"
        for name in (
            build + "/bin",
            build + "/etc",
            "Tools/simulation/gz/models",
            "Tools/simulation/gz/worlds",
        ):
            (self.source / name).mkdir(parents=True)
        for name in (
            build + "/bin/px4",
            build + "/etc/rcS",
            build + "/rootfs/gz_env.sh",
            "src/modules/simulation/gz_bridge/server.config",
            "LICENSE",
            build + "/src/modules/simulation/gz_plugins/example.so",
        ):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"non-executable stock-output fixture\n")
        (self.source / build / "bin/px4-listener").symlink_to("px4")
        for name in prepare.SUBMODULES:
            (self.source / name).mkdir(parents=True, exist_ok=True)
        for name in (
            HELPER,
            "examples/px4-x500/native_worker.py",
            "host/workers/px4/probe.py",
            "host/workers/legacy-finalization/export_retained.py",
            "docker/python/px4-native-sdk.lock",
        ):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE_ROOT / name, target)
        (self.root / "host/workers/px4/source-lock.json").write_text(
            '{"mavsdk":{"server_version":"4.0.3"}}\n'
        )
        (self.root / "host/workers/px4/README.md").write_text("legacy fixture\n")
        self.server = self.root / "server"
        self.server.write_bytes(b"non-executable old server fixture")
        self.old_sha = prepare.sha

    def git_observation(self, argv, cwd=None):
        if argv[:3] == ["git", "status", "--porcelain"]:
            return ""
        self.assertEqual(argv, ["git", "rev-parse", "HEAD"])
        if cwd == self.source:
            return prepare.COMMIT
        return prepare.SUBMODULES[str(Path(cwd).relative_to(self.source))]

    def fixture_sha(self, path):
        return SERVER_SHA if path == self.server else self.old_sha(path)

    def run_prepare(self, extra, *, git=None):
        argv = [
            "prepare-px4-image.py",
            "--source",
            str(self.source),
            "--deps-image",
            "sha256:" + "a" * 64,
            *extra,
        ]
        with patch.object(prepare, "ROOT", self.root), patch.object(sys, "argv", argv):
            with (
                patch.object(
                    prepare, "command", side_effect=git or self.git_observation
                ),
                patch.object(prepare, "sha", side_effect=self.fixture_sha),
                patch.object(prepare.subprocess, "run") as build,
            ):
                prepare.main()
                build.assert_called_once()
                return build.call_args.args[0]

    def manifest(self, context, name, base):
        rows = {}
        for line in (context / "metadata" / name).read_text().splitlines():
            digest, relative = line.split("  ", 1)
            self.assertEqual(
                hashlib.sha256((base / relative).read_bytes()).hexdigest(), digest
            )
            rows[relative] = digest
        return rows

    def test_native_context_has_only_selected_worker_sources_and_exact_shared_parser(
        self,
    ):
        argv = self.run_prepare(["--controller", "native-python"])
        context = self.root / "host/.tools/px4-image-native-context"
        self.assertEqual(
            argv[argv.index("-f") + 1],
            str(self.root / "docker/px4-sitl-native.Dockerfile"),
        )
        self.assertEqual(argv[argv.index("-t") + 1], "localhost/rr-px4-native:source")
        self.assertEqual(argv[-1], str(context))
        self.assertFalse((context / "mavsdk_server").exists())
        workers = context / "workers"
        self.assertEqual(
            {path.name for path in workers.iterdir()},
            {"native_worker.py", "_px4_listener.py", "probe.py", "opaque_export.py"},
        )
        self.assertEqual(
            (workers / "_px4_listener.py").read_bytes(),
            (SOURCE_ROOT / HELPER).read_bytes(),
        )
        self.assertEqual(
            (workers / "native_worker.py").read_bytes(),
            (SOURCE_ROOT / "examples/px4-x500/native_worker.py").read_bytes(),
        )
        self.assertEqual(
            (workers / "probe.py").read_bytes(),
            (SOURCE_ROOT / "host/workers/px4/probe.py").read_bytes(),
        )
        self.assertEqual(
            set(self.manifest(context, "workers.sha256", workers)),
            {path.name for path in workers.iterdir()},
        )
        self.manifest(context, "payload.sha256", context / "payload")
        self.manifest(context, "native-sdk.sha256", context)
        record = json.loads((context / "metadata/source.json").read_text())
        self.assertEqual(record["controller"], "native-python")
        self.assertEqual(
            record["native_sdk"]["lock_sha256"],
            self.old_sha(context / "native-sdk.lock"),
        )
        self.assertEqual(
            (context / "native-sdk.lock").read_bytes(),
            (SOURCE_ROOT / "docker/python/px4-native-sdk.lock").read_bytes(),
        )
        self.assertNotIn("worker_image_id", record)
        self.assertNotIn("mavsdk_server", record)

    def test_default_legacy_context_preserves_server_and_metadata(self):
        argv = self.run_prepare(["--mavsdk-server", str(self.server)])
        context = self.root / "host/.tools/px4-image-context"
        self.assertEqual(
            argv[argv.index("-f") + 1], str(self.root / "docker/px4-sitl.Dockerfile")
        )
        self.assertEqual(argv[argv.index("-t") + 1], "localhost/rr-c13-px4:source")
        self.assertEqual(
            (context / "mavsdk_server").read_bytes(), self.server.read_bytes()
        )
        self.assertTrue((context / "workers/source-lock.json").exists())
        self.assertFalse((context / "workers/native_worker.py").exists())
        self.assertFalse((context / "native-sdk.lock").exists())
        record = json.loads((context / "metadata/source.json").read_text())
        self.assertNotIn("controller", record)
        self.assertNotIn("native_sdk", record)
        self.manifest(context, "workers.sha256", context / "workers")
        self.assertTrue(
            (context / "payload/build/px4_sitl_default/bin/px4-listener").is_symlink()
        )

    def test_native_mode_rejects_legacy_server_before_context_creation(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.run_prepare(
                ["--controller", "native-python", "--mavsdk-server", str(self.server)]
            )
        self.assertFalse((self.root / "host/.tools/px4-image-native-context").exists())

    def test_default_legacy_mode_still_requires_server(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.run_prepare([])
        self.assertFalse((self.root / "host/.tools/px4-image-context").exists())

    def test_new_mode_does_not_relax_stock_source_identity(self):
        with self.assertRaisesRegex(ValueError, "exact clean stock source"):
            self.run_prepare(
                ["--controller", "native-python"],
                git=lambda *args, **kwargs: "wrong-commit",
            )
        self.assertFalse((self.root / "host/.tools/px4-image-native-context").exists())

    def test_existing_context_is_never_overwritten(self):
        context = self.root / "host/.tools/px4-image-native-context"
        context.mkdir()
        marker = context / "retained"
        marker.write_bytes(b"original")
        with self.assertRaises(FileExistsError):
            self.run_prepare(["--controller", "native-python"])
        self.assertEqual(marker.read_bytes(), b"original")
        self.assertEqual(list(context.iterdir()), [marker])

    def test_mutable_dependency_tag_refuses_without_build(self):
        with self.assertRaisesRegex(ValueError, "immutable dependency"):
            self.run_prepare(
                ["--controller", "native-python", "--deps-image", "example:latest"]
            )
        self.assertFalse((self.root / "host/.tools/px4-image-native-context").exists())


if __name__ == "__main__":
    unittest.main()
