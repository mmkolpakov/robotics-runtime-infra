"""Real Cosign signature tests with explicitly simulated S3 GetObject responses."""

from __future__ import annotations

import argparse
import base64
import copy
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import patch

from robotics_runtime_contracts import validate_document
from robotics_runtime_contracts.writers import create_artifact_receipt

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "retained_artifact", ROOT / "docker/evidence-sink/retained-artifact.py"
)
assert SPEC is not None and SPEC.loader is not None
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


class RetainedArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cosign = os.environ.get("ROBOTICS_TEST_COSIGN") or shutil.which("cosign")
        if not cls.cosign:
            raise RuntimeError("Cosign 3.1.3+ is required for retained artifact tests")
        cls.directory = tempfile.TemporaryDirectory(prefix="retention-signatures-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = Path(cls.directory.name)
        cls.source = ROOT / "test/fixtures/playback/golden/golden_0.mcap"
        cls.source_raw = cls.source.read_bytes()
        cls.registration = {
            "run_id": "run-00000000-0000-4000-8000-000000000001",
            "upload_status": "confirmed",
            "uri": "s3://fixture-bucket/recording_0.mcap",
            "version_id": "retained-version-1",
            "sha256": verifier.sha256(cls.source_raw),
            "size_bytes": len(cls.source_raw),
            "media_type": "application/mcap",
        }
        cls.registration_file = cls.root / "registration.json"
        cls.registration_file.write_text(json.dumps(cls.registration), encoding="utf-8")
        for name in ("signer", "foreign"):
            cls.cosign_command(
                "generate-key-pair", "--output-key-prefix", str(cls.root / name)
            )
        cls.cosign_command(
            "signing-config", "create", "--out", str(cls.root / "signing.json")
        )
        cls.cosign_command(
            "trusted-root", "create", "--out", str(cls.root / "root.json")
        )
        cls.bundle = cls.root / "signed.sigstore.json"
        predicate = verifier.retention_predicate(cls.registration_file, cls.source)
        cls.sign(predicate, cls.bundle)

    @classmethod
    def cosign_command(cls, *arguments):
        subprocess.run(
            [cls.cosign, *arguments],
            check=True,
            capture_output=True,
            timeout=60,
            env={**os.environ, "COSIGN_PASSWORD": "test-only"},
        )

    @classmethod
    def sign(cls, predicate, bundle):
        predicate_file = bundle.with_suffix(".predicate.json")
        predicate_file.write_text(json.dumps(predicate), encoding="utf-8")
        cls.cosign_command(
            "attest-blob",
            "--yes",
            "--key",
            str(cls.root / "signer.key"),
            "--signing-config",
            str(cls.root / "signing.json"),
            "--trusted-root",
            str(cls.root / "root.json"),
            "--predicate",
            str(predicate_file),
            "--type",
            verifier.PREDICATE_TYPE,
            "--bundle",
            str(bundle),
            str(cls.source),
        )

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="retention-case-")
        self.addCleanup(directory.cleanup)
        self.work = Path(directory.name)
        self.document = copy.deepcopy(self.registration)
        self.registration_path = self.work / "registration.json"
        self.save_registration()
        self.args = argparse.Namespace(
            registration=self.registration_path,
            bundle=self.bundle,
            key=self.root / "signer.pub",
            output=self.work / "verified",
            cosign=self.cosign,
            aws="fixture-aws",
            max_artifact_bytes=verifier.MAX_ARTIFACT_BYTES,
        )
        self.remote_bytes = self.source_raw
        self.response_overrides = {}
        self.aws_commands = []
        self.real_execute = verifier.execute

    def save_registration(self):
        self.registration_path.write_text(json.dumps(self.document), encoding="utf-8")

    def execute(self, command, **kwargs):
        if command[0] != "fixture-aws":
            return self.real_execute(command, **kwargs)
        self.aws_commands.append(command)
        size = len(self.remote_bytes)
        Path(command[-1]).write_bytes(self.remote_bytes)
        return json.dumps(
            {
                "VersionId": self.document["version_id"],
                "ContentType": self.document["media_type"],
                "ContentLength": size,
                "ContentRange": f"bytes 0-{size - 1}/{size}",
                **self.response_overrides,
            }
        ).encode()

    def verify(self):
        with patch.object(verifier, "execute", side_effect=self.execute):
            return verifier.verify(self.args)

    def assert_rejected(self, reason):
        with self.assertRaisesRegex(ValueError, reason):
            self.verify()
        self.assertFalse(self.args.output.exists())
        self.assertEqual(list(self.work.glob(".retention-*")), [])

    def test_real_signature_and_get_version_produce_a_valid_receipt_chain(self):
        output = self.verify()
        verification = output / "artifact-verification.json"
        result = json.loads(verification.read_bytes())
        validate_document(result)
        receipt = create_artifact_receipt(
            {
                "receipt_id": "fixture-retained",
                "run_id": self.document["run_id"],
                "created_at": datetime.now(UTC).isoformat(),
            },
            self.source,
            verification,
            [
                output / "statement.json",
                output / "trust-policy.pem",
                output / "verification-evidence.sigstore.json",
            ],
        )
        validate_document(receipt)
        self.assertEqual(
            receipt["artifact"]["immutable_revision"], self.document["version_id"]
        )
        self.assertEqual(
            receipt["verification_sha256"], verifier.sha256(verification.read_bytes())
        )
        self.assertEqual(
            (output / "trust-policy.pem").read_bytes(), self.args.key.read_bytes()
        )
        self.assertEqual(
            (output / "verification-evidence.sigstore.json").read_bytes(),
            self.bundle.read_bytes(),
        )
        self.assertFalse((output / "downloaded.mcap").exists())
        self.assertIn("--version-id=retained-version-1", self.aws_commands[0])
        self.assertIn(f"--range=bytes=0-{len(self.source_raw)}", self.aws_commands[0])

    def test_wrong_public_key_cannot_create_a_verification(self):
        self.args.key = self.root / "foreign.pub"
        self.assert_rejected(r"cosign.*failed")

    def test_changed_signed_payload_is_rejected_by_cosign(self):
        bundle = json.loads(self.bundle.read_bytes())
        payload = json.loads(base64.b64decode(bundle["dsseEnvelope"]["payload"]))
        payload["predicate"]["producer_implementation"] = "another-producer"
        bundle["dsseEnvelope"]["payload"] = base64.b64encode(
            json.dumps(payload).encode()
        ).decode()
        self.args.bundle = self.work / "tampered.sigstore.json"
        self.args.bundle.write_text(json.dumps(bundle), encoding="utf-8")
        self.assert_rejected(r"cosign.*failed")

    def test_encoded_key_is_decoded_only_for_the_s3_request(self):
        self.document["uri"] = "s3://fixture-bucket/nested/a%20%23%25_0.mcap"
        self.save_registration()
        self.args.bundle = self.work / "encoded.sigstore.json"
        self.sign(
            verifier.retention_predicate(self.registration_path, self.source),
            self.args.bundle,
        )
        output = self.verify()
        result = json.loads((output / "artifact-verification.json").read_bytes())
        self.assertEqual(result["artifact"]["uri"], self.document["uri"])
        self.assertIn("--key=nested/a #%_0.mcap", self.aws_commands[0])

    def test_changed_downloaded_bytes_are_rejected_even_with_matching_metadata(self):
        self.remote_bytes = bytes([self.source_raw[0] ^ 1]) + self.source_raw[1:]
        self.assert_rejected("downloaded object bytes do not match")

    def test_a_get_of_another_version_is_rejected(self):
        self.response_overrides["VersionId"] = "another-version"
        self.assert_rejected("complete requested object version")

    def test_partial_range_cannot_claim_a_complete_object(self):
        self.response_overrides["ContentRange"] = (
            f"bytes 0-{len(self.source_raw) - 1}/{len(self.source_raw) + 10}"
        )
        self.assert_rejected("complete requested object version")

    def test_changed_media_type_is_rejected(self):
        self.response_overrides["ContentType"] = "application/octet-stream"
        self.assert_rejected("complete requested object version")

    def test_unencoded_key_is_rejected_before_s3(self):
        self.document["uri"] = "s3://fixture-bucket/a b_0.mcap"
        self.save_registration()
        self.assert_rejected("canonical percent encoding")
        self.assertEqual(self.aws_commands, [])

    def test_a_valid_signature_for_another_revision_is_rejected(self):
        self.document["version_id"] = "retained-version-2"
        self.save_registration()
        self.assert_rejected("signed retention predicate does not match")

    def test_a_valid_signature_for_another_run_is_rejected(self):
        self.document["run_id"] = "run-00000000-0000-4000-8000-000000000002"
        self.save_registration()
        self.assert_rejected("signed retention predicate does not match")

    def test_mutable_null_version_never_reaches_s3(self):
        self.document["version_id"] = "null"
        self.save_registration()
        self.assert_rejected("non-null immutable object version")
        self.assertEqual(self.aws_commands, [])

    def test_oversized_registration_never_reaches_s3(self):
        self.args.max_artifact_bytes = len(self.source_raw) - 1
        self.assert_rejected("within the download limit")
        self.assertEqual(self.aws_commands, [])

    def test_existing_output_is_preserved(self):
        self.args.output.mkdir()
        previous = self.args.output / "artifact-verification.json"
        previous.write_bytes(b"previous")
        with self.assertRaisesRegex(ValueError, "must not already exist"):
            self.verify()
        self.assertEqual(previous.read_bytes(), b"previous")
        self.assertEqual(self.aws_commands, [])


if __name__ == "__main__":
    unittest.main()
