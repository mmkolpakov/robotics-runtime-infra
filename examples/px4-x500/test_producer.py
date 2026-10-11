"""Installed SDK synthetic controls; no native flight or composition is qualified."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from robotics_acceptance_harness.evidence import VerifiedEvidence

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("px4_producer", ROOT / "producer.py")
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)
RUN = "run-11111111-2222-4333-8444-555555555555"


def write(path, value):
    path.write_text(json.dumps(value))
    return path


def inputs(root, case="land"):
    profile = {
        "profile_id": PRODUCER.PROFILE,
        "executor": {
            "implementation": "px4-x500-controller",
            "version": "synthetic-source-control",
        },
        "clock": PRODUCER.CLOCK,
        "channels": [
            {
                "name": "mavsdk-telemetry-position",
                "original_type": {
                    "name": "mavsdk.rpc.telemetry.PositionResponse",
                    "type_support": {
                        "implementation": "MAVSDK-Proto",
                        "version": "5c81ecfeb6110cf74ba75ae50b78a1b265c05670",
                    },
                },
                "backend": "gRPC",
                "wire_envelope": "protobuf",
                "native_encoding": "protobuf",
                "recorder": {
                    "implementation": "px4-x500-controller",
                    "version": "1",
                    "transformation": "SDK-decoded JSON",
                },
            }
        ],
        "observations": {
            name: {"kind": kind, "requirement": "required"}
            for name, kind in (
                ("command", "command_acceptance"),
                ("terminal", "native_final_state"),
                ("postcondition", "postcondition"),
                ("cleanup", "shutdown"),
            )
        },
    }
    path = write(root / "profile.json", profile)
    prepared = root / "archive/inputs"
    supplied = os.environ.get("PX4_EVALUATOR_BINDING")
    binding = (
        Path(supplied)
        if supplied
        else write(
            root / "binding.json",
            {
                "namespace": PRODUCER.PROFILE,
                "entry_point": "px4_x500_evaluator:evaluate",
                "distribution": "px4-x500-evaluator",
                "version": "0.1.0",
                "artifact_sha256": "a" * 64,
                "receipt_sha256": "b" * 64,
            },
        )
    )
    manifest = PRODUCER.prepare(path, case, prepared, binding_path=binding, run_id=RUN)
    return prepared, manifest


def capture(prepared, case="land", *, ascent=1.5, missing_ground=False, cleanup=True):
    directory = prepared.parent / "capture"
    directory.mkdir()
    base = 1700000000000000000
    rows = []

    def record(kind, value):
        number = len(rows)
        value = {
            "run_id": RUN,
            "domain_id": "px4",
            "sequence": number,
            "kind": kind,
            "receiver_unix_ns": str(base + (number + 1) * 1000000),
            "receiver_monotonic_ms": (number + 1) * 1.0,
            "value": value,
        }
        path = write(directory / (str(number).zfill(4) + "-" + kind + ".json"), value)
        raw = path.read_bytes()
        rows.append(
            {
                "path": path.name,
                "kind": kind,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size_bytes": len(raw),
            }
        )

    if case != "unarmed-refusal":
        record("action-issued", {"method": "takeoff"})
        record(
            "action-takeoff",
            {
                "monotonic_ms": 1,
                "value": {"action_result": {"result": "RESULT_SUCCESS"}},
            },
        )
    for altitude in (0, 0.05, 0.1, 0.05) if case == "unarmed-refusal" else (0, ascent):
        record(
            "telemetry-position",
            {"value": {"position": {"relative_altitude_m": altitude}}},
        )
    if case != "unarmed-refusal":
        record("action-issued", {"method": "land"})
        record(
            "action-land", {"value": {"action_result": {"result": "RESULT_SUCCESS"}}}
        )
    if not missing_ground:
        record(
            "telemetry-landed", {"value": {"landed_state": "LANDED_STATE_ON_GROUND"}}
        )
    record("telemetry-armed", {"value": {"is_armed": False}})
    outcome = {"case": case}
    if case == "unarmed-refusal":
        outcome.update(
            {
                "observed": "caller-refused-unarmed",
                "refusal": {
                    "method": "takeoff",
                    "boundary": "caller-precondition",
                    "reason": "unarmed",
                },
            }
        )
    record("controller-result", {"complete": True, "outcome": outcome})
    end = base + (len(rows) + 2) * 1000000
    manifest = {
        "run_id": RUN,
        "domain_id": "px4",
        "clock_source": PRODUCER.CLOCK["source_id"],
        "started_unix_ns": str(base),
        "finished_unix_ns": str(end),
        "complete": True,
        "records": rows,
        "total_bytes": sum(row["size_bytes"] for row in rows),
    }
    write(directory / "controller-manifest.json", manifest)
    if cleanup:
        write(
            directory / "engine-cleanup.json",
            {
                "owner_id": RUN,
                "released": True,
                "observed": {"containers": [], "networks": []},
                "clock_source": PRODUCER.CLOCK["source_id"],
                "receiver_unix_ns": str(end - 1000000),
            },
        )
    return directory


def rewrite_capture(folder, transform):
    """Synthetic record edits preserve the journal's actual byte links/order."""
    manifest_path = folder / "controller-manifest.json"
    manifest = json.loads(manifest_path.read_bytes())
    records = [
        json.loads((folder / entry["path"]).read_bytes())
        for entry in manifest["records"]
    ]
    transform(records)
    base = int(manifest["started_unix_ns"])
    rows = []
    for number, record in enumerate(records):
        record.update(
            sequence=number,
            receiver_unix_ns=str(base + (number + 1) * 1000000),
            receiver_monotonic_ms=(number + 1) * 1.0,
        )
        path = write(
            folder / (str(number).zfill(4) + "-" + record["kind"] + ".json"), record
        )
        raw = path.read_bytes()
        rows.append(
            {
                "path": path.name,
                "kind": record["kind"],
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size_bytes": len(raw),
            }
        )
    manifest.update(
        records=rows,
        total_bytes=sum(row["size_bytes"] for row in rows),
        finished_unix_ns=str(base + (len(rows) + 2) * 1000000),
    )
    write(manifest_path, manifest)


def incomplete_controller(records):
    for record in records:
        if record["kind"] == "controller-result":
            record["value"] = {"complete": False, "error": "interrupted"}


def initial_state_only(records):
    states = [
        record
        for record in records
        if record["kind"] in ("telemetry-landed", "telemetry-armed")
    ]
    records[:] = states + [record for record in records if record not in states]


def action_result(value):
    def transform(records):
        for record in records:
            if record["kind"] == "action-takeoff":
                record["value"]["value"]["action_result"]["result"] = value

    return transform


class ProducerControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.admission = os.environ.get("PX4_ADMISSION")

    def assess(
        self,
        *,
        ascent=1.5,
        missing_ground=False,
        cleanup=True,
        case="land",
        transform=None,
        operator_profile=None,
        include_trust=True,
    ):
        if not self.admission:
            self.skipTest(
                "actual external wheel authentication/receipt fixture required"
            )
        prepared, _manifest = inputs(self.root, case)
        folder = capture(
            prepared,
            case,
            ascent=ascent,
            missing_ground=missing_ground,
            cleanup=cleanup,
        )
        if transform:
            transform(folder)
        before = {path: path.read_bytes() for path in prepared.iterdir()}
        result = PRODUCER.complete(prepared, folder)
        arguments = [
            str(Path(sys.executable).parent / "robotics-acceptance"),
            "evaluate",
        ]
        for key, value in result.items():
            arguments += ["--" + key.replace("_", "-"), str(value)]
        output = self.root / "assessment"
        arguments += ["--output", str(output)]
        admission = Path(self.admission)
        if include_trust:
            arguments += [
                "--evaluator-trust-profile",
                str(operator_profile or admission / "operator-profile.json"),
            ]
        for flag, name in (
            ("--evaluator-receipt", "receipt.json"),
            ("--evaluator-verification", "verification.json"),
        ):
            arguments += [flag, str(admission / name)]
        for name in ("statement.json", "publisher.json", "verified-report.txt"):
            arguments += ["--evaluator-receipt-dependency", str(admission / name)]
        environment = os.environ.copy()
        environment.pop("PYTHONPATH", None)
        environment.pop("PYTHONHOME", None)
        completed = subprocess.run(
            arguments,
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        return completed, output

    def test_installed_core_projects_passed_json_and_junit(self):
        result, output = self.assess()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "passed")
        document = json.loads((output / "acceptance-result.json").read_bytes())
        self.assertEqual(document["schema_version"], "acceptance-result.v2")
        self.assertEqual(document["run_id"], RUN)
        self.assertFalse(ET.parse(output / "junit.xml").findall(".//failure"))

    def test_ack_with_observed_no_ascent_is_failed(self):
        result, output = self.assess(ascent=0)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "failed")
        self.assertTrue(ET.parse(output / "junit.xml").findall(".//failure"))

    def test_missing_ground_is_incomplete(self):
        result, output = self.assess(missing_ground=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "incomplete")
        self.assertTrue(ET.parse(output / "junit.xml").findall(".//skipped"))

    def test_missing_owner_cleanup_is_incomplete(self):
        result, output = self.assess(cleanup=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "incomplete")
        self.assertTrue(ET.parse(output / "junit.xml").findall(".//skipped"))

    def test_unarmed_refusal_does_not_claim_a_firmware_denial(self):
        result, _output = self.assess(case="unarmed-refusal")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "passed")

    def test_interrupted_controller_with_omitted_outcome_is_incomplete(self):
        result, _output = self.assess(
            transform=lambda folder: rewrite_capture(folder, incomplete_controller)
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "incomplete")

    def test_missing_terminal_summary_does_not_erase_independent_facts(self):
        def transform(folder):
            rewrite_capture(
                folder,
                lambda records: records.__setitem__(
                    slice(None),
                    [row for row in records if row["kind"] != "controller-result"],
                ),
            )

        result, output = self.assess(transform=transform)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "incomplete")
        assertions = json.loads((output / "acceptance-result.json").read_bytes())[
            "assertion_results"
        ]
        cleanup = next(
            row for row in assertions if row["assertion_id"].endswith(".cleanup")
        )
        self.assertEqual(cleanup["status"], "passed")

    def test_initial_ground_disarm_cannot_be_terminal_postcondition(self):
        result, _output = self.assess(
            transform=lambda folder: rewrite_capture(folder, initial_state_only)
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "incomplete")

    def test_terminal_state_after_issued_before_ack_is_observed(self):
        def ordered(records):
            ack = next(row for row in records if row["kind"] == "action-land")
            records.remove(ack)
            records.insert(len(records) - 1, ack)

        result, _output = self.assess(
            transform=lambda folder: rewrite_capture(folder, ordered)
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unknown_takeoff_response_is_incomplete(self):
        result, _output = self.assess(
            transform=lambda folder: rewrite_capture(
                folder, action_result("RESULT_UNKNOWN")
            )
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "incomplete")

    def test_timeout_ack_does_not_claim_vehicle_denial(self):
        result, _output = self.assess(
            transform=lambda folder: rewrite_capture(
                folder, action_result("RESULT_TIMEOUT")
            )
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "incomplete")

    def test_non_enum_takeoff_response_is_error(self):
        result, _output = self.assess(
            transform=lambda folder: rewrite_capture(
                folder, action_result("RESULT_BOGUS")
            )
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "error")

    def test_interrupted_controller_keeps_observed_cleanup_failure(self):
        def transform(folder):
            rewrite_capture(folder, incomplete_controller)
            path = folder / "engine-cleanup.json"
            value = json.loads(path.read_bytes())
            value.update(
                released=False, observed={"containers": ["remaining"], "networks": []}
            )
            write(path, value)

        result, output = self.assess(transform=transform)
        self.assertEqual(result.returncode, 1, result.stderr)
        assertions = json.loads((output / "acceptance-result.json").read_bytes())[
            "assertion_results"
        ]
        cleanup = next(
            row for row in assertions if row["assertion_id"].endswith(".cleanup")
        )
        self.assertEqual(cleanup["status"], "failed")

    def test_frozen_snapshots_ignore_mutation_of_original_after_capture(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        original = PRODUCER.add_evidence_artifact
        calls = []

        def register(draft, path, metadata):
            calls.append(path)
            # At this point originals were already bounded/captured; writers only
            # receive producer-owned frozen files, never this mutable source.
            if len(calls) == 1:
                for source in folder.glob("*.json"):
                    source.write_bytes(b"changed after capture")
            self.assertIn(
                path.parent,
                (prepared.parent / "source-records", prepared, prepared.parent),
            )
            return original(draft, path, metadata)

        with patch.object(PRODUCER, "add_evidence_artifact", register):
            PRODUCER.complete(prepared, folder)
        observation = json.loads((prepared.parent / "observation.json").read_bytes())
        self.assertTrue(observation["observations"]["postcondition"]["value"])

    def test_oversized_and_mismatched_record_refuse_before_writer(self):
        for oversized in (False, True):
            with (
                self.subTest(oversized=oversized),
                tempfile.TemporaryDirectory() as temporary,
            ):
                prepared, _manifest = inputs(Path(temporary))
                folder = capture(prepared)
                manifest = json.loads(
                    (folder / "controller-manifest.json").read_bytes()
                )
                path = folder / manifest["records"][0]["path"]
                path.write_bytes(
                    b"x" * (PRODUCER.LIMIT + 1)
                    if oversized
                    else path.read_bytes() + b"x"
                )
                with patch.object(PRODUCER, "add_evidence_artifact") as writer:
                    with self.assertRaises(ValueError):
                        PRODUCER.complete(prepared, folder)
                    writer.assert_not_called()
                self.assertFalse((prepared.parent / "source-records").exists())
                self.assertFalse((prepared.parent / "evidence-index.json").exists())

    def test_cleanup_symlink_refuses_before_writer(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = folder / "engine-cleanup.json"
        other = self.root / "outside.json"
        path.rename(other)
        path.symlink_to(other)
        with patch.object(PRODUCER, "add_evidence_artifact") as writer:
            with self.assertRaisesRegex(ValueError, "symlink"):
                PRODUCER.complete(prepared, folder)
            writer.assert_not_called()

    def test_cleanup_fifo_is_rejected_in_bounded_outer_process(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = folder / "engine-cleanup.json"
        path.unlink()
        os.mkfifo(path, 0o600)
        program = (
            "import importlib.util; from pathlib import Path; "
            f"s=importlib.util.spec_from_file_location('producer', {str(ROOT / 'producer.py')!r}); "
            "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
            "m.add_evidence_artifact=lambda *args: (_ for _ in ()).throw(AssertionError('writer reached')); "
            f"m.complete(Path({str(prepared)!r}), Path({str(folder)!r}))"
        )
        result = subprocess.run(
            [sys.executable, "-c", program],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bounded regular file", result.stderr)
        self.assertNotIn("writer reached", result.stderr)
        self.assertFalse((prepared.parent / "evidence-index.json").exists())

    def test_receipt_documents_without_external_authentication_refuse_loading(self):
        result, _output = self.assess(include_trust=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires authenticated wheel/source admission", result.stderr)

    def test_genuine_signature_with_wrong_external_publisher_key_refuses(self):
        if not self.admission:
            self.skipTest("actual stock Cosign publisher fixture required")
        admission = Path(self.admission)
        profile = json.loads((admission / "operator-profile.json").read_bytes())
        wrong_key = admission / "other.pub"
        digest = hashlib.sha256(wrong_key.read_bytes()).hexdigest()
        profile["verifier"].update(public_key=str(wrong_key), public_key_sha256=digest)
        profile["evaluators"][0]["publisher"]["public_key_sha256"] = digest
        path = write(self.root / "other-operator-profile.json", profile)
        path.chmod(0o400)
        result, _output = self.assess(operator_profile=path)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Cosign", result.stderr)

    def test_pre_run_documents_exist_before_capture_and_are_not_rewritten(self):
        prepared, manifest = inputs(self.root)
        before = {path: path.read_bytes() for path in prepared.iterdir()}
        self.assertFalse((prepared.parent / "observation.json").exists())
        folder = capture(prepared)
        result = PRODUCER.complete(prepared, folder)
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        observation = json.loads((prepared.parent / "observation.json").read_bytes())
        self.assertEqual(
            observation["runtime_manifest_sha256"], manifest["runtime"]["sha256"]
        )
        self.assertEqual(result["run_id"], RUN)

    def test_each_original_payload_is_parsed_from_one_verified_snapshot(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        original = VerifiedEvidence.read_local
        reads = []

        def read(evidence, path, **keywords):
            raw = original(evidence, path, **keywords)
            reads.append(path)
            return raw

        with patch.object(VerifiedEvidence, "read_local", read):
            PRODUCER.complete(prepared, folder)
        self.assertEqual(len(reads), len(set(reads)))
        self.assertEqual(
            len(reads),
            len(
                json.loads((folder / "controller-manifest.json").read_bytes())[
                    "records"
                ]
            )
            + 1,
        )

    def test_command_ack_cannot_create_ground_or_ascent(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared, ascent=0, missing_ground=True)
        PRODUCER.complete(prepared, folder)
        observation = json.loads((prepared.parent / "observation.json").read_bytes())
        self.assertEqual(observation["observations"]["command"]["value"], True)
        self.assertEqual(observation["observations"]["terminal"]["state"], "unobserved")
        self.assertEqual(observation["observations"]["postcondition"]["value"], False)

    def test_absent_cleanup_remains_unobserved(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared, cleanup=False)
        PRODUCER.complete(prepared, folder)
        observation = json.loads((prepared.parent / "observation.json").read_bytes())
        self.assertEqual(observation["observations"]["cleanup"]["state"], "unobserved")

    def test_sdk_observations_do_not_invent_otlp_instrumentation(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = folder / "engine-cleanup.json"
        facts = json.loads(path.read_bytes())
        del facts["receiver_unix_ns"]
        write(path, facts)
        PRODUCER.complete(prepared, folder)
        self.assertFalse((prepared.parent / "metrics.jsonl").exists())

    def test_foreign_cleanup_owner_refuses(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = folder / "engine-cleanup.json"
        facts = json.loads(path.read_bytes())
        facts["owner_id"] = "foreign"
        write(path, facts)
        with self.assertRaisesRegex(ValueError, "another native owner"):
            PRODUCER.complete(prepared, folder)

    def test_manifest_complete_requires_json_boolean_true(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = folder / "controller-manifest.json"
        document = json.loads(path.read_bytes())
        document["complete"] = 1
        write(path, document)
        with patch.object(PRODUCER, "add_evidence_artifact") as writer:
            with self.assertRaisesRegex(ValueError, "closed manifest"):
                PRODUCER.complete(prepared, folder)
            writer.assert_not_called()

    def test_changed_pre_run_input_refuses_before_completed_outputs(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = prepared / "runtime.json"
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "pre-run input bytes changed"):
            PRODUCER.complete(prepared, folder)
        self.assertFalse((prepared.parent / "evidence-index.json").exists())


if __name__ == "__main__":
    unittest.main()
