"""Exercise synthetic runtime production with retained observation fixtures."""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

from robotics_runtime_contracts import validate_role

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/physical-attach/create-runtime-input.py"
SPEC = importlib.util.spec_from_file_location("physical_runtime", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
producer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(producer)


class PhysicalRuntimeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        self.args = argparse.Namespace(
            inputs=self.inputs,
            output=self.root / "provider",
            subject_digest="sha256:" + "a" * 64,
            subject_reference="local/observer@sha256:" + "a" * 64,
            workspace_revision="b" * 40,
            infra_revision="c" * 40,
            run_id="run-aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
            domain_id=92,
        )
        self.platform = {
            "os": "ubuntu",
            "os_version": "24.04",
            "architecture": "x86_64",
            "kernel": "6.8.0-test",
        }
        self.ros = {
            "distribution": "jazzy",
            "rmw_implementation": "rmw_fastrtps_cpp",
            "rmw_version": "8.4.2",
            "domain_id": 92,
        }
        self.evidence = producer.mapping(ROOT / "test/ci/physical-attach/target-evidence.json")
        self.evidence["identity"]["sha256"] = "d" * 64
        self.evidence["identity"]["certificate_sha256"] = "e" * 64
        self.save("target-evidence.json", self.evidence)
        self.save("host-platform.json", self.platform)
        self.save("clock.json", {"offset_ms": 0.75, "drift_ppm": 1.5})
        (self.inputs / "template.json").write_bytes(
            (ROOT / "test/physical/hil-runtime.input.json").read_bytes()
        )
        (self.inputs / "observer.policy.xml").write_bytes(b"<policy/>\n")
        (self.inputs / "serial-received.txt").write_bytes(b"target-to-host\n")
        (self.inputs / "serial-reverse-received.txt").write_bytes(b"host-to-target\n")
        (self.inputs / "can-received.txt").write_bytes(b"client | vcan0 123#DEADBEEF\n")

    def save(self, name, value):
        (self.inputs / name).write_text(json.dumps(value), encoding="utf-8")

    def create(self):
        return producer.create_documents(self.args, self.platform, self.ros)

    def invoke(self):
        arguments = [str(SCRIPT)]
        for key, value in vars(self.args).items():
            arguments.extend(["--" + key.replace("_", "-"), str(value)])
        errors = io.StringIO()
        with (
            patch.object(sys, "argv", arguments),
            patch.dict(os.environ, ROS_DISTRO="jazzy", RMW_IMPLEMENTATION="rmw_fastrtps_cpp"),
            patch.object(producer, "platform_facts", return_value=self.platform),
            patch.object(producer.subprocess, "check_output", return_value="8.4.2\n") as ros,
            redirect_stderr(errors),
        ):
            status = producer.main()
        return status, errors.getvalue(), ros

    def test_cli_binds_file_bytes_and_actual_platform_and_ros_facts(self):
        status, errors, ros_call = self.invoke()
        self.assertEqual(status, 0, errors)
        ros_call.assert_called_once_with(
            ["ros2", "pkg", "xml", "rmw_fastrtps_cpp", "--tag", "version"],
            text=True,
            timeout=20,
        )
        output = self.args.output
        runtime = producer.mapping(output / "runtime-manifest.input.json")
        result = producer.mapping(output / "conformance.json")
        profile = producer.mapping(output / "profile.json")
        for document, role in (
            (runtime, "runtime_manifest"),
            (result, "conformance_result"),
            (profile, "qualification_profile"),
        ):
            validate_role(document, role)
        binding = runtime["provider_bindings"][0]
        for field, filename in (
            ("qualification_profile_sha256", "profile.json"),
            ("conformance_result_sha256", "conformance.json"),
        ):
            self.assertEqual(
                binding[field],
                hashlib.sha256((output / filename).read_bytes()).hexdigest(),
            )
        self.assertEqual(binding["provider"], result["provider"])
        self.assertEqual(
            result["provider"]["configuration_sha256"],
            hashlib.sha256((output / "configuration.json").read_bytes()).hexdigest(),
        )
        self.assertFalse(
            producer.mapping(output / "configuration.json")["hardware_identity_verified"]
        )
        self.assertIn(
            "no physical hardware identity or qualification",
            result["checks"][0]["message"],
        )
        self.assertEqual(runtime["ros"], self.ros)
        self.assertEqual(runtime["host_platform"], self.platform)
        self.assertEqual(runtime["execution_platform"], self.platform)
        self.assertEqual(runtime["clock"]["offset_ms"], 0.75)
        self.assertEqual(runtime["clock"]["drift_ppm"], 1.5)
        self.assertEqual(runtime["execution_subject"]["digest"], self.args.subject_digest)
        self.assertEqual(runtime["components"]["contracts_revision"], self.args.workspace_revision)
        self.assertNotIn("oci_image", runtime)
        self.assertNotIn("host", runtime)
        for artifact in result["evidence"]:
            paths = [p for p in self.inputs.iterdir() if p.resolve().as_uri() == artifact["uri"]]
            self.assertEqual(len(paths), 1)
            raw = paths[0].read_bytes()
            self.assertEqual(artifact["sha256"], hashlib.sha256(raw).hexdigest())
            self.assertEqual(artifact["size_bytes"], len(raw))

    def test_failed_serial_and_can_observations_produce_no_manifest(self):
        for name in (
            "serial-received.txt",
            "serial-reverse-received.txt",
            "can-received.txt",
        ):
            with self.subTest(name=name):
                path = self.inputs / name
                original = path.read_bytes()
                path.write_bytes(b"wrong observation\n")
                status, errors, _ = self.invoke()
                self.assertEqual(status, 1)
                self.assertIn("exchange failed", errors)
                self.assertFalse(self.args.output.exists())
                path.write_bytes(original)

    def test_rejects_physical_identity_claim_and_malformed_observations(self):
        for field, value in (
            ("identity", None),
            ("serial", []),
            ("can", "vcan0"),
            (
                "identity",
                {**self.evidence["identity"], "hardware_identity_verified": True},
            ),
            ("identity", {**self.evidence["identity"], "scope": "physical_target"}),
            ("serial", {**self.evidence["serial"], "bidirectional_exchange": False}),
            ("can", {**self.evidence["can"], "receive_only_gateway": False}),
        ):
            with self.subTest(field=field, value=value):
                evidence = copy.deepcopy(self.evidence)
                evidence[field] = value
                self.save("target-evidence.json", evidence)
                with self.assertRaisesRegex(ValueError, "synthetic PTY/vCAN"):
                    self.create()

    def test_rejects_clock_fields_that_override_the_measured_basis(self):
        self.save("clock.json", {"offset_ms": 0.1, "drift_ppm": 1, "basis": "ros_time"})
        with self.assertRaisesRegex(ValueError, "measured clock offset and drift"):
            self.create()

    def test_rejects_missing_and_multiline_rmw_versions(self):
        for version in (None, "", "  ", "8.4.2\n8.4.3"):
            with self.subTest(version=version):
                self.ros["rmw_version"] = version
                with self.assertRaisesRegex(ValueError, "exactly one version"):
                    self.create()

    def test_runtime_binding_has_no_mutable_alias_to_the_result(self):
        _, _, result, runtime = self.create()
        result["provider"]["version"] = "changed"
        result["capabilities"].clear()
        self.assertEqual(
            runtime["provider_bindings"][0]["provider"]["version"],
            self.args.infra_revision,
        )
        self.assertEqual(runtime["provider_bindings"][0]["capabilities"], ["live_observation"])

    def test_existing_output_is_preserved(self):
        self.args.output.mkdir()
        marker = self.args.output / "keep.txt"
        marker.write_bytes(b"existing evidence")
        status, errors, ros = self.invoke()
        self.assertEqual(status, 1)
        self.assertIn("must be new", errors)
        self.assertEqual(marker.read_bytes(), b"existing evidence")
        ros.assert_not_called()

    def test_wrong_platform_facts_are_rejected_before_any_output(self):
        self.platform["architecture"] = ""
        status, errors, _ = self.invoke()
        self.assertEqual(status, 1)
        self.assertIn("architecture", errors)
        self.assertFalse(self.args.output.exists())


if __name__ == "__main__":
    unittest.main()
