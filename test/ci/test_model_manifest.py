"""Exercise the producer against the installed contracts, including altered evidence."""

from __future__ import annotations

import json
import runpy
import tempfile
import unittest
from hashlib import sha256
from pathlib import Path

from robotics_runtime_contracts import validate_document

ROOT = Path(__file__).resolve().parents[2]
write_manifest = runpy.run_path(
    str(ROOT / "test/accelerators/write-model-manifest.py")
)["write_manifest"]


class ModelManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.report_dir = Path(self.temporary.name)
        (self.report_dir / "model").mkdir()
        (self.report_dir / "configuration").mkdir()
        self.files = {
            "model/model.onnx": b"fixture model bytes",
            "sample-inputs.npy": b"fixture dataset bytes",
            "configuration/inference-provider.json": b'{"device_type":"CPU"}',
        }
        for name, content in self.files.items():
            (self.report_dir / name).write_bytes(content)
        self.fixture = json.loads(
            (ROOT / "test/accelerators/fixtures/onnxruntime-sigmoid.json").read_bytes()
        )
        self.fixture["source"]["sha256"] = self.digest("model/model.onnx")
        self.fixture_path = self.report_dir / "fixture.json"
        self.fixture_path.write_text(json.dumps(self.fixture))
        self.report = {
            "status": "passed",
            "numerical_parity": True,
            "fallback_count": 0,
            "executed_providers": ["OpenVINOExecutionProvider"],
            "runtime_version": self.fixture["runtime_version"],
            "model_artifact_sha256": self.digest("model/model.onnx"),
            "sample_dataset_path": "/reports/sample-inputs.npy",
            "sample_dataset_sha256": self.digest("sample-inputs.npy"),
            "provider_options_sha256": self.digest(
                "configuration/inference-provider.json"
            ),
            "tolerances": {"absolute": 0.00001, "relative": 0.0001},
        }
        self.report_path = self.report_dir / "sensor-inference.json"
        self.report_path.write_text(json.dumps(self.report))

    def digest(self, name: str) -> str:
        return sha256(self.files[name]).hexdigest()

    def write(self) -> Path:
        return write_manifest(self.report_dir, self.fixture_path, "sha256:" + "a" * 64)

    def test_manifest_binds_model_tensors_configuration_and_conformance(self) -> None:
        document = json.loads(self.write().read_bytes())
        validate_document(document)
        self.assertEqual(
            document["model_id"], "org.example.onnxruntime.sigmoid.openvino"
        )
        self.assertEqual(
            document["source"]["size_bytes"], len(self.files["model/model.onnx"])
        )
        self.assertEqual(document["source"]["inputs"], document["target"]["inputs"])
        self.assertEqual(
            document["build"]["configuration_sha256"],
            self.report["provider_options_sha256"],
        )
        self.assertEqual(
            document["numerical_conformance"]["report_sha256"],
            sha256(self.report_path.read_bytes()).hexdigest(),
        )

    def test_changed_inputs_cannot_produce_a_manifest(self) -> None:
        for name, original in self.files.items():
            with self.subTest(name=name):
                path = self.report_dir / name
                path.write_bytes(original + b"changed")
                with self.assertRaisesRegex(ValueError, "evidence differs"):
                    self.write()
                self.assertFalse(
                    (self.report_dir / "model/model-manifest.json").exists()
                )
                path.write_bytes(original)

    def test_failed_probe_cannot_be_relabelled_as_conforming(self) -> None:
        self.report["numerical_parity"] = False
        self.report_path.write_text(json.dumps(self.report))
        with self.assertRaisesRegex(ValueError, "evidence differs"):
            self.write()


if __name__ == "__main__":
    unittest.main()
