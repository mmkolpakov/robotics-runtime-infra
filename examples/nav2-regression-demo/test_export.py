"""Real-Cosign export, relocation, and trust-boundary regressions."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import export_bundle as exporter
import regression_driver as driver


class ExportQualification(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not list((driver.DEMO / "dist").glob("nav2_turtlebot3_evaluator-*.whl")):
            raise unittest.SkipTest(
                "build the evaluator with run-demo.sh --prepare-only"
            )
        cls.tool = driver._cosign_tool(None)
        (driver.DEMO / "work").mkdir(exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(
            prefix="export-test-", dir=driver.DEMO / "work"
        )
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.environment = {**os.environ, "COSIGN_PASSWORD": "test-only"}
        cls.key = cls.root / "user"
        exporter.run(
            [
                cls.tool["executable"],
                "generate-key-pair",
                "--output-key-prefix",
                cls.key,
            ],
            env=cls.environment,
        )
        cls.profile = cls.root / "operator" / "operator-profile.json"
        cls.work = cls.root / "run"
        cls.package = cls.root / "package"
        with (
            patch.dict(os.environ, {"COSIGN_PASSWORD": "test-only"}),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            status = exporter.main(
                [
                    "--bootstrap",
                    "--operator-profile",
                    str(cls.profile),
                    "--publisher-key",
                    str(cls.key.with_suffix(".key")),
                    "--public-key",
                    str(cls.key.with_suffix(".pub")),
                    "--work-dir",
                    str(cls.work),
                    "--output",
                    str(cls.package),
                ]
            )
        if status != 0:
            raise RuntimeError("real-Cosign export failed")
        cls.bin = cls.root / "bin"
        cls.bin.mkdir()
        (cls.bin / "cosign").symlink_to(cls.tool["executable"])
        cls.verify_env = {
            **cls.environment,
            "PATH": str(cls.bin) + os.pathsep + os.environ.get("PATH", ""),
            "ROBOTICS_CONTRACTS_CLI": str(
                Path(exporter.sys.executable).parent / "robotics-contracts"
            ),
        }

    def verify(self, package, key):
        arguments = (package / "qualification-arguments.txt").read_text().splitlines()
        return exporter.run(
            [
                exporter.QUALIFICATION / "verify-bundle",
                *arguments,
                "--bundle",
                "qualification.sigstore.json",
                "--key",
                key,
            ],
            cwd=package,
            env=self.verify_env,
        )

    def test_round_trip_and_full_inventory(self):
        verified = self.verify(self.package, self.key.with_suffix(".pub"))
        self.assertIn(b"qualification bundle verified", verified)
        statement = json.loads(
            (self.package / "qualification-statement.json").read_bytes()
        )
        kinds = {item["kind"] for item in statement["predicate"]["artifacts"]}
        self.assertTrue(
            {
                "scenario",
                "acceptance_run",
                "runtime_manifest",
                "domain_result",
                "acceptance_aggregate",
                "evidence_index",
                "acceptance_observation",
                "artifact_receipt",
                "artifact_verification",
                "attestation",
                "policy",
                "verification",
                "package",
                "junit",
                "other_evidence",
            }
            <= kinds
        )
        self.assertNotIn("recording_summary", kinds)
        self.assertFalse(list(self.package.rglob("*.key")))
        self.assertFalse(list(self.package.rglob("*.pub")))

    def test_relocated_package_without_original_evidence(self):
        relocated = self.root / "relocated"
        shutil.copytree(self.package, relocated)
        hidden = self.root / "original-unavailable"
        self.work.rename(hidden)
        try:
            self.assertIn(
                b"qualification bundle verified",
                self.verify(relocated, self.key.with_suffix(".pub")),
            )
        finally:
            hidden.rename(self.work)

    def test_wrong_public_key_refused(self):
        wrong = self.root / "wrong"
        exporter.run(
            [
                self.tool["executable"],
                "generate-key-pair",
                "--output-key-prefix",
                wrong,
            ],
            env=self.environment,
        )
        with self.assertRaises(exporter.subprocess.CalledProcessError) as refused:
            self.verify(self.package, wrong.with_suffix(".pub"))
        self.assertIn(b"Sigstore verification failed", refused.exception.stderr)

    def test_failed_verdict_remains_failed_in_a_verified_export(self):
        output = self.root / "failed-package"
        with (
            patch.dict(os.environ, {"COSIGN_PASSWORD": "test-only"}),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            status = exporter.main(
                [
                    "--operator-profile",
                    str(self.profile),
                    "--publisher-key",
                    str(self.key.with_suffix(".key")),
                    "--case",
                    "criterion-sensitivity",
                    "--work-dir",
                    str(self.root / "failed-run"),
                    "--output",
                    str(output),
                ]
            )
        self.assertEqual(status, 0)
        aggregate = json.loads(
            (output / "subjects" / "acceptance-aggregate.json").read_bytes()
        )
        self.assertEqual(aggregate["per_domain_aggregate"], "failed")
        self.assertIn(
            b"qualification bundle verified",
            self.verify(output, self.key.with_suffix(".pub")),
        )

    def test_one_changed_evidence_byte_refused(self):
        tampered = self.root / "tampered"
        shutil.copytree(self.package, tampered)
        path = tampered / "subjects" / "evidence" / "get-result-response.cdr"
        raw = bytearray(path.read_bytes())
        raw[-1] ^= 1
        path.write_bytes(raw)
        with self.assertRaises(exporter.subprocess.CalledProcessError):
            self.verify(tampered, self.key.with_suffix(".pub"))

    def test_foreign_operator_profile_refused_at_evaluation_and_export(self):
        foreign = self.root / "foreign"
        exporter.run(
            [
                self.tool["executable"],
                "generate-key-pair",
                "--output-key-prefix",
                foreign,
            ],
            env=self.environment,
        )
        values = json.loads(self.profile.read_bytes())
        values["verifier"]["public_key"] = str(foreign.with_suffix(".pub"))
        values["verifier"]["public_key_sha256"] = driver._sha256(
            foreign.with_suffix(".pub")
        )
        values["evaluators"][0]["publisher"]["public_key_sha256"] = values["verifier"][
            "public_key_sha256"
        ]
        profile = self.root / "foreign-profile.json"
        profile.write_text(json.dumps(values))
        profile.chmod(0o400)
        selected = self.work / "run" / "baseline"
        prepared = selected / "archive" / "inputs"
        completed = driver._evaluate_cli(
            {
                "scenario": prepared / "scenario.json",
                "runtime": prepared / "runtime.json",
                "run_context": prepared / "run.json",
                "evidence_index": selected / "archive" / "evidence-index.json",
                "run_id": driver.RUN_IDS["baseline"],
                "domain_id": "nav2",
            },
            prepared,
            self.root / "foreign-evaluation",
            self.work / "admission" / "qualification",
            profile,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(
            (self.root / "foreign-evaluation" / "acceptance-result.json").exists()
        )
        with (
            patch.dict(os.environ, {"COSIGN_PASSWORD": "test-only"}),
            contextlib.redirect_stderr(io.StringIO()) as errors,
        ):
            status = exporter.main(
                [
                    "--operator-profile",
                    str(profile),
                    "--publisher-key",
                    str(self.key.with_suffix(".key")),
                    "--work-dir",
                    str(self.root / "foreign-run"),
                    "--output",
                    str(self.root / "foreign-package"),
                ]
            )
        self.assertEqual(status, 1)
        self.assertIn("does not match the operator profile key", errors.getvalue())
        self.assertFalse((self.root / "foreign-package").exists())

    def test_recorded_chronology_can_be_aggregated(self):
        selected = self.work / "run" / "baseline"
        run = json.loads((selected / "archive" / "inputs" / "run.json").read_bytes())
        runtime = json.loads(
            (selected / "archive" / "inputs" / "runtime.json").read_bytes()
        )
        result = json.loads(
            (selected / "assessment" / "acceptance-result.json").read_bytes()
        )
        self.assertEqual(run["created_at"], result["original_execution"]["started_at"])
        self.assertEqual(runtime["generated_at"], run["created_at"])
        aggregate = json.loads(
            (selected / "assessment" / "acceptance-aggregate.json").read_bytes()
        )
        self.assertEqual(aggregate["per_domain_aggregate"], "passed")


if __name__ == "__main__":
    unittest.main()
