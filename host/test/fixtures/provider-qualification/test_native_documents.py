import sys
import unittest
import tempfile
import json
import hashlib
import shutil
import importlib.metadata
from pathlib import Path

sys.path.insert(0, "/producer")
from provider_qualification import (
    produce,
    time_value,
    NAMESPACE,
    SCHEMA_URI,
    CAPABILITIES,
)
from robotics_runtime_contracts import validate_document, ContractError
from robotics_runtime_contracts.providers import (
    validate_provider_requirements,
    ProviderRequirementError,
)
from robotics_runtime_contracts.writers import write_document
from robotics_acceptance_harness.evidence import (
    load_evidence_index,
    EvidenceValidationError,
)

FIXTURES = Path("/fixtures")
SCHEMA = Path("/schemas/native-provider-source.v1.schema.json")


class NativeDocuments(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_provider(self, backend, inputs=None, manifest=None):
        return produce(
            backend,
            inputs or FIXTURES / "native" / backend,
            manifest or FIXTURES / (backend + "-inputs.json"),
            SCHEMA,
            self.root / backend,
            generated_at="2026-10-05T00:00:00Z",
            run_id="run-cc58f1f4-2bfb-44aa-b33c-aa2a1cb3e37b",
        )

    def changed_inputs(self, backend, name, edit):
        inputs = self.root / "changed"
        shutil.copytree(FIXTURES / "native" / backend, inputs)
        path = inputs / name
        value = json.loads(path.read_text())
        edit(value)
        path.write_text(json.dumps(value))
        manifest = json.loads((FIXTURES / (backend + "-inputs.json")).read_text())
        raw = path.read_bytes()
        manifest["files"][name] = {
            "sha256": hashlib.sha256(raw).hexdigest(),
            "size_bytes": len(raw),
        }
        where = self.root / "manifest.json"
        where.write_text(json.dumps(manifest))
        return inputs, where

    def test_retained_bytes_survive_input_removal_and_existing_harness_rejects_tamper(
        self,
    ):
        inputs = self.root / "ephemeral-inputs"
        shutil.copytree(FIXTURES / "native/webots", inputs)
        paths = self.run_provider("webots", inputs=inputs)
        shutil.rmtree(inputs)
        verified = load_evidence_index(
            paths["evidence"],
            expected_run_id="run-cc58f1f4-2bfb-44aa-b33c-aa2a1cb3e37b",
        )
        self.assertEqual(len(verified.links), 6)
        payload = self.root / "webots/raw/controller-result.json"
        payload.write_bytes(payload.read_bytes() + b" ")
        with self.assertRaises(EvidenceValidationError):
            load_evidence_index(paths["evidence"])

    def test_integer_ns_beyond_javascript_precision_are_preserved(self):
        native = time_value(
            "9007199254740993",
            "ns",
            "native source",
            "epoch-1",
            {"sha256": "1" * 64, "pointer": "/clock"},
        )
        self.assertEqual(native["value"], "9007199254740993")
        with self.assertRaises(ValueError):
            time_value(
                9007199254740993,
                "ns",
                "native source",
                "epoch-1",
                {"sha256": "1" * 64, "pointer": "/clock"},
            )

    def test_frame_unit_mismatch_is_rejected_by_public_extension_validation(self):
        paths = self.run_provider("webots")
        document = json.loads(paths["conformance"].read_text())
        document["extensions"][NAMESPACE]["frame"]["position_unit"] = "cm"
        with self.assertRaises(ContractError):
            validate_document(
                document, extension_schemas={SCHEMA_URI: SCHEMA.read_bytes()}
            )

    def test_scene_requirement_cannot_merge_two_incomplete_providers(self):
        requirement = {
            "capabilities": [],
            "scene": {
                "semantic_scene_id": "native-scene",
                "required_entities": ["body"],
                "required_interfaces": ["native-step"],
            },
        }
        bindings = [
            {
                "capabilities": [],
                "scene": {
                    "semantic_scene_id": "native-scene",
                    "entities": ["body"],
                    "interfaces": [],
                    "physical_parameters": {},
                },
            },
            {
                "capabilities": [],
                "scene": {
                    "semantic_scene_id": "native-scene",
                    "entities": [],
                    "interfaces": ["native-step"],
                    "physical_parameters": {},
                },
            },
        ]
        with self.assertRaises(ProviderRequirementError):
            validate_provider_requirements(requirement, bindings)

    def test_installed_public_packages(self):
        self.assertEqual(
            importlib.metadata.version("robotics-runtime-contracts"), "0.18.2"
        )
        self.assertEqual(
            importlib.metadata.version("robotics-acceptance-harness"), "0.19.1"
        )

    def test_accepted_cpu_source_documents_and_native_precision(self):
        for backend in ["gazebo", "webots"]:
            paths = self.run_provider(backend)
            document = json.loads(paths["conformance"].read_text())
            self.assertEqual(document["status"], "passed")
            validate_document(
                document, extension_schemas={SCHEMA_URI: SCHEMA.read_bytes()}
            )
            validate_provider_requirements(
                {"capabilities": CAPABILITIES},
                [{"capabilities": document["capabilities"]}],
            )
            native = document["extensions"][NAMESPACE]
            if backend == "webots":
                self.assertEqual(native["native_times"][1]["value"], 0.016)
                self.assertEqual(native["native_times"][1]["hex"], float(0.016).hex())
                self.assertNotIn("Clock", json.dumps(native))
                self.assertTrue(
                    native["lifecycle"]["evidence_before_destructive_reset"]
                )
            else:
                self.assertTrue(
                    all(
                        value["representation"] == "integer-decimal"
                        and isinstance(value["value"], str)
                        for value in native["native_times"]
                    )
                )

    def test_isaac_representative_shape_cannot_establish_execution_capabilities(self):
        paths = self.run_provider("isaac")
        document = json.loads(paths["conformance"].read_text())
        self.assertEqual(document["status"], "skipped")
        self.assertEqual(document["capabilities"], [])
        self.assertEqual(
            document["extensions"][NAMESPACE]["execution_evaluation"], "unevaluated"
        )
        with self.assertRaises(ProviderRequirementError):
            validate_provider_requirements(
                {"capabilities": ["simulated_physics"]},
                [{"capabilities": document["capabilities"]}],
            )

    def test_missing_provider_and_unsupported_capability_refuse(self):
        with self.assertRaises(ValueError):
            self.run_provider("missing")
        with self.assertRaises(ProviderRequirementError):
            validate_provider_requirements(
                {"capabilities": ["native-rtx-execution"]},
                [{"capabilities": CAPABILITIES}],
            )
        with self.assertRaises(ProviderRequirementError):
            validate_provider_requirements({"capabilities": ["simulated_physics"]}, [])

    def test_tampered_bytes_refuse_existing_output_is_unchanged(self):
        paths = self.run_provider("webots")
        before = paths["conformance"].read_bytes()
        inputs = self.root / "tampered"
        shutil.copytree(FIXTURES / "native/webots", inputs)
        (inputs / "controller-result.json").write_bytes(
            (inputs / "controller-result.json").read_bytes() + b" "
        )
        with self.assertRaises(ContractError):
            self.run_provider("webots", inputs=inputs)
        self.assertEqual(paths["conformance"].read_bytes(), before)

    def test_missing_native_evidence_refuses(self):
        inputs = self.root / "missing"
        shutil.copytree(FIXTURES / "native/webots", inputs)
        (inputs / "pre-reset.json").unlink()
        with self.assertRaises((ContractError, OSError)):
            self.run_provider("webots", inputs=inputs)

    def test_native_time_unit_mismatch_rejects_before_a_verdict(self):
        inputs, manifest = self.changed_inputs(
            "webots",
            "controller-result.json",
            lambda d: d["time"].__setitem__("native_unit", "ms"),
        )
        with self.assertRaisesRegex(ValueError, "time identity"):
            self.run_provider("webots", inputs, manifest)

    def test_evidence_after_reset_refuses_even_with_rebound_bytes(self):
        inputs, manifest = self.changed_inputs(
            "webots",
            "pre-reset.json",
            lambda d: d["reset"].__setitem__("observed", True),
        )
        with self.assertRaisesRegex(ValueError, "pre-reset"):
            self.run_provider("webots", inputs, manifest)

    def test_extension_shape_and_digest_refuse_invalid_units(self):
        paths = self.run_provider("webots")
        document = json.loads(paths["conformance"].read_text())
        document["extensions"][NAMESPACE]["native_times"][0]["unit"] = "ns"
        before = paths["conformance"].read_bytes()
        with self.assertRaises(ContractError):
            write_document(
                document,
                paths["conformance"],
                extension_schemas={SCHEMA_URI: SCHEMA.read_bytes()},
            )
        self.assertEqual(paths["conformance"].read_bytes(), before)
        document = json.loads(before)
        with self.assertRaises(ContractError):
            validate_document(
                document, extension_schemas={SCHEMA_URI: SCHEMA.read_bytes() + b" "}
            )

    def test_representative_source_execution_claim_is_not_accepted(self):
        paths = self.run_provider("isaac")
        document = json.loads(paths["conformance"].read_text())
        document["extensions"][NAMESPACE]["scope"] = "native-cpu-source"
        document["extensions"][NAMESPACE]["execution_evaluation"] = (
            "accepted-source-proof"
        )
        with self.assertRaises(ContractError):
            validate_document(
                document, extension_schemas={SCHEMA_URI: SCHEMA.read_bytes()}
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
