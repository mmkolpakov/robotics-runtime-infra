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
        self.image = "localhost/webots@sha256:" + "a" * 64
        self.image_id = "sha256:" + "b" * 64
        self.inspection = [{"Id": self.image_id, "RepoDigests": [self.image]}]
        lock_bytes = (self.repo / "config/foundation-lock.json").read_bytes()
        self.foundation = json.loads(lock_bytes)
        self.public_python = {
            "installed": {
                package["distribution"]: package["version"]
                for package in self.foundation["packages"].values()
            },
            "foundationLock": self.foundation,
            "foundationLockSha256": hashlib.sha256(lock_bytes).hexdigest(),
        }
        self.podman_calls = []

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
            self.image,
            "--source-volume",
            "rr-webots-review-source",
            "--retained-volume",
            "rr-webots-review-retained",
        ]
        actual_check_output = subprocess.check_output

        def check_output(command, **kwargs):
            if command[0] != "podman":
                return actual_check_output(command, **kwargs)
            self.podman_calls.append(command)
            if command[1:3] == ["image", "inspect"]:
                return json.dumps(self.inspection).encode()
            if command[1] == "run":
                return json.dumps(self.public_python).encode()
            raise AssertionError("unexpected prerequisite command")

        with (
            patch.object(sys, "argv", arguments),
            patch.object(prepare.subprocess, "check_output", side_effect=check_output),
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
        self.assertEqual(identity["observedImageId"], self.image_id)
        self.assertEqual(identity["RepoDigests"], [self.image])
        self.assertEqual(identity["publicPythonProbe"], self.public_python)
        self.assertEqual(identity["foundationLock"]["document"], self.foundation)
        self.assertEqual(identity["foundationLock"]["revision"], self.revision)
        self.assertIn(self.image_id, self.podman_calls[1])
        self.assertNotIn(self.image, self.podman_calls[1])

    def test_tgz_drift_refused_before_consumer_is_written(self):
        self.core.write_bytes(self.core.read_bytes() + b"drift")
        with self.assertRaisesRegex(ValueError, "core TGZ checksum mismatch"):
            self.prepare()
        self.assertFalse(self.consumer.exists())

    def test_historical_worker_pair_refused_before_consumer_write(self):
        self.public_python["installed"]["robotics-runtime-contracts"] = "0.18.2"
        self.public_python["installed"]["robotics-acceptance-harness"] = "0.19.1"
        with self.assertRaisesRegex(ValueError, "installed public Python pair differs"):
            self.prepare()
        self.assertFalse(self.consumer.exists())

    def test_worker_full_source_lock_must_match_exact_git_lock(self):
        changed = json.loads(json.dumps(self.foundation))
        changed["workspace"]["revision"] = "0" * 40
        self.public_python["foundationLock"] = changed
        with self.assertRaisesRegex(ValueError, "embedded foundation lock differs"):
            self.prepare()
        self.assertFalse(self.consumer.exists())

    def test_worker_source_lock_bytes_must_match_exact_git_lock(self):
        self.public_python["foundationLockSha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "foundation lock bytes differ"):
            self.prepare()
        self.assertFalse(self.consumer.exists())

    def test_unobserved_worker_digest_refused_before_probe_or_consumer_write(self):
        self.inspection[0]["RepoDigests"] = []
        with self.assertRaisesRegex(ValueError, "observed immutable RepoDigest"):
            self.prepare()
        self.assertEqual(len(self.podman_calls), 1)
        self.assertFalse(self.consumer.exists())

    def test_dirty_fixture_refused_before_probe_or_consumer_write(self):
        target = self.repo / "host/test/fixtures/installed-webots/consumer.mjs"
        target.write_bytes(target.read_bytes() + b"// changed after source commit\\n")
        with self.assertRaisesRegex(ValueError, "differs from committed HEAD"):
            self.prepare()
        self.assertEqual(self.podman_calls, [])
        self.assertFalse(self.consumer.exists())

    def test_partial_consumer_refused_without_replacing_existing_bytes(self):
        self.consumer.mkdir()
        marker = self.consumer / "partial.json"
        marker.write_bytes(b"retained partial attempt")
        with self.assertRaisesRegex(FileExistsError, "fresh and nonexistent"):
            self.prepare()
        self.assertEqual(marker.read_bytes(), b"retained partial attempt")
        self.assertEqual(self.podman_calls, [])

    def test_existing_source_ancestor_refused_without_overwriting_sentinels(self):
        self.consumer = self.repo.parent
        sentinels = {
            name: ("existing ancestor " + name).encode()
            for name in (
                "package.json",
                "Dockerfile",
                "identity.json",
                "package-lock.json",
            )
        }
        for name, raw in sentinels.items():
            (self.consumer / name).write_bytes(raw)
        with self.assertRaisesRegex(FileExistsError, "fresh and nonexistent"):
            self.prepare()
        self.assertEqual(self.podman_calls, [])
        for name, raw in sentinels.items():
            self.assertEqual((self.consumer / name).read_bytes(), raw)

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
