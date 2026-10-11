"""Portable synthetic capture controls; no simulator/renderer execution is claimed."""

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import patch

from host.producers import webots_native as producer
from workers.webots.common import model_inputs

ROOT = Path(__file__).resolve().parents[4]
ASSETS = ROOT / "workers/webots"


def write(path, value):
    path.write_text(json.dumps(value, allow_nan=False))
    return path


class WebotsV2Documents(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.archive = Path(self.temporary.name) / "archive"
        self.prepared = self.archive / "inputs"
        self.owner = "run-11111111-1111-4111-8111-111111111111"
        self.project = "rr-webots-" + "1" * 24
        self.issued = producer.prepare(
            ASSETS,
            self.prepared,
            owner_id=self.owner,
            project=self.project,
            worker_image="localhost/webots@sha256:" + "a" * 64,
        )
        self.capture = self.archive / "capture"
        self.capture.mkdir()
        for name in ("native.wbt", "NativeProbe.proto", "upstream.json"):
            shutil.copyfile(self.prepared / name, self.capture / name)
        scene = self.capture / "loaded-scene.wrl"
        scene.write_bytes(
            b"Group { children [] }\n"
        )  # synthetic JSON/byte binding control
        pins = json.loads((ASSETS / "upstream.json").read_bytes())["model_inputs"]
        self.controller = {
            "owner_id": self.owner,
            "status": "completed",
            "source_scope": "synthetic document control",
            "observed_world_path": "/opt/robotics/webots/worlds/native.wbt",
            "model_inputs": {
                key: {"sha256": p["sha256"], "size_bytes": p["size_bytes"]}
                for key, p in pins.items()
            },
            "asset_manifest_ref": producer.reference(self.capture / "upstream.json"),
            "loaded_scene_ref": producer.reference(scene, "text/plain"),
            "samples": [
                {
                    "request_ms": 16,
                    "result": 0,
                    "before_seconds": 0.0,
                    "after_seconds": 0.016,
                    "before_seconds_hex": (0.0).hex(),
                    "after_seconds_hex": (0.016).hex(),
                }
            ],
            "time": {
                "authority": "Webots Supervisor.getTime",
                "native_unit": "seconds",
                "representation": "float64",
                "epoch": self.owner + ":initial",
            },
            "camera": {"sampling_period_ms": 0},
            "initial_state": {"body_position_m": [0.0, 0.0, 1.0]},
            "last_native_state": {"body_position_m": [0.0, 0.0, 0.99]},
        }
        self.save_controller()
        self.worker = {
            "owner_id": self.owner,
            "status": "completed",
            "started_at": datetime.now(UTC).isoformat(),
            "finished_at": datetime.now(UTC).isoformat(),
            "controller_result_ref": producer.reference(
                self.capture / "controller-result.json"
            ),
        }
        write(self.capture / "worker-result.json", self.worker)
        self.cleanup = self.capture / "engine-cleanup.json"
        write(
            self.cleanup,
            {
                "owner_id": self.owner,
                "project": self.project,
                "observed_at": datetime.now(UTC).isoformat(),
                "released": True,
                "observation": {
                    "status": "complete",
                    "inventory": {
                        "containers": [],
                        "networks": [],
                        "volumes": {"Volumes": []},
                    },
                },
            },
        )

    def save_controller(self):
        write(self.capture / "controller-result.json", self.controller)
        if hasattr(self, "worker"):
            self.worker["controller_result_ref"] = producer.reference(
                self.capture / "controller-result.json"
            )
            write(self.capture / "worker-result.json", self.worker)

    def complete(self, cleanup=True):
        ref = self.issued["input_manifest"]
        return producer.complete(
            self.prepared,
            self.capture,
            self.cleanup if cleanup else None,
            input_manifest_sha256=ref["sha256"],
            input_manifest_size=ref["size_bytes"],
        )

    def assess(self, inputs):
        args = [str(Path(sys.executable).parent / "robotics-acceptance"), "evaluate"]
        for key in (
            "scenario",
            "runtime",
            "run_context",
            "evidence_index",
            "otel_metrics",
        ):
            args += ["--" + key.replace("_", "-"), inputs[key]]
        args += [
            "--run-id",
            self.owner,
            "--domain-id",
            "webots",
            "--window-start-ns",
            "0",
            "--window-end-ns",
            "1",
            "--output",
            str(self.archive / "assessment"),
        ]
        completed = subprocess.run(
            args, capture_output=True, text=True, timeout=40, check=False
        )
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["status"], "incomplete")
        self.assertTrue((self.archive / "assessment/junit.xml").is_file())
        return json.loads(
            (self.archive / "assessment/acceptance-result.json").read_bytes()
        )

    def test_public_installed_v2_path_is_incomplete_and_preserves_original_bytes(self):
        files = [*self.prepared.iterdir(), *self.capture.iterdir()]
        before = {p: p.read_bytes() for p in files}
        result = self.assess(self.complete())
        self.assertIn("$.observations.terminal", result["unevaluated"])
        self.assertIn("$.assertions", result["unevaluated"])
        self.assertEqual(before, {p: p.read_bytes() for p in files})
        observation = json.loads((self.archive / "observation.json").read_bytes())
        self.assertEqual(
            observation["observations"]["command"]["value"][0],
            {"native_api": "Supervisor.step", "request_ms": 16, "return": 0},
        )
        self.assertEqual(observation["observations"]["terminal"]["state"], "unobserved")
        self.assertNotIn("measurement_window", observation)

    def test_missing_scene_time_and_engine_inventory_remain_unobserved(self):
        (self.capture / "loaded-scene.wrl").unlink()
        self.controller.pop("time")
        self.save_controller()
        result = self.assess(self.complete(cleanup=False))
        for key in ("loaded-scene", "native-time", "cleanup"):
            self.assertIn("$.observations." + key, result["unevaluated"])

    def test_changed_world_and_proto_are_refused_even_with_recomputed_caller_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            copied = Path(tmp) / "worker"
            shutil.copytree(ASSETS, copied)
            for name, key in (
                ("worlds/native.wbt", "world"),
                ("protos/NativeProbe.proto", "proto"),
            ):
                original = (copied / name).read_bytes()
                (copied / name).write_bytes(
                    original + b'\nEXTERNPROTO "https://example.org/foreign.proto"\n'
                )
                pins = json.loads((copied / "upstream.json").read_bytes())[
                    "model_inputs"
                ]
                pins[key]["sha256"] = hashlib.sha256(
                    (copied / name).read_bytes()
                ).hexdigest()
                with self.assertRaisesRegex(ValueError, "bytes differ"):
                    model_inputs(
                        copied, pins["world"]["sha256"], pins["proto"]["sha256"]
                    )
                target = Path(tmp) / ("refused-" + key)
                refused = subprocess.run(
                    [
                        sys.executable,
                        str(copied / "launcher.py"),
                        "run",
                        "--output",
                        str(target),
                        "--owner-id",
                        self.owner,
                        "--expected-world-sha256",
                        pins["world"]["sha256"],
                        "--expected-proto-sha256",
                        pins["proto"]["sha256"],
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn("model input bytes differ", refused.stderr)
                self.assertFalse(target.exists())
                (copied / name).write_bytes(original)

    def test_captured_bytes_drifting_after_preflight_are_refused_before_issuance(self):
        real = producer.read_once

        def changed(path, limit):
            raw = real(path, limit)
            return raw + b"\n" if path.name == "native.wbt" else raw

        target = self.archive / "other-inputs"
        with patch.object(producer, "read_once", side_effect=changed):
            with self.assertRaisesRegex(
                ValueError, "captured model source bytes differ"
            ):
                producer.prepare(
                    ASSETS,
                    target,
                    owner_id=self.owner,
                    project=self.project,
                    worker_image="localhost/webots@sha256:" + "a" * 64,
                )
        self.assertFalse(target.exists())

    def test_rewritten_sidecar_cannot_replace_host_owned_identity(self):
        p = self.prepared / "pre-execution-inputs.json"
        p.chmod(0o600)
        value = json.loads(p.read_bytes())
        value["project"] = "foreign"
        write(p, value)
        with self.assertRaisesRegex(ValueError, "host-owned"):
            self.complete()

    def test_runtime_drift_and_foreign_native_run_refuse(self):
        p = self.prepared / "runtime.json"
        p.chmod(0o600)
        raw = p.read_bytes()
        p.write_bytes(raw + b" ")
        with self.assertRaisesRegex(ValueError, "pre-execution source"):
            self.complete()
        p.write_bytes(raw)
        self.controller["owner_id"] = "foreign"
        self.save_controller()
        with self.assertRaisesRegex(ValueError, "foreign run"):
            self.complete()

    def test_forged_released_or_foreign_project_inventory_refuses(self):
        value = json.loads(self.cleanup.read_bytes())
        value["observation"]["inventory"]["containers"] = [
            {"Id": "owned-still-present"}
        ]
        write(self.cleanup, value)
        with self.assertRaisesRegex(ValueError, "claimed cleanup"):
            self.complete()
        value["observation"]["inventory"]["containers"] = []
        value["project"] = "foreign"
        write(self.cleanup, value)
        with self.assertRaisesRegex(ValueError, "foreign run"):
            self.complete()

    def test_mutation_after_parse_cannot_recite_new_bytes_for_old_values(self):
        real = producer.native_observations

        def mutate(*args):
            value = real(*args)
            p = self.capture / "controller-result.json"
            p.write_bytes(p.read_bytes() + b" ")
            return value

        with patch.object(producer, "native_observations", side_effect=mutate):
            with self.assertRaises(ValueError):
                self.complete()
        self.assertFalse((self.archive / "evidence-index.json").exists())

    def test_substituted_asset_manifest_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            copied = Path(tmp) / "worker"
            shutil.copytree(ASSETS, copied)
            p = copied / "upstream.json"
            value = json.loads(p.read_bytes())
            value["model_inputs"]["world"]["sha256"] = "0" * 64
            write(p, value)
            with self.assertRaisesRegex(ValueError, "manifest bytes differ"):
                producer.prepare(
                    copied,
                    self.archive / "other",
                    owner_id=self.owner,
                    project=self.project,
                    worker_image="localhost/webots@sha256:" + "a" * 64,
                )

    def test_incomplete_inventory_is_unknown_and_complete_nonempty_is_known_false(self):
        value = json.loads(self.cleanup.read_bytes())
        value["released"] = False
        value["observation"]["status"] = "incomplete"
        value["observation"]["missing"] = ["project.containers"]
        value["observation"]["inventory"]["volumes"]["Volumes"] = None
        write(self.cleanup, value)
        row, time, rawref = producer.cleanup_observation(
            self.cleanup, self.owner, self.project
        )
        self.assertEqual(row["state"], "unobserved")
        self.assertIsNone(time)
        self.assertIsNotNone(rawref)
        value["observation"]["status"] = "complete"
        value["observation"]["missing"] = []
        value["observation"]["inventory"]["containers"] = [{"Id": "remaining"}]
        write(self.cleanup, value)
        row, _, _ = producer.cleanup_observation(self.cleanup, self.owner, self.project)
        self.assertEqual(row["state"], "measured")
        self.assertIs(row["value"]["resources_released"], False)
        value["observation"]["inventory"]["containers"] = []
        value["released"] = True
        write(self.cleanup, value)
        row, _, _ = producer.cleanup_observation(self.cleanup, self.owner, self.project)
        self.assertIs(row["value"]["resources_released"], True)

    def test_prepared_inputs_and_custody_manifest_are_readonly(self):
        self.assertTrue(
            all(p.stat().st_mode & 0o777 == 0o400 for p in self.prepared.iterdir())
        )


if __name__ == "__main__":
    unittest.main()
