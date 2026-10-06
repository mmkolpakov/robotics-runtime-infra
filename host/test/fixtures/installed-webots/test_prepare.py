"""Preparation regressions: exact deployment bytes and coordinated asset boundaries."""

import contextlib
import hashlib
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

FIXTURE = Path(__file__).resolve().parent
SOURCE = FIXTURE.parents[3]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, FIXTURE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prepare = load("installed_webots_prepare", "prepare.py")
worker = load("installed_webots_prepare_worker", "prepare-worker.py")


class Preparation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repository"
        self.repo.mkdir()
        shutil.copytree(FIXTURE, self.repo / "host/test/fixtures/installed-webots")
        self.source_bytes = (
            (SOURCE / "compose.webots.yaml")
            .read_bytes()
            .replace(b'      - "90"', b"      - '90' # finite native episode")
            .replace(
                b"volumes:\n  run-data:", b"volumes: # host-owned storage\n  run-data:"
            )
        )
        (self.repo / "compose.webots.yaml").write_bytes(self.source_bytes)
        self.podman_bytes = (SOURCE / "compose.webots.podman.yaml").read_bytes()
        (self.repo / "compose.webots.podman.yaml").write_bytes(self.podman_bytes)
        for name in (
            "config/foundation-lock.json",
            "config/qualification/native-provider-source.v1.schema.json",
            "docker/python/acceptance-observer.lock",
            "host/producers/provider_qualification.py",
        ):
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE / name, target)
        self.git("init", "--quiet")
        self.git("add", ".")
        self.git(
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "Record fixture inputs",
        )
        self.revision = self.git("rev-parse", "HEAD").decode().strip()
        self.core = self.root / "core.tgz"
        self.infra = self.root / "infra.tgz"
        self.core.write_bytes(b"independent core asset")
        self.infra.write_bytes(b"independent infrastructure asset")
        self.compose = self.root / "docker-compose"
        self.compose.write_bytes(b"pinned compose executable fixture")
        self.manifest = self.root / "source-identity.json"
        self.identity = {
            name: {
                "revision": self.revision,
                "sha256": hashlib.sha256(asset.read_bytes()).hexdigest(),
            }
            for name, asset in (("core", self.core), ("infra", self.infra))
        }
        self.manifest.write_text(json.dumps(self.identity))
        self.consumer = self.root / "consumer"

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.repo), *args], stderr=subprocess.PIPE
        )

    def prepare(self):
        arguments = [
            "prepare.py",
            "--repo",
            str(self.repo),
            "--consumer",
            str(self.consumer),
            "--core",
            str(self.core),
            "--infra",
            str(self.infra),
            "--source-identity",
            str(self.manifest),
            "--compose",
            str(self.compose),
            "--worker-image",
            "localhost/webots@sha256:" + "a" * 64,
            "--source-volume",
            "rr-webots-review-source",
            "--retained-volume",
            "rr-webots-review-retained",
        ]
        with (
            patch.object(sys, "argv", arguments),
            patch.object(
                prepare,
                "COMPOSE_SHA256",
                hashlib.sha256(self.compose.read_bytes()).hexdigest(),
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            prepare.main()

    def test_deployment_bytes_survive_layout_changes_and_overlay_is_selected(self):
        self.prepare()
        self.assertEqual(
            (self.consumer / "compose.worker.yaml").read_bytes(), self.source_bytes
        )
        self.assertEqual(
            (self.consumer / "compose.podman.yaml").read_bytes(), self.podman_bytes
        )
        overlay = json.loads((self.consumer / "compose.fixture.yaml").read_bytes())
        native = overlay["services"]["webots-native"]
        self.assertIn("--probe-reset", native["command"])
        self.assertEqual(
            overlay["volumes"]["retained"],
            {"external": True, "name": "rr-webots-review-retained"},
        )
        config = json.loads((self.consumer / "profiles/webots.yml").read_bytes())[0][
            "config"
        ]
        self.assertEqual(
            set(config["composeFiles"]),
            {
                "/app/compose.worker.yaml",
                "/app/compose.podman.yaml",
                "/app/compose.fixture.yaml",
            },
        )
        identity = json.loads((self.consumer / "identity.json").read_bytes())
        self.assertEqual(identity["assetSourceIdentity"], self.identity)
        self.assertEqual(identity["deployment"]["revision"], self.revision)
        self.assertEqual(identity["fixture"]["revision"], self.revision)
        self.assertNotEqual(
            overlay["services"]["foreign-fixture"]["labels"][
                "org.robotics.runtime.run-id"
            ],
            identity["hostOwner"],
        )
        self.assertEqual(identity["hostProject"], identity["hostOwner"])

    def test_tgz_drift_refused_before_consumer_is_written(self):
        self.core.write_bytes(self.core.read_bytes() + b"drift")
        with self.assertRaisesRegex(ValueError, "core TGZ checksum mismatch"):
            self.prepare()
        self.assertFalse(self.consumer.exists())

    def test_worker_exports_exact_producer_revision_and_current_foundation_lock(self):
        old_producer = (
            self.repo / "host/producers/provider_qualification.py"
        ).read_bytes()
        (self.repo / "host/producers/provider_qualification.py").write_bytes(
            b"# newer producer\n"
        )
        self.git("add", "host/producers/provider_qualification.py")
        self.git(
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "Advance producer",
        )
        current = self.git("rev-parse", "HEAD").decode().strip()
        output = self.root / "worker"
        with patch.object(
            sys,
            "argv",
            [
                "prepare-worker.py",
                "--repo",
                str(self.repo),
                "--output",
                str(output),
                "--producer-revision",
                self.revision,
            ],
        ):
            worker.main()
        self.assertEqual(
            (output / "assets/provider_qualification.py").read_bytes(), old_producer
        )
        self.assertEqual(
            (output / "assets/foundation-lock.json").read_bytes(),
            (self.repo / "config/foundation-lock.json").read_bytes(),
        )
        identity = json.loads((output / "source-identity.json").read_bytes())
        self.assertEqual(identity["producerSource"], self.revision)
        self.assertEqual(identity["fixtureSource"], current)
        for target, source in identity["exports"].items():
            self.assertEqual(
                hashlib.sha256((output / target).read_bytes()).hexdigest(),
                source["sha256"],
            )


if __name__ == "__main__":
    unittest.main()
