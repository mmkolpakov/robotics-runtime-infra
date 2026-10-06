"""Check fresh report metadata using retained model bytes and installed public APIs."""

import hashlib
import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[5]
sys.path.insert(0, str(ROOT / "host/producers"))
SPEC = importlib.util.spec_from_file_location(
    "installed_webots_document_checks", Path(__file__).with_name("document-checks.py")
)
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)
SCHEMA = ROOT / "config/qualification/native-provider-source.v1.schema.json"


class FreshDocumentMetadata(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.native = self.root / "native"
        shutil.copytree(
            ROOT / "host/test/fixtures/provider-qualification/native/webots",
            self.native,
        )
        self.output = self.root / "new-report"
        self.declared = json.loads((ROOT / "workers/webots/upstream.json").read_bytes())
        self.worker = json.loads((self.native / "worker-result.json").read_bytes())
        self.identity = {
            "owner_id": self.worker["owner_id"],
            "release": self.declared["release"],
            "upstream": self.declared,
        }
        self.bind_identity()

    def bind_identity(self):
        raw = (json.dumps(self.identity, indent=2) + "\n").encode()
        (self.native / "worker-identity.json").write_bytes(raw)
        self.worker["worker_identity_ref"] = {
            "uri": (self.native / "worker-identity.json").as_uri(),
            "sha256": hashlib.sha256(raw).hexdigest(),
            "size_bytes": len(raw),
        }
        (self.native / "worker-result.json").write_text(
            json.dumps(self.worker, indent=2) + "\n"
        )

    def create(self):
        return CHECKS.create_native_documents(
            self.native,
            self.worker,
            self.output,
            SCHEMA,
            "sha256:" + "a" * 64,
            "run-12345678-1234-4234-9234-123456789abc",
            self.declared,
        )

    def test_report_binds_retained_release_and_creates_one_current_utc_date(self):
        before_bytes = {p.name: p.read_bytes() for p in self.native.iterdir()}
        before = datetime.now(timezone.utc)
        with patch.object(CHECKS, "datetime", wraps=datetime) as clock:
            paths, manifest_path, generated_at = self.create()
        after = datetime.now(timezone.utc)
        self.assertEqual(clock.now.call_count, 1)
        self.assertEqual(clock.now.call_args.args, (timezone.utc,))
        created = datetime.fromisoformat(generated_at)
        self.assertEqual(created.utcoffset().total_seconds(), 0)
        self.assertLessEqual(before, created)
        self.assertLessEqual(created, after)
        conformance = json.loads(paths["conformance"].read_bytes())
        evidence = json.loads(paths["evidence"].read_bytes())
        manifest = json.loads(manifest_path.read_bytes())
        self.assertEqual(conformance["provider"]["version"], self.identity["release"])
        self.assertEqual(manifest["version"], self.identity["release"])
        self.assertEqual(conformance["generated_at"], generated_at)
        self.assertEqual(evidence["generated_at"], generated_at)
        self.assertIn("worker-identity.json", manifest["files"])
        self.assertEqual(len(CHECKS.load_evidence_index(paths["evidence"]).links), 7)
        self.assertEqual(
            (self.output / "documents/raw/worker-identity.json").read_bytes(),
            before_bytes["worker-identity.json"],
        )
        times = conformance["extensions"][CHECKS.NAMESPACE]["native_times"]
        self.assertEqual(times[1]["value"], 0.016)
        self.assertEqual(times[1]["hex"], (0.016).hex())
        self.assertTrue(
            all(row["authority"] == "Webots Supervisor.getTime" for row in times)
        )
        self.assertEqual(
            {p.name: p.read_bytes() for p in self.native.iterdir()}, before_bytes
        )

    def test_absent_or_incompatible_observed_release_refuses_before_output(self):
        for value in (None, "", "R2025b"):
            with self.subTest(release=value):
                self.identity["release"] = value
                self.bind_identity()
                with self.assertRaisesRegex(ValueError, "Webots release"):
                    self.create()
                self.assertFalse(self.output.exists())
        self.identity.pop("release")
        self.bind_identity()
        with self.assertRaisesRegex(ValueError, "release is absent"):
            self.create()
        self.assertFalse(self.output.exists())

    def test_missing_or_unbound_identity_refuses_before_output(self):
        (self.native / "worker-identity.json").unlink()
        with self.assertRaisesRegex(ValueError, "identity is absent"):
            self.create()
        self.assertFalse(self.output.exists())
        self.bind_identity()
        (self.native / "worker-identity.json").write_bytes(b'{"release":"R2025a"}')
        with self.assertRaisesRegex(ValueError, "bytes do not match"):
            self.create()
        self.assertFalse(self.output.exists())
        self.bind_identity()
        self.worker.pop("worker_identity_ref")
        with self.assertRaisesRegex(ValueError, "bytes do not match"):
            self.create()
        self.assertFalse(self.output.exists())

    def test_declared_pin_and_native_owner_cannot_be_substituted(self):
        self.declared = {**self.declared, "release": "R2025b"}
        with self.assertRaisesRegex(ValueError, "differs from declared pin"):
            self.create()
        self.declared.pop("release")
        with self.assertRaisesRegex(ValueError, "compatibility release is absent"):
            self.create()
        self.declared = json.loads((ROOT / "workers/webots/upstream.json").read_bytes())
        self.identity["upstream"] = {**self.declared, "release": "R2025b"}
        self.bind_identity()
        with self.assertRaisesRegex(ValueError, "differs from declared pin"):
            self.create()
        self.identity["upstream"] = self.declared
        self.identity["owner_id"] = "foreign"
        self.bind_identity()
        with self.assertRaisesRegex(ValueError, "another owner"):
            self.create()
        self.assertFalse(self.output.exists())

    def test_changed_identity_after_admission_cannot_rebind_the_report_version(self):
        identity_path = self.native / "worker-identity.json"
        read_bytes = Path.read_bytes
        reads = 0

        def changed_read(path):
            nonlocal reads
            if path == identity_path:
                reads += 1
                if reads == 2:
                    changed = {**self.identity, "release": "R2025b"}
                    path.write_text(json.dumps(changed, indent=2) + "\n")
            return read_bytes(path)

        with (
            patch.object(Path, "read_bytes", changed_read),
            self.assertRaises(CHECKS.ContractError),
        ):
            self.create()
        self.assertFalse((self.output / "documents/conformance-result.json").exists())

    def test_existing_output_and_original_native_bytes_remain_unchanged(self):
        self.output.mkdir()
        marker = self.output / "previous"
        marker.write_bytes(b"previous report")
        before = {p.name: p.read_bytes() for p in self.native.iterdir()}
        with self.assertRaises(FileExistsError):
            self.create()
        self.assertEqual(marker.read_bytes(), b"previous report")
        self.assertEqual(
            {p.name: p.read_bytes() for p in self.native.iterdir()}, before
        )


if __name__ == "__main__":
    unittest.main()
