"""Validate retained simulation observations before producing provider bindings."""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from robotics_runtime_contracts import validate_document

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/foundation/create-simulation-provider.py"
SPEC = importlib.util.spec_from_file_location("simulation_provider", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
producer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(producer)


class SimulationProviderTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.args = argparse.Namespace(
            **{
                name: self.root / f"{name}.json"
                for name in (
                    "scenario",
                    "run_context",
                    "profile",
                    "configuration",
                    "observation",
                    "world",
                    "output",
                )
            },
            subject_digest="sha256:" + "a" * 64,
        )
        self.scenario, scenario_raw = producer.read_mapping(
            ROOT / "test/acceptance/stepped-smoke.yaml"
        )
        # This source is YAML even though the temporary filename ends in .json.
        self.args.scenario = self.root / "scenario.yaml"
        self.args.scenario.write_bytes(scenario_raw)
        self.run, _ = producer.read_mapping(
            ROOT / "test/qualification/fixtures/acceptance-run.json"
        )
        self.run["scenario_id"] = self.scenario["scenario_id"]
        self.run["scenario_sha256"] = producer.digest(scenario_raw)
        self.save("run_context", self.run)
        self.profile, _ = producer.read_mapping(
            ROOT / "config/qualification/simulation-interfaces.json"
        )
        self.save("profile", self.profile)
        self.world = (
            ROOT / "ros_ws/src/robotics_runtime_infra/worlds/empty.sdf"
        ).read_bytes()
        self.args.world.write_bytes(self.world)
        self.configuration = {
            "implementation_id": "gz_sim",
            "version": "8.11.0",
            "service_namespace": "/simulator",
            "world_sha256": producer.digest(self.world),
            "world_size_bytes": len(self.world),
        }
        self.save("configuration", self.configuration)
        self.report = {
            "schema_version": "simulation-conformance.v1",
            "status": "passed",
            "service_namespace": "/simulator",
            "steps": 5,
            "step_size_ns": 1_000_000,
            "clock": {
                "playing_ns": 1_000_000,
                "paused_ns": 2_000_000,
                "stepped_ns": 7_000_000,
                "resumed_ns": 8_000_000,
            },
        }
        self.save("observation", self.report)

    def save(self, name, value):
        getattr(self.args, name).write_text(json.dumps(value), encoding="utf-8")

    def create(self):
        return producer.create_result(
            self.args, now=datetime(2026, 9, 8, tzinfo=timezone.utc)
        )

    def cli(self):
        arguments = [sys.executable, str(SCRIPT)]
        for name, value in vars(self.args).items():
            arguments.extend(["--" + name.replace("_", "-"), str(value)])
        return subprocess.run(arguments, text=True, capture_output=True, check=False)

    def test_writer_binds_actual_retained_bytes(self):
        completed = self.cli()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result, raw = producer.read_mapping(self.args.output)
        validate_document(result)
        binding = json.loads(completed.stdout)[0]
        self.assertEqual(binding["conformance_result_sha256"], producer.digest(raw))
        for name, field in (
            ("profile", "qualification_profile_sha256"),
            ("configuration", "configuration_sha256"),
        ):
            owner = binding if name == "profile" else binding["provider"]
            self.assertEqual(
                owner[field], producer.digest(getattr(self.args, name).read_bytes())
            )
        self.assertEqual(result["execution_subject_digest"], self.args.subject_digest)
        self.assertEqual(result["run_id"], self.run["run_id"])
        self.assertEqual(result["checks"][0]["observed_value"], 5_000_000)
        evidence = {item["uri"]: item for item in result["evidence"]}
        for path in (self.args.observation, self.args.world):
            self.assertEqual(
                evidence[path.as_uri()]["sha256"], producer.digest(path.read_bytes())
            )

    def test_rejects_failed_or_inconsistent_probe(self):
        cases = (
            ({"status": "failed"}, "did not pass"),
            ({"steps": True}, "positive integer"),
            ({"step_size_ns": 1.0}, "positive integer"),
            ({"clock": None}, "observations are missing"),
            (
                {"clock": {**self.report["clock"], "stepped_ns": 6_000_000}},
                "exact stepping",
            ),
            (
                {"clock": {**self.report["clock"], "resumed_ns": 7_000_000}},
                "exact stepping",
            ),
            ({"service_namespace": "/foreign"}, "namespace"),
        )
        for update, reason in cases:
            with self.subTest(update=update):
                self.save("observation", {**self.report, **update})
                with self.assertRaisesRegex(ValueError, reason):
                    self.create()

    def test_rejects_world_bytes_changed_after_configuration(self):
        self.args.world.write_bytes(self.world + b"\n")
        with self.assertRaisesRegex(ValueError, "does not bind retained world"):
            self.create()

    def test_rejects_world_with_a_different_physics_step(self):
        world = self.world.replace(b"0.001</max_step_size>", b"0.002</max_step_size>")
        self.assertNotEqual(world, self.world)
        self.args.world.write_bytes(world)
        self.configuration.update(
            world_sha256=producer.digest(world), world_size_bytes=len(world)
        )
        self.save("configuration", self.configuration)
        with self.assertRaisesRegex(
            ValueError, "step size does not match retained SDF"
        ):
            self.create()

    def test_rejects_scenario_and_run_mismatches(self):
        for update, reason in (
            ({"scenario_id": "org.example.foreign"}, "does not identify"),
            ({"scenario_sha256": "b" * 64}, "does not bind"),
        ):
            with self.subTest(update=update):
                self.save("run_context", {**self.run, **update})
                with self.assertRaisesRegex(ValueError, reason):
                    self.create()

    def test_does_not_claim_unobserved_profile_capabilities(self):
        self.profile["requirements"].append(
            {"capability": "synthetic_sensor", "required": True}
        )
        self.save("profile", self.profile)
        with self.assertRaisesRegex(ValueError, "does not qualify"):
            self.create()

    def test_does_not_claim_unobserved_scenario_capabilities(self):
        scenario = copy.deepcopy(self.scenario)
        scenario["provider_requirements"]["capabilities"].append("synthetic_sensor")
        self.save("scenario", scenario)
        self.run["scenario_sha256"] = producer.digest(self.args.scenario.read_bytes())
        self.save("run_context", self.run)
        with self.assertRaisesRegex(
            ValueError, "provider bindings do not satisfy capabilities"
        ):
            self.create()

    def test_invalid_probe_preserves_existing_output(self):
        self.args.output.write_bytes(b"previous output")
        self.save("observation", {**self.report, "status": "failed"})
        completed = self.cli()
        self.assertEqual(completed.returncode, 1)
        self.assertIn("simulation probe did not pass", completed.stderr)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(self.args.output.read_bytes(), b"previous output")

    def test_output_cannot_overwrite_a_probe_input(self):
        self.args.output = self.args.observation
        original = self.args.observation.read_bytes()
        completed = self.cli()
        self.assertEqual(completed.returncode, 1)
        self.assertEqual(self.args.observation.read_bytes(), original)
        self.assertEqual(completed.stdout, "")


if __name__ == "__main__":
    unittest.main()
