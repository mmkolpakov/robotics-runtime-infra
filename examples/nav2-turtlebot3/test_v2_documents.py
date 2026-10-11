"""Synthetic document controls; no robot, simulator or composition is qualified."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path

from nav2_turtlebot3_evaluator import evaluate
from robotics_acceptance_harness import EvaluationContext
from robotics_acceptance_harness.documents import DocumentBundle, load_document
from robotics_acceptance_harness.evidence import load_evidence_index
from robotics_runtime_contracts import validate_document

ROOT = Path(__file__).parent
NAMESPACE = "org.example.nav2-turtlebot3"


def module(name):
    spec = importlib.util.spec_from_file_location(
        name.replace("-", "_"), ROOT / (name + ".py")
    )
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


PREPARE = module("make-scenario")
FINALIZE = module("finalize")


def dump(path, value):
    path.write_text(json.dumps(value))
    return path


def reference(path):
    raw = path.read_bytes()
    return {
        "uri": path.resolve().as_uri(),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "size_bytes": len(raw),
        "media_type": "application/json",
    }


def inputs(root, binding=None):
    report = json.loads(
        (ROOT / "evaluator/tests/fixtures/success/workload.json").read_bytes()
    )
    profile = {
        "profile_id": NAMESPACE,
        "executor": {
            "implementation": NAMESPACE,
            "version": "synthetic-document-control",
        },
        "channels": [
            {
                "name": "/odom",
                "original_type": {
                    "name": "nav_msgs/msg/Odometry",
                    "type_support": {"implementation": "rosidl", "version": "Jazzy"},
                },
                "backend": "ROS-DDS",
                "wire_envelope": "native-ROS-message",
                "native_encoding": "CDR",
                "recorder": {
                    "implementation": "rosbag2",
                    "version": "0.26.11",
                    "transformation": "none",
                },
            }
        ],
        "clock": {"kind": "sim_clock", "source_id": "gazebo-harmonic-clock"},
        "observations": {
            "command": {"kind": "command_acceptance", "requirement": "required"},
            "terminal": {"kind": "native_final_state", "requirement": "required"},
            "condition": {"kind": "postcondition", "requirement": "required"},
            "cleanup": {"kind": "shutdown", "requirement": "required"},
        },
    }
    if binding is None:
        binding = {
            "namespace": NAMESPACE,
            "entry_point": "nav2_turtlebot3_evaluator:evaluate",
            "distribution": "nav2-turtlebot3-evaluator",
            "version": "0.3.0",
            "artifact_sha256": "a" * 64,
            "receipt_sha256": "b" * 64,
        }
    profile_path = dump(root / "profile.json", profile)
    requirements = dump(
        root / "requirements.json",
        {
            "case": "success",
            "configuration": {**report["parameters"], "case": "success"},
            "evaluator_requirement": binding,
        },
    )
    prepared = root / "archive" / "inputs"
    manifest = PREPARE.prepare(
        profile_path,
        requirements,
        prepared,
        run_id="run-11111111-2222-4333-8444-555555555555",
    )
    return prepared, manifest


def completed(prepared, manifest):
    capture = prepared.parent / "capture"
    capture.mkdir()
    report = json.loads(
        (ROOT / "evaluator/tests/fixtures/success/workload.json").read_bytes()
    )
    report["run_id"] = manifest["run_id"]
    workload = dump(capture / "workload.json", report)
    cdr = capture / "get-result-response.cdr"
    cdr.write_bytes((ROOT / "evaluator/tests/fixtures/success" / cdr.name).read_bytes())
    cleanup = dump(
        capture / "cleanup.json", {"remaining": [], "scope": "synthetic source control"}
    )
    now = datetime.now(UTC).isoformat()
    facts = {
        "started_at": now,
        "finished_at": now,
        "observations": {
            "command": {
                "state": "measured",
                "value": report["goal_accepted"],
                "evidence": reference(workload),
            },
            "terminal": {
                "state": "measured",
                "value": report["action_status"],
                "evidence": reference(workload),
            },
            "condition": {
                "state": "measured",
                "value": report["final_amcl_pose"],
                "evidence": reference(workload),
            },
            "cleanup": {
                "state": "measured",
                "value": [],
                "evidence": reference(cleanup),
            },
        },
        "artifacts": [
            {
                "source": "workload.json",
                "artifact_id": "workload",
                "kind": "other_evidence",
                "media_type": "application/json",
            },
            {
                "source": cdr.name,
                "artifact_id": "get-result-response",
                "kind": "other_evidence",
                "media_type": "application/octet-stream",
            },
            {
                "source": cleanup.name,
                "artifact_id": "cleanup",
                "kind": "other_evidence",
                "media_type": "application/json",
            },
        ],
        "policy_observation": {
            "recording_mode": "native-files",
            "compression": "none",
            "retention_class": "test-evidence",
            "upload_mode": "local_only",
            "remote_sink_used": False,
            "spool_peak_size_bytes": 1024 * 1024,
            "upload_lag_max_sec": 0,
        },
    }
    dump(capture / "completed-facts.json", facts)
    return capture, facts


class NativeDocumentControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_public_inputs_are_issued_before_capture_and_remain_immutable(self):
        prepared, manifest = inputs(self.root)
        scenario = load_document(
            prepared / "scenario.json",
            expected_role="acceptance_scenario",
            extension_schemas={
                "urn:nav2-turtlebot3:scenario:v1": (
                    prepared / "nav2.schema.json"
                ).read_bytes()
            },
        )
        self.assertEqual(scenario.schema_version, "acceptance-scenario.v2")
        self.assertIsInstance(
            scenario.data["extensions"][NAMESPACE]["required_tf_edges"], tuple
        )
        originals = {p: p.read_bytes() for p in prepared.iterdir()}
        self.assertFalse((prepared.parent / "observation.json").exists())
        capture, _facts = completed(prepared, manifest)
        result = FINALIZE.complete(prepared, capture)
        for path, raw in originals.items():
            self.assertEqual(path.read_bytes(), raw)
        observation = json.loads((prepared.parent / "observation.json").read_bytes())
        self.assertEqual(
            observation["runtime_manifest_sha256"], manifest["runtime"]["sha256"]
        )
        self.assertEqual(observation["run_id"], manifest["run_id"])
        validate_document(observation)
        validate_document(json.loads(Path(result["evidence_index"]).read_bytes()))

    def test_product_method_consumes_the_public_immutable_v2_context(self):
        prepared, manifest = inputs(self.root)
        capture, _facts = completed(prepared, manifest)
        result = FINALIZE.complete(prepared, capture)
        scenario = load_document(
            prepared / "scenario.json",
            expected_role="acceptance_scenario",
            extension_schemas={
                "urn:nav2-turtlebot3:scenario:v1": (
                    prepared / "nav2.schema.json"
                ).read_bytes()
            },
        )
        runtime = load_document(
            prepared / "runtime.json", expected_role="runtime_manifest"
        )
        evidence = load_evidence_index(
            result["evidence_index"], expected_run_id=manifest["run_id"]
        )
        context = EvaluationContext(
            manifest["run_id"],
            "nav2",
            DocumentBundle(scenario, runtime),
            evidence,
            (),
            0,
            1,
        )
        self.assertEqual(
            [assertion.status for assertion in evaluate(context)], ["passed", "passed"]
        )

    def test_missing_required_observation_is_not_invented(self):
        prepared, manifest = inputs(self.root)
        capture, facts = completed(prepared, manifest)
        del facts["observations"]["cleanup"]
        dump(capture / "completed-facts.json", facts)
        FINALIZE.complete(prepared, capture)
        observation = json.loads((prepared.parent / "observation.json").read_bytes())
        self.assertNotIn("cleanup", observation["observations"])

    def test_changed_preexecution_runtime_refuses_completion(self):
        prepared, manifest = inputs(self.root)
        capture, _facts = completed(prepared, manifest)
        runtime = prepared / "runtime.json"
        runtime.write_bytes(runtime.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "input bytes changed"):
            FINALIZE.complete(prepared, capture)
        self.assertFalse((prepared.parent / "evidence-index.json").exists())

    def test_capture_path_escape_refuses_before_output(self):
        prepared, manifest = inputs(self.root)
        capture, facts = completed(prepared, manifest)
        facts["artifacts"][0]["source"] = "../../profile.json"
        dump(capture / "completed-facts.json", facts)
        with self.assertRaisesRegex(ValueError, "confined regular"):
            FINALIZE.complete(prepared, capture)
        self.assertFalse((prepared.parent / "observation.json").exists())

    def test_declared_case_cannot_diverge_from_worker_configuration(self):
        profile = dump(self.root / "profile.json", {"profile_id": NAMESPACE})
        requirements = dump(
            self.root / "requirements.json",
            {
                "case": "success",
                "configuration": {"case": "cancel"},
                "evaluator_requirement": {},
            },
        )
        with self.assertRaisesRegex(ValueError, "configuration differs"):
            PREPARE.prepare(profile, requirements, self.root / "archive")
        self.assertFalse((self.root / "archive").exists())


if __name__ == "__main__":
    unittest.main()
