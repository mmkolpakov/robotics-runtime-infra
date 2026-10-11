"""Installed public CLI controls with a temporary stock Cosign publisher."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from dataclasses import asdict
from pathlib import Path

from robotics_acceptance_harness.evaluator_trust import CosignKeyWheelPolicy

ROOT = Path(__file__).parent


def module(name):
    specification = importlib.util.spec_from_file_location(
        name.replace("-", "_"), ROOT / (name + ".py")
    )
    value = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(value)
    return value


DOCUMENTS = module("test_v2_documents")
QUALIFY = module("qualify-evaluator")


class InstalledCliControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        profile_path = os.environ.get("ROBOTICS_COSIGN_PROFILE")
        wheel_path = os.environ.get("NAV2_EVALUATOR_WHEEL")
        if not profile_path or not wheel_path:
            raise unittest.SkipTest(
                "exact installed evaluator wheel and admitted Cosign tool profile required"
            )
        cls.temporary = tempfile.TemporaryDirectory(prefix="nav2-local-publisher-")
        cls.root = Path(cls.temporary.name)
        cls.addClassCleanup(cls.temporary.cleanup)
        tool = json.loads(Path(profile_path).read_bytes())
        executable = Path(tool["executable"])
        if (
            hashlib.sha256(executable.read_bytes()).hexdigest()
            != tool["executable_sha256"]
        ):
            raise ValueError("Cosign differs from the approved executable SHA-256")
        cls.wheel = Path(wheel_path).resolve()
        cls.environment = {
            "HOME": str(cls.root),
            "XDG_CONFIG_HOME": str(cls.root / "config"),
            "COSIGN_PASSWORD": "",
            "LC_ALL": "C.UTF-8",
        }

        def cosign(*arguments):
            result = subprocess.run(
                [str(executable), *arguments],
                cwd=cls.root,
                env=cls.environment,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                timeout=30,
                check=False,
            )
            if result.returncode:
                raise ValueError("stock temporary publisher operation refused")
            return result.stdout

        version = json.loads(cosign("version", "--json"))
        if version["gitVersion"] != tool["version"]:
            raise ValueError("stock Cosign exact build version differs")
        cosign("signing-config", "create", "--out", "signing.json")
        cosign("trusted-root", "create", "--out", "roots.json")
        cosign("generate-key-pair", "--output-key-prefix", "publisher")
        cosign("generate-key-pair", "--output-key-prefix", "other")
        predicate = DOCUMENTS.dump(
            cls.root / "predicate.json",
            {"scope": "synthetic Nav2 document controls; no native performance claim"},
        )
        cls.bundle = cls.root / "wheel.sigstore.json"
        predicate_type = "urn:nav2-turtlebot3:consumer-evaluator-qualification:v1"
        cosign(
            "attest-blob",
            "--yes",
            "--key",
            "publisher.key",
            "--signing-config",
            "signing.json",
            "--trusted-root",
            "roots.json",
            "--type",
            predicate_type,
            "--predicate",
            str(predicate),
            "--bundle",
            str(cls.bundle),
            str(cls.wheel),
        )
        # Neither retained controls nor their logs contain temporary private keys.
        (cls.root / "publisher.key").unlink()
        (cls.root / "other.key").unlink()
        key = cls.root / "publisher.pub"

        def digest(path):
            return hashlib.sha256(path.read_bytes()).hexdigest()

        policy = CosignKeyWheelPolicy(
            digest(cls.wheel), predicate_type, digest(key), "key_only_no_tlog"
        )
        cls.profile_values = {
            "profile_version": 1,
            "verifier": {
                "kind": "cosign_key_no_tlog",
                **tool,
                "public_key": str(key),
                "public_key_sha256": digest(key),
                "trusted_root": str(cls.root / "roots.json"),
                "trusted_root_sha256": digest(cls.root / "roots.json"),
            },
            "evaluators": [
                {
                    "namespace": DOCUMENTS.NAMESPACE,
                    "wheel": str(cls.wheel),
                    "bundle": str(cls.bundle),
                    "publisher": asdict(policy),
                }
            ],
        }
        cls.profile = DOCUMENTS.dump(
            cls.root / "operator-profile.json", cls.profile_values
        )
        cls.profile.chmod(0o400)
        cls.qualification = cls.root / "qualification"
        preinstall = cls.root / "preinstall"
        captured_binding = QUALIFY.qualify(cls.profile, preinstall, installed=False)
        if (preinstall / cls.wheel.name).read_bytes() != cls.wheel.read_bytes():
            raise ValueError("preinstall input differs from authenticated bytes")
        cls.binding = QUALIFY.qualify(cls.profile, cls.qualification)
        if captured_binding["artifact_sha256"] != cls.binding["artifact_sha256"]:
            raise ValueError("preinstall and installed subjects differ")

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.case.cleanup)
        self.prepared, self.manifest = DOCUMENTS.inputs(
            Path(self.case.name), self.binding
        )
        self.capture, self.facts = DOCUMENTS.completed(self.prepared, self.manifest)

    def assess(self, profile=None):
        inputs = DOCUMENTS.FINALIZE.complete(self.prepared, self.capture)
        arguments = [
            str(Path(sys.executable).parent / "robotics-acceptance"),
            "evaluate",
        ]
        for key, value in inputs.items():
            arguments += ["--" + key.replace("_", "-"), str(value)]
        arguments += [
            "--window-start-ns",
            "0",
            "--window-end-ns",
            "1",
            "--extension-schema",
            "urn:nav2-turtlebot3:scenario:v1="
            + str(self.prepared / "nav2.schema.json"),
            "--output",
            str(Path(self.case.name) / "assessment"),
        ]
        for flag, name in (
            ("--evaluator-receipt", "receipt.json"),
            ("--evaluator-verification", "verification.json"),
        ):
            arguments += [flag, str(self.qualification / name)]
        for name in ("statement.json", "publisher.json", "verified-report.txt"):
            arguments += [
                "--evaluator-receipt-dependency",
                str(self.qualification / name),
            ]
        if profile:
            arguments += ["--evaluator-trust-profile", str(profile)]
        originals = {path: path.read_bytes() for path in self.prepared.iterdir()}
        environment = os.environ.copy()
        environment.pop("PYTHONPATH", None)
        environment.pop("PYTHONHOME", None)
        result = subprocess.run(
            arguments,
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=45,
            check=False,
        )
        self.assertEqual(originals, {path: path.read_bytes() for path in originals})
        return result

    def test_authenticated_product_projects_json_and_junit(self):
        result = self.assess(self.profile)
        self.assertEqual(result.returncode, 0, result.stderr)
        projection = json.loads(result.stdout)
        self.assertEqual(projection["status"], "passed")
        assessment = Path(self.case.name) / "assessment"
        document = json.loads((assessment / "acceptance-result.json").read_bytes())
        self.assertEqual(document["schema_version"], "acceptance-result.v2")
        self.assertEqual(document["run_id"], self.manifest["run_id"])
        self.assertEqual(
            len(ET.parse(assessment / "junit.xml").findall(".//failure")), 0
        )

    def test_wrong_goal_is_failed_in_json_and_junit(self):
        path = self.capture / "workload.json"
        report = json.loads(path.read_bytes())
        report["goal_requested"]["x"] += 1
        DOCUMENTS.dump(path, report)
        for name in ("command", "terminal", "condition"):
            self.facts["observations"][name]["evidence"] = DOCUMENTS.reference(path)
        DOCUMENTS.dump(self.capture / "completed-facts.json", self.facts)
        result = self.assess(self.profile)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "failed")
        junit = ET.parse(Path(self.case.name) / "assessment/junit.xml")
        self.assertGreater(len(junit.findall(".//failure")), 0)

    def test_missing_required_cleanup_remains_incomplete(self):
        del self.facts["observations"]["cleanup"]
        DOCUMENTS.dump(self.capture / "completed-facts.json", self.facts)
        result = self.assess(self.profile)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "incomplete")
        junit = ET.parse(Path(self.case.name) / "assessment/junit.xml")
        self.assertGreater(len(junit.findall(".//skipped")), 0)

    def test_receipt_only_does_not_admit_executable(self):
        result = self.assess()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("authenticated", result.stderr.lower())

    def test_other_pinned_key_cannot_verify_the_subject(self):
        values = json.loads(json.dumps(self.profile_values))
        other = self.root / "other.pub"
        digest = hashlib.sha256(other.read_bytes()).hexdigest()
        values["verifier"]["public_key"] = str(other)
        values["verifier"]["public_key_sha256"] = digest
        values["evaluators"][0]["publisher"]["public_key_sha256"] = digest
        wrong = DOCUMENTS.dump(Path(self.case.name) / "wrong-key-profile.json", values)
        wrong.chmod(0o400)
        result = self.assess(wrong)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verification refused", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
