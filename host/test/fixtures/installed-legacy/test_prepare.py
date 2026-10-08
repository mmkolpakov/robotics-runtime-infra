"""Check installed engine selection and unchanged Compose admission bindings."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[4]
SPEC = importlib.util.spec_from_file_location(
    "installed_legacy_prepare", Path(__file__).with_name("prepare.py")
)
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)
COMPOSE = os.environ.get("ROBOTICS_COMPOSE")


class InstalledPreparation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="installed-ros-profile-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.assets = self.directory / "assets"
        self.assets.mkdir()
        identities = {}
        for component in ("core", "infra"):
            raw = component.encode()
            (self.assets / (component + ".tgz")).write_bytes(raw)
            identities[component] = {
                "revision": "c" * 40,
                "sha256": hashlib.sha256(raw).hexdigest(),
            }
        (self.assets / "source-identity.json").write_text(json.dumps(identities))
        self.lock = json.loads((ROOT / "config/foundation-lock.json").read_bytes())
        self.probe = {
            "foundationLock": self.lock,
            "versions": {
                row["distribution"]: row["version"]
                for row in self.lock["packages"].values()
            },
        }
        self.reference = "localhost/fixture@sha256:" + "b" * 64
        self.image = "sha256:" + "a" * 64
        self.digests = [self.reference]
        self.selected_engines = []

    def command(self, argv, **_options):
        if argv[:2] == ["git", "rev-parse"]:
            return "c" * 40 + "\n"
        if argv[:2] == ["git", "show"]:
            return (ROOT / argv[2].split(":", 1)[1]).read_bytes()
        self.selected_engines.append(argv[0])
        if argv[1:3] == ["image", "inspect"]:
            return json.dumps(
                [{"Id": self.image, "RepoDigests": self.digests}]
            ).encode()
        if argv[1] == "run":
            return json.dumps(self.probe).encode()
        raise AssertionError(argv)

    def prepare(self, engine=None, negative=False):
        consumer = self.directory / "consumer"
        args = [
            "prepare",
            "--repo",
            str(ROOT),
            "--consumer",
            str(consumer),
            "--assets",
            str(self.assets),
            "--deployment-revision",
            "c" * 40,
            "--compose",
            COMPOSE,
            "--simulation-image",
            self.reference,
            "--simulation-id",
            self.image,
            "--finalizer-image",
            self.reference,
            "--evidence-image",
            self.reference,
            "--source-volume",
            "rr-source-fixture",
            "--retained-volume",
            "rr-retained-fixture",
        ]
        if engine is not None:
            args += ["--engine", engine]
        if negative:
            args.append("--negative-lifecycle")
        with (
            patch.object(sys, "argv", args),
            patch.object(PREPARE.subprocess, "check_output", self.command),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            PREPARE.main()
        return json.loads((consumer / "identity.json").read_bytes())

    @unittest.skipUnless(
        COMPOSE, "ROBOTICS_COMPOSE selects the pinned local Compose binary"
    )
    def test_default_podman_and_explicit_docker_keep_exact_namespace_profiles(self):
        default = self.prepare()
        self.assertEqual(
            default["engineProfile"],
            {"engine": "podman", "expectedUsernsMode": "private"},
        )
        self.assertEqual(set(self.selected_engines), {"podman"})
        self.selected_engines.clear()
        self.directory = self.directory / "docker"
        self.directory.mkdir()
        docker = self.prepare("docker")
        self.assertEqual(
            docker["engineProfile"], {"engine": "docker", "expectedUsernsMode": ""}
        )
        self.assertEqual(set(self.selected_engines), {"docker"})
        self.assertEqual(docker["observedImages"]["simulation"]["imageId"], self.image)
        self.assertEqual(
            docker["observedImages"]["finalizer"]["reference"], self.reference
        )
        self.assertEqual(
            docker["observedImages"]["evidence"]["publicPython"], self.probe
        )
        self.assertIn(
            "host/test/fixtures/legacy-live/compose.podman.yaml", docker["deployment"]
        )
        env = {
            **os.environ,
            "ROBOTICS_RUN_ID": "run-fixture",
            "ROS_DOMAIN_ID": "181",
            "GZ_PARTITION": "fixture",
            "LEGACY_SIMULATION_IMAGE": self.image,
            "LEGACY_SOURCE_REVISION": "c" * 40,
            "LEGACY_COORDINATOR_IMAGE": self.image,
            "LEGACY_SOURCE_ROOT": "/deployment",
            "LEGACY_SHARED_VOLUME": "rr-source",
            "ROBOTICS_RETAINED_VOLUME": "rr-retained",
            "LEGACY_SIMULATION_REFERENCE": self.reference,
            "LEGACY_SIMULATION_DIGEST": "sha256:" + "b" * 64,
        }
        compose = (
            self.directory
            / "consumer/deployment/host/test/fixtures/legacy-live/compose.yaml"
        )
        model = json.loads(
            subprocess.run(
                [COMPOSE, "--file", str(compose), "config", "--format", "json"],
                env=env,
                check=True,
                capture_output=True,
            ).stdout
        )
        health = model["services"]["simulation"]["healthcheck"]
        self.assertEqual(health["start_interval"], "2s")
        self.assertEqual(health["interval"], "30s")
        self.assertEqual(health["timeout"], "6s")
        self.assertEqual(health["start_period"], "15s")
        self.assertEqual(health["retries"], 3)
        self.assertEqual(
            health["test"][-3:],
            [
                "/simulator/get_simulator_features",
                "simulation_interfaces/srv/GetSimulatorFeatures",
                "{}",
            ],
        )

    @unittest.skipUnless(
        COMPOSE, "ROBOTICS_COMPOSE selects the pinned local Compose binary"
    )
    def test_positive_consumer_retains_admission_helper_closure(self):
        identity = self.prepare("docker")
        deployment = self.directory / "consumer/deployment"
        for worker in (
            "compose.simulation-health.yaml",
            "host/workers/legacy/prepare-source.py",
            "host/workers/legacy-live/capture-provider.py",
            "host/workers/legacy-live/export-startup-failure.py",
            "host/workers/legacy-live/probe-diagnostic-export.py",
        ):
            with self.subTest(worker=worker):
                raw = (deployment / worker).read_bytes()
                self.assertEqual(raw, (ROOT / worker).read_bytes())
                self.assertEqual((deployment / worker).stat().st_mode & 0o777, 0o444)
                self.assertEqual(
                    identity["deployment"][worker],
                    {
                        "sha256": hashlib.sha256(raw).hexdigest(),
                        "size_bytes": len(raw),
                    },
                )

    @unittest.skipUnless(
        COMPOSE, "ROBOTICS_COMPOSE selects the pinned local Compose binary"
    )
    def test_negative_consumer_retains_exact_worker_and_installed_entrypoints(self):
        identity = self.prepare("docker", negative=True)
        consumer = self.directory / "consumer"
        worker = "host/workers/legacy-live/export-startup-failure.py"
        raw = (consumer / "deployment" / worker).read_bytes()
        self.assertEqual(raw, (ROOT / worker).read_bytes())
        self.assertEqual(
            identity["deployment"][worker],
            {"sha256": hashlib.sha256(raw).hexdigest(), "size_bytes": len(raw)},
        )
        for target, source in (
            ("app/negative-bootstrap.mjs", "negative-bootstrap.mjs"),
            ("negative-launch.mjs", "negative-launch.mjs"),
        ):
            self.assertEqual(
                (consumer / target).read_bytes(),
                (ROOT / "host/test/fixtures/installed-legacy" / source).read_bytes(),
            )

    @unittest.skipUnless(
        COMPOSE, "ROBOTICS_COMPOSE selects the pinned local Compose binary"
    )
    def test_foreign_helper_digest_refuses_before_consumer_creation(self):
        self.digests = ["localhost/foreign@sha256:" + "d" * 64]
        with self.assertRaisesRegex(ValueError, "observed local RepoDigest"):
            self.prepare("docker")
        self.assertFalse((self.directory / "consumer").exists())

    @unittest.skipUnless(
        COMPOSE, "ROBOTICS_COMPOSE selects the pinned local Compose binary"
    )
    def test_foreign_installed_python_cohort_refuses_before_consumer_creation(self):
        self.probe["versions"]["robotics-acceptance-harness"] = "0.19.1"
        with self.assertRaisesRegex(ValueError, "actual Python cohort differs"):
            self.prepare("docker")
        self.assertFalse((self.directory / "consumer").exists())

    @unittest.skipUnless(
        COMPOSE, "ROBOTICS_COMPOSE selects the pinned local Compose binary"
    )
    def test_changed_archive_refuses_before_engine_probe(self):
        (self.assets / "infra.tgz").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "TGZ checksum mismatch"):
            self.prepare("docker")
        self.assertEqual(self.selected_engines, [])
        self.assertFalse((self.directory / "consumer").exists())


class DiagnosticStateAccess(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="diagnostic-state-")
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name) / "state"
        self.state.mkdir(mode=0o700)
        spec = importlib.util.spec_from_file_location(
            "diagnostic_export_probe",
            ROOT / "host/workers/legacy-live/probe-diagnostic-export.py",
        )
        self.probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.probe)

    def inspect(self, uid=None):
        return self.probe.private_state_inventory(
            self.state, os.getuid() if uid is None else uid, os.getgid()
        )

    def test_absent_lazy_metric_keeps_actual_empty_private_directory_readable(self):
        result = self.inspect()
        self.assertTrue(result["stateDirectoryReadable"])
        self.assertEqual(result["presentStateFilesRead"], [])
        self.assertFalse((self.state / "spool-peak-size-bytes").exists())

    def test_stock_sink_empty_spool_preserves_inherited_setgid_directory_mode(self):
        self.state.rmdir()
        self.state.parent.chmod(0o2770)
        result = subprocess.run(
            [
                "bash",
                "-c",
                "umask 0022; source <(sed '/^for command/,$d' "
                "docker/evidence-sink/evidence-sink); "
                "update_max_state spool-peak-size-bytes 0",
            ],
            cwd=ROOT,
            env={**os.environ, "EVIDENCE_STATE_DIR": str(self.state)},
            check=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.state.stat().st_mode & 0o7777, 0o2755)
        self.assertFalse((self.state / "spool-peak-size-bytes").exists())
        observed = self.inspect()
        self.assertEqual(observed["stateMode"], "0o2755")
        self.assertTrue(observed["stateDirectoryReadable"])
        self.assertEqual(observed["presentStateFilesRead"], [])

    def test_every_present_private_state_file_is_read_without_changing_bytes(self):
        registrations = self.state / "registrations"
        registrations.mkdir(mode=0o700)
        files = {
            self.state / "spool-peak-size-bytes": b"7",
            registrations / "receipt.json": b'{"original": true}',
        }
        for path, raw in files.items():
            path.write_bytes(raw)
            path.chmod(0o600)
        result = self.inspect()
        self.assertCountEqual(
            result["presentStateFilesRead"],
            ["spool-peak-size-bytes", "registrations/receipt.json"],
        )
        self.assertEqual({path: path.read_bytes() for path in files}, files)

    def test_missing_foreign_or_nonprivate_directory_refuses(self):
        with self.assertRaisesRegex(ValueError, "ownership"):
            self.inspect(os.getuid() + 1)
        self.state.chmod(0o777)
        with self.assertRaisesRegex(ValueError, "foreign writes"):
            self.inspect()
        self.state.rmdir()
        with self.assertRaises(FileNotFoundError):
            self.inspect()

    def test_unreadable_present_file_refuses(self):
        path = self.state / "private"
        path.write_bytes(b"preserved")
        path.chmod(0)
        with self.assertRaises(PermissionError):
            self.inspect()
        self.assertEqual(path.stat().st_mode & 0o777, 0)

    def test_symlink_entry_or_root_refuses_without_following_it(self):
        target = self.state.parent / "outside"
        target.write_bytes(b"outside")
        link = self.state / "linked"
        link.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "regular file"):
            self.inspect()
        link.unlink()
        self.state.rmdir()
        self.state.symlink_to(self.state.parent, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "directory type"):
            self.inspect()


@unittest.skipUnless(
    COMPOSE, "ROBOTICS_COMPOSE selects the pinned local Compose binary"
)
class ComposeProfiles(unittest.TestCase):
    def test_public_simulator_profiles_share_native_probe_and_startup_policy(self):
        for overlay in ("compose.stepped.yaml", "compose.simulation-conformance.yaml"):
            with self.subTest(overlay=overlay):
                model = json.loads(
                    subprocess.check_output(
                        [
                            COMPOSE,
                            "--file",
                            str(ROOT / "compose.yaml"),
                            "--file",
                            str(ROOT / overlay),
                            "--profile",
                            "*",
                            "config",
                            "--format",
                            "json",
                        ],
                        env={
                            **os.environ,
                            "ROBOTICS_RUN_ID": "run-fixture",
                            "ROBOTICS_DOMAIN_ID": "0",
                            "ROBOTICS_SIMULATOR_SERVICE_NAMESPACE": "/custom",
                        },
                    )
                )
                health = model["services"]["simulation"]["healthcheck"]
                self.assertEqual(health["start_interval"], "2s")
                self.assertEqual(health["interval"], "30s")
                self.assertEqual(health["timeout"], "6s")
                self.assertEqual(health["start_period"], "20s")
                self.assertEqual(health["retries"], 3)
                self.assertEqual(
                    health["test"][-3:],
                    [
                        "/custom/get_simulator_features",
                        "simulation_interfaces/srv/GetSimulatorFeatures",
                        "{}",
                    ],
                )
                self.assertNotIn("simulation-health", model["services"])

    def test_engine_overlays_keep_native_namespace_and_socket_groups_explicit(self):
        self.assertEqual(
            hashlib.sha256(Path(COMPOSE).read_bytes()).hexdigest(),
            "f9ebc6ebdb19d769b793c245a736caaeb198c62587f13b25c660c13b4987f959",
        )
        env = {
            **os.environ,
            "ROBOTICS_RUN_ID": "run-fixture",
            "ROS_DOMAIN_ID": "181",
            "GZ_PARTITION": "fixture",
            "LEGACY_SIMULATION_IMAGE": "sha256:" + "a" * 64,
            "LEGACY_SIMULATION_REFERENCE": "localhost/fixture@sha256:" + "b" * 64,
            "LEGACY_SIMULATION_DIGEST": "sha256:" + "b" * 64,
            "LEGACY_COORDINATOR_IMAGE": "sha256:" + "c" * 64,
            "LEGACY_EVIDENCE_IMAGE": "sha256:" + "d" * 64,
            "LEGACY_SOURCE_ROOT": str(ROOT),
            "LEGACY_SOURCE_REVISION": "c" * 40,
            "LEGACY_SHARED_VOLUME": "rr-source",
            "ROBOTICS_RETAINED_VOLUME": "rr-retained",
            "C18_NODE_IMAGE": "localhost/node@sha256:" + "e" * 64,
            "C18_HOST_OWNER": "fixture-host",
            "C18_HOST_PROJECT": "fixture-project",
            "C18_SOURCE_VOLUME": "rr-source",
            "C18_RETAINED_VOLUME": "rr-retained",
            "C18_SOCKET": "/engine.sock",
            "C18_SOCKET_GID": "998",
            "C18_DEPLOYMENT_HOST_ROOT": str(ROOT),
        }
        groups = [
            (
                [
                    "host/test/fixtures/legacy-live/compose.yaml",
                    "host/test/fixtures/legacy-live/evidence.yaml",
                ],
                "host/test/fixtures/legacy-live/compose.podman.yaml",
                None,
            ),
            (
                ["host/test/fixtures/installed-legacy/compose.host.yaml"],
                "host/test/fixtures/installed-legacy/compose.host.podman.yaml",
                "host/test/fixtures/installed-legacy/compose.host.docker.yaml",
            ),
            (
                ["host/test/fixtures/installed-legacy/compose.post.yaml"],
                "host/test/fixtures/installed-legacy/compose.post.podman.yaml",
                "host/test/fixtures/installed-legacy/compose.post.docker.yaml",
            ),
        ]

        def model(files):
            args = [COMPOSE, "--project-name", "fixture-profile"]
            for name in files:
                args += ["--file", str(ROOT / name)]
            return json.loads(
                subprocess.check_output(
                    args + ["config", "--format", "json", "--no-path-resolution"],
                    env=env,
                )
            )

        for bases, overlay, docker_overlay in groups:
            with self.subTest(bases=bases):
                docker = model([*bases, docker_overlay] if docker_overlay else bases)
                podman = model([*bases, overlay])
                for name, service in docker["services"].items():
                    self.assertNotIn("userns_mode", service)
                    if name in ("installed-host", "installed-postprocessor"):
                        self.assertEqual(service.pop("group_add"), ["998"])
                    self.assertEqual(
                        podman["services"][name].pop("userns_mode"),
                        "keep-id:uid=1000,gid=1000",
                    )
                self.assertEqual(docker, podman)


if __name__ == "__main__":
    unittest.main()
